#!/usr/bin/env bash
# One-step installer for HDMI 2.1 FRL with VRR on the Valve Steam Machine.
# Run it as the deck user, without sudo: it asks for the password itself.
#
#   setup.sh install|uninstall|status [--yes|-y] [--no-reboot] [--dir DIR]
#            [--dry-run] [-h|--help]
#
#   install    build the patched amdgpu module, install it and the self-heal
#              units, switch grub to FRL, then offer a reboot
#   uninstall  undo all of that (TMDS again, stock module, units removed)
#   status     show what is installed and running; changes nothing
#
#   --yes       take every default without asking (reboots at the end)
#   --no-reboot do not offer the final reboot
#   --dir DIR   install location under /home (default ~/steam-machine-hdmi21,
#               or $HDMI21_DIR); the self-heal units run the scripts from there
#   --dry-run   print what would be done, change nothing, never use sudo
#
# Exit codes: 0 ok, 1 a step failed, 2 usage, 3 refused by a preflight check,
# 4 declined at a prompt. The log is $HDMI21_LOG, default
# ~/steam-machine-hdmi21-setup.log.
set -euo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ORIG_ARGS=("$@")

CMD=""
YES=0
NO_REBOOT=0
DRY=0
DIR_ARG=${HDMI21_DIR:-}
LOG=${HDMI21_LOG:-$HOME/steam-machine-hdmi21-setup.log}
VERSION=$(cat "$SELF_DIR/VERSION" 2>/dev/null || echo unknown)

UNIT_PATH=/etc/systemd/system/hdmi-frl-grub.service
CACHE_DIR=$HOME/.cache/steam-machine-hdmi21
MARKER_FILE=.installed-by-setup
SB_VAR=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
MIRROR_URL=https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources/
EXEC_FILES="build.sh install.sh uninstall.sh hdmi-mode.sh setup-selfheal.sh setup.sh get.sh
selfheal/hdmi-frl-selfheal.sh selfheal/hdmi-frl-resume.sh"
# SHA-256 of patches/*.patch (cat in name order) as shipped in 1.0.0 and 1.0.1.
# build.sh stamps every module with the hash of the patches it was built from;
# a module from before the stamp existed (1.0.0) was built from this set.
LEGACY_PATCHES_SHA=2172983dbd3bae7ba2dc45ba29a25758f9bf9569780286dc547fb324c51a4aff

STEP=0
KEEPALIVE_PID=""
TEE_PID=""
TARGET=""
INSTALL_DIR=""
STAGE_NEW=""
STAGE_OLD=""

log() { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARNING: %s\n' "$*" >&2; }
die() { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }
refuse() { printf '[setup] %s\n' "$*" >&2; exit 3; }
usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
usage_error() { printf '[setup] %s (see --help)\n' "$*" >&2; exit 2; }
run() {
	if [ "$DRY" = 1 ]; then log "would run: $*"; else "$@"; fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		install|uninstall|status)
			[ -z "$CMD" ] || usage_error "more than one command given: $CMD and $1"
			CMD=$1; shift ;;
		--yes|-y) YES=1; shift ;;
		--no-reboot) NO_REBOOT=1; shift ;;
		--dry-run) DRY=1; shift ;;
		--dir)
			[ $# -ge 2 ] || usage_error "--dir needs a path"
			DIR_ARG=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) usage_error "unknown argument: $1" ;;
	esac
done
[ -n "$CMD" ] || usage_error "no command given (install, uninstall or status)"

# --- exit handling --------------------------------------------------------
# One handler for every exit: stop the sudo keepalive, report a failed step,
# and close the log pipe so tee flushes the last lines before the shell is gone.
on_exit() {
	local rc=$?
	set +e
	[ -z "$KEEPALIVE_PID" ] || kill "$KEEPALIVE_PID" 2>/dev/null
	# Only staging directories this run created; the old tree is removed
	# explicitly after a good swap, and kept (not removed) if it is not empty.
	[ -z "$STAGE_NEW" ] || rm -rf "$STAGE_NEW" 2>/dev/null || sudo -n rm -rf "$STAGE_NEW" 2>/dev/null
	[ -z "$STAGE_OLD" ] || rmdir "$STAGE_OLD" 2>/dev/null
	if [ "$rc" != 0 ] && [ "$STEP" -gt 0 ]; then
		if [ "$CMD" = install ]; then
			printf '[setup] failed at step %s; log: %s; to roll back run: bash %s/setup.sh uninstall\n' \
				"$STEP" "$LOG" "$SELF_DIR" >&2
		else
			printf '[setup] failed at step %s; log: %s; fix the cause and run uninstall again\n' \
				"$STEP" "$LOG" >&2
		fi
		rc=1
	fi
	if [ -n "$TEE_PID" ]; then
		exec >&- 2>&-
		wait "$TEE_PID" 2>/dev/null
	fi
	exit "$rc"
}
trap on_exit EXIT

# --- prompts --------------------------------------------------------------
# ask "question" y|n: returns 0 for yes. --yes (and --dry-run) take the default.
ask() {
	local q=$1 def=$2 ans hint="[y/N]"
	[ "$def" = y ] && hint="[Y/n]"
	if [ "$YES" = 1 ] || [ "$DRY" = 1 ]; then
		log "$q $hint -> $def (automatic)"
		[ "$def" = y ]
		return
	fi
	( : </dev/tty ) 2>/dev/null || refuse "no terminal to ask '$q': run this in a terminal (or pass --yes)"
	printf '[setup] %s %s ' "$q" "$hint" >/dev/tty
	read -r ans </dev/tty || ans=""
	[ -n "$ans" ] || ans=$def
	case "$ans" in
		y|Y|yes|YES|Yes) return 0 ;;
		*) return 1 ;;
	esac
}

# sudo -v once, then keep the timestamp fresh while this script lives so the
# long build in the middle does not make a later sudo ask again.
start_keepalive() {
	[ "$DRY" = 0 ] || return 0
	if ! sudo -v; then
		printf '[setup] sudo did not accept the password.\n' >&2
		printf '[setup] Set one in Konsole with: passwd   then run this again.\n' >&2
		exit 3
	fi
	( while kill -0 $$ 2>/dev/null; do sudo -n -v || exit; sleep 45; done ) >/dev/null 2>&1 &
	KEEPALIVE_PID=$!
}

start_logging() {
	[ "$DRY" = 0 ] || return 0
	exec > >(tee -a "$LOG") 2>&1
	TEE_PID=$!
	log "log $LOG"
	log "date $(date '+%F %T')"
	log "version $VERSION"
	log "kernel $(uname -r)"
}

# --- preflight ------------------------------------------------------------
# True when out/ already holds a module for the running kernel that was built
# from the patches in this tree, so an upgrade that only touches scripts does
# not download, compile and reinstall anything again. HDMI21_REBUILD=1 forces
# a rebuild.
module_is_current() {
	local krel zst vm built want
	[ "${HDMI21_REBUILD:-0}" != 1 ] || return 1
	krel=$(uname -r)
	zst=$SELF_DIR/out/amdgpu-$krel.ko.zst
	[ -f "$zst" ] && [ -f "$zst.vermagic" ] || return 1
	vm=$(modinfo -F vermagic "$zst" 2>/dev/null | head -1) || return 1
	[ "${vm%% *}" = "$krel" ] || return 1
	built=$(cat "$zst.patches" 2>/dev/null || echo "$LEGACY_PATCHES_SHA")
	want=$(cat "$SELF_DIR"/patches/*.patch | sha256sum | cut -d' ' -f1)
	[ "$built" = "$want" ]
}

# 1-3: run before anything is changed; uninstall needs only these.
preflight_basic() {
	local pw
	[ "$(id -u)" != 0 ] || refuse "run as deck without sudo; it asks for your password itself"
	# shellcheck disable=SC1091
	if [ ! -r /etc/os-release ] || ! ( . /etc/os-release; [ "${ID:-}" = steamos ] ); then
		refuse "this is not SteamOS (/etc/os-release ID is not steamos)"
	fi
	pw=$(passwd -S "${USER:-$(id -un)}" 2>/dev/null | awk '{print $2}') || pw=""
	case "$pw" in
		NP|L)
			printf 'No password is set for %s. Open Konsole, run: passwd   then run this again.\n' "${USER:-$(id -un)}" >&2
			exit 3 ;;
	esac
}

# 4-10: install only, run once the scripts are in their final place.
preflight_install() {
	local krel have_deps=1 have_cache=0 avail need=12 net_ok=1 reuse=0
	krel=$(uname -r)
	if module_is_current; then reuse=1; need=0; fi

	bash "$SELF_DIR/build.sh" --check-kernel || refuse "this kernel is not supported (see above)"

	if [ "$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)" != Fremont ]; then
		warn "this does not look like a Steam Machine (product_name is not Fremont)"
		ask "Continue anyway?" y || exit 4
	fi

	if [ -r "$SB_VAR" ] && [ "$(tail -c1 "$SB_VAR" | od -An -tu1 | tr -d ' ')" = 1 ]; then
		refuse "Secure Boot is on; the module is unsigned"
	fi

	if compgen -G "$CACHE_DIR/extract/*/.bare-repo" >/dev/null; then
		have_cache=1
		if [ "$reuse" = 0 ]; then need=4; fi
	fi
	avail=$(df -Pk /home | awk 'NR==2 {print $4}')
	if [ "${avail:-0}" -lt $(( need * 1024 * 1024 )) ]; then
		refuse "need ${need} GiB free in /home, have $(( ${avail:-0} / 1024 / 1024 )) GiB"
	fi

	[ -d "/lib/modules/$krel/build" ] && command -v gcc >/dev/null 2>&1 \
		&& command -v make >/dev/null 2>&1 || have_deps=0
	curl -fsS --max-time 15 -o /dev/null "$MIRROR_URL" || net_ok=0
	if [ "$net_ok" = 0 ]; then
		if [ "$reuse" = 1 ]; then
			warn "cannot reach $MIRROR_URL; the module already built for $krel is reused"
		elif [ "$have_deps" = 1 ] && [ "$have_cache" = 1 ]; then
			warn "cannot reach $MIRROR_URL, carrying on with the cached toolchain and source"
		else
			refuse "cannot reach $MIRROR_URL and the headers, gcc, make and cached source are not all present"
		fi
	fi

	command -v modetest >/dev/null 2>&1 || warn "modetest (libdrm) is missing; status and the resume self-heal cannot read modes"
	command -v edid-decode >/dev/null 2>&1 || warn "edid-decode (v4l-utils) is missing; the resume self-heal cannot check the sink"

	if systemctl is-active -q hdmi-frl-rebuild 2>/dev/null; then
		refuse "a rebuild is running, wait: journalctl -fu hdmi-frl-rebuild"
	fi
}

# --- relocation -----------------------------------------------------------
# The self-heal units run the scripts in place, so they must live under /home,
# which survives atomic updates; a zip extracted in Downloads, a curl | tar in
# /tmp or a checkout somewhere else is copied there first and re-run from it.
physical_path() { ( cd -- "$1" 2>/dev/null && pwd -P ); }

copy_tree() { # dest
	mkdir -p "$1"
	tar -C "$SELF_DIR" --exclude=./.git --exclude=./out --exclude=./work -cf - . \
		| tar -C "$1" -xf -
	printf '%s\n' "$VERSION" > "$1/$MARKER_FILE"
	normalise_modes "$1"
}

# A zip extraction drops the executable bits, and systemd and setup-selfheal.sh
# refuse helpers that lack them, so fix them on every path before any step runs.
normalise_modes() { # dir
	local f todo=() missing=()
	for f in $EXEC_FILES; do
		[ ! -f "$1/$f" ] || todo+=("$1/$f")
	done
	[ ${#todo[@]} -gt 0 ] || return 0
	if [ "$DRY" = 1 ]; then
		for f in "${todo[@]}"; do
			[ -x "$f" ] || missing+=("${f#"$1"/}")
		done
		[ ${#missing[@]} -eq 0 ] || log "would chmod 755: ${missing[*]}"
		return 0
	fi
	chmod 755 "${todo[@]}"
}

move_in() { # src dest: keep build output across an upgrade
	[ -e "$1" ] || return 0
	mv "$1" "$2" 2>/dev/null || sudo mv "$1" "$2"
}

# Replace the installed copy with the staged one, carrying out/ and work/ over.
# The old tree is parked in a directory of its own and put back if anything
# fails, so the user's build output is never left only in a staging directory.
swap_in() { # staged-dir
	local d old
	old=$(mktemp -d "$TARGET.old.XXXXXX")
	STAGE_OLD=$old
	mv "$TARGET" "$old/prev"
	if move_in "$old/prev/out" "$1/out" \
		&& move_in "$old/prev/work" "$1/work" \
		&& mv "$1" "$TARGET"; then
		rm -rf "$old" 2>/dev/null || sudo rm -rf "$old"
		STAGE_OLD=""
		return 0
	fi
	for d in out work; do
		if [ -e "$1/$d" ] && [ ! -e "$old/prev/$d" ]; then
			mv "$1/$d" "$old/prev/$d" 2>/dev/null || sudo mv "$1/$d" "$old/prev/$d" \
				|| { STAGE_NEW=""; warn "could not move $1/$d back; it is kept in $1"; }
		fi
	done
	mv "$old/prev" "$TARGET" || { STAGE_OLD=""; die "upgrade failed and the old install is in $old/prev"; }
	die "upgrade of $TARGET failed; the previous install was put back"
}

relocate() {
	TARGET=${DIR_ARG:-$HOME/steam-machine-hdmi21}
	TARGET=${TARGET%/}
	if ! printf '%s\n' "$TARGET" | grep -qE '^/home/[A-Za-z0-9._/-]+$'; then
		refuse "install location '$TARGET' must be a path under /home using only letters, digits, . _ - and /"
	fi
	case "$TARGET" in
		*/../*|*/..) refuse "install location '$TARGET' must not contain '..'" ;;
	esac

	if [ "$SELF_DIR" = "$TARGET" ] || [ "$(physical_path "$TARGET")" = "$SELF_DIR" ]; then
		log "running in place from $SELF_DIR"
		return 0
	fi

	if [ -d "$TARGET/.git" ]; then
		log "$TARGET is an existing git checkout; using it in place, nothing is copied"
		log "update it with: git -C $TARGET pull"
		[ -f "$TARGET/setup.sh" ] || refuse "$TARGET is a checkout without setup.sh; run git pull there first"
		normalise_modes "$TARGET"
		if [ "$DRY" = 1 ]; then log "would run: bash $TARGET/setup.sh ${ORIG_ARGS[*]}"; return 0; fi
		exec bash "$TARGET/setup.sh" "${ORIG_ARGS[@]}"
	fi

	if [ -f "$TARGET/$MARKER_FILE" ]; then
		upgrade=1
	elif [ -e "$TARGET" ]; then
		refuse "$TARGET exists and was not created by this installer; move it or pass --dir"
	else
		upgrade=0
	fi
	if [ "$DRY" = 1 ]; then
		if [ "$upgrade" = 1 ]; then
			log "would upgrade $TARGET from $SELF_DIR, keeping out/ and work/"
		else
			log "would copy $SELF_DIR to $TARGET"
		fi
		return 0
	fi

	# Stage next to TARGET under names mktemp picked, so a rename stays on one
	# filesystem and nothing that already exists beside TARGET is ever touched.
	mkdir -p "$(dirname "$TARGET")"
	STAGE_NEW=$(mktemp -d "$TARGET.new.XXXXXX")
	chmod 755 "$STAGE_NEW"
	log "copying $SELF_DIR to $TARGET"
	copy_tree "$STAGE_NEW"
	if [ "$upgrade" = 1 ]; then
		log "upgrading $TARGET (out/ and work/ are kept)"
		swap_in "$STAGE_NEW"
	else
		[ ! -e "$TARGET" ] || refuse "$TARGET appeared while copying; move it or pass --dir"
		mv "$STAGE_NEW" "$TARGET"
	fi
	STAGE_NEW=""
	exec env HDMI21_RELOCATED=1 bash "$TARGET/setup.sh" "${ORIG_ARGS[@]}"
}

# --- shared ---------------------------------------------------------------
resolve_install_dir() {
	INSTALL_DIR=$(sed -n 's/^Environment=HDMI_FRL_REPO=//p' "$UNIT_PATH" 2>/dev/null | head -1 || true)
	[ -n "$INSTALL_DIR" ] || INSTALL_DIR=${DIR_ARG:-$HOME/steam-machine-hdmi21}
	INSTALL_DIR=${INSTALL_DIR%/}
}

offer_reboot() { # what the reboot is for
	if [ "$NO_REBOOT" = 1 ]; then
		log "not rebooting (--no-reboot). Reboot when ready to $1: sudo systemctl reboot"
		return 0
	fi
	warn "rebooting disconnects SSH sessions and closes this window"
	if ask "Reboot now to $1?" y; then
		run sudo systemctl reboot
	else
		log "reboot later with: sudo systemctl reboot"
	fi
}

# A dry run shows the script's own --dry-run output instead of running sudo.
dry_forward() { # script
	log "would run: sudo bash $SELF_DIR/$1 --dry-run"
	bash "$SELF_DIR/$1" --dry-run || log "(dry run of $1 is not possible yet, rc=$?)"
}

# --- install --------------------------------------------------------------
verify_install() {
	local krel failed=0
	krel=$(uname -r)
	check() { # description, command...
		local d=$1; shift
		if "$@"; then log "ok      $d"; else log "FAILED  $d"; failed=1; fi
	}
	check "modprobe resolves amdgpu to updates/" \
		bash -c "modprobe --show-depends amdgpu 2>/dev/null | grep -q /updates/amdgpu.ko"
	check "marker $HOME/.hdmi-frl-enabled" test -f "$HOME/.hdmi-frl-enabled"
	check "/etc/default/grub.d/hdmi-frl.cfg" test -f /etc/default/grub.d/hdmi-frl.cfg
	check "hdmi-frl-grub.service enabled" systemctl is-enabled -q hdmi-frl-grub.service
	check "hdmi-frl-resume.service enabled" systemctl is-enabled -q hdmi-frl-resume.service
	check "/etc/atomic-update.conf.d/hdmi-frl.conf" test -f /etc/atomic-update.conf.d/hdmi-frl.conf
	if sudo -n grep -qs 'amdgpu.dcfeaturemask=0x402' /efi/EFI/steamos/grub.cfg; then
		log "ok      grub.cfg carries amdgpu.dcfeaturemask=0x402"
	else
		warn "could not find amdgpu.dcfeaturemask=0x402 in /efi/EFI/steamos/grub.cfg (path unverified)"
	fi
	[ "$failed" = 0 ] || die "verification failed for $krel"
}

do_install() {
	log "first run downloads about 3.4 GB of kernel source, extracting it takes a few"
	log "minutes, and the build takes about 2-4 minutes"
	ask "Proceed with the install?" y || exit 4
	start_keepalive

	STEP=1; log "step 1/5: build the patched amdgpu module"
	if module_is_current; then
		log "out/ already holds a module for $(uname -r) built from these patches, not rebuilding"
		log "(HDMI21_REBUILD=1 forces a rebuild)"
	else
		run bash "$SELF_DIR/build.sh"
	fi

	STEP=2; log "step 2/5: install the module"
	if [ "$DRY" = 1 ]; then dry_forward install.sh; else sudo bash "$SELF_DIR/install.sh"; fi

	STEP=3; log "step 3/5: install the self-heal units"
	if [ "$DRY" = 1 ]; then dry_forward setup-selfheal.sh; else sudo bash "$SELF_DIR/setup-selfheal.sh"; fi

	STEP=4; log "step 4/5: switch grub to FRL"
	run sudo sh "$SELF_DIR/hdmi-mode.sh" frl

	STEP=5; log "step 5/5: verify"
	if [ "$DRY" = 1 ]; then
		log "would verify: updates/ module, marker, grub drop-in, units, atomic keep list"
	else
		verify_install
	fi
	STEP=0

	log "installed"
	if [ "$DRY" = 0 ]; then sh "$SELF_DIR/hdmi-mode.sh" status; fi
	log "next steps: after the reboot pick 3840x2160 at 144 Hz and turn on HDR in"
	log "Steam Settings > Display. Check with: bash $SELF_DIR/setup.sh status"
	offer_reboot "load the patched module"
}

# --- uninstall ------------------------------------------------------------
do_uninstall() {
	local del_default=n
	resolve_install_dir
	log "install dir $INSTALL_DIR"
	ask "Remove HDMI 2.1 FRL (stock module, TMDS, self-heal units)?" y || exit 4
	start_keepalive

	STEP=1; log "step 1/4: stop a running rebuild"
	if systemctl is-active -q hdmi-frl-rebuild 2>/dev/null; then
		run sudo systemctl stop hdmi-frl-rebuild
	else
		log "no rebuild running"
	fi

	STEP=2; log "step 2/4: back to TMDS in grub"
	run sudo sh "$SELF_DIR/hdmi-mode.sh" tmds

	STEP=3; log "step 3/4: remove the patched module"
	if [ "$DRY" = 1 ]; then dry_forward uninstall.sh; else sudo bash "$SELF_DIR/uninstall.sh"; fi

	STEP=4; log "step 4/4: remove the self-heal units"
	if [ "$DRY" = 1 ]; then dry_forward setup-selfheal.sh; else sudo bash "$SELF_DIR/setup-selfheal.sh" --remove; fi
	STEP=0

	if [ -d "$CACHE_DIR" ] && ask "Delete the build cache $CACHE_DIR (about 7 GB)?" y; then
		run sudo rm -rf "$CACHE_DIR"
	fi

	log "the kernel headers and base-devel stay until the next SteamOS update"
	log "the log stays at $LOG"

	if [ -e "$INSTALL_DIR/$MARKER_FILE" ]; then del_default=y; fi
	[ ! -d "$INSTALL_DIR/.git" ] || del_default=n
	if [ -d "$INSTALL_DIR" ] && printf '%s\n' "$INSTALL_DIR" | grep -qE '^/home/[^/]+/.+' \
		&& ask "Delete $INSTALL_DIR?" "$del_default"; then
		# Last thing that touches the disk: this script may live in this directory.
		run sudo rm -rf "$INSTALL_DIR"
	fi

	log "removed"
	offer_reboot "go back to the stock amdgpu module"
}

# --- status ---------------------------------------------------------------
do_status() {
	local k vm unit
	k=$(uname -r)
	resolve_install_dir
	echo "version     $VERSION"
	echo "install dir $INSTALL_DIR"
	echo "kernel      $k"
	if [ -f "$INSTALL_DIR/out/amdgpu-$k.ko.zst.vermagic" ]; then
		vm=$(cat "$INSTALL_DIR/out/amdgpu-$k.ko.zst.vermagic")
		echo "built       $vm"
	else
		echo "built       no module for this kernel in $INSTALL_DIR/out"
	fi
	sh "$SELF_DIR/hdmi-mode.sh" status || true
	for unit in hdmi-frl-grub hdmi-frl-resume hdmi-frl-rebuild; do
		printf '%-18s enabled=%s active=%s\n' "$unit" \
			"$(systemctl is-enabled "$unit" 2>/dev/null || true)" \
			"$(systemctl is-active "$unit" 2>/dev/null || true)"
	done
	journalctl -u hdmi-frl-grub -b -n 5 2>/dev/null || true
	for unit in modetest edid-decode; do
		if command -v "$unit" >/dev/null 2>&1; then echo "$unit present"; else echo "$unit missing"; fi
	done
}

# --- main -----------------------------------------------------------------
case "$CMD" in
	status) do_status ;;
	uninstall)
		preflight_basic
		start_logging
		do_uninstall ;;
	install)
		preflight_basic
		if [ "${HDMI21_RELOCATED:-0}" != 1 ]; then relocate; fi
		start_logging
		normalise_modes "$SELF_DIR"
		preflight_install
		do_install ;;
esac
