#!/usr/bin/env bash
# One-step installer for HDMI 2.1 FRL with VRR on the Valve Steam Machine.
# Run it as the deck user, without sudo: it asks for the password itself.
#
#   setup.sh install|uninstall|status [--yes|-y] [--no-reboot] [--dir DIR]
#            [--dry-run] [--json] [-h|--help]
#   setup.sh allm disabled|dynamic|always-on|default [--yes|-y] [--no-reboot]
#            [--dry-run]
#
#   install    build the patched amdgpu module, install it and the self-heal
#              units, switch grub to FRL, then offer a reboot
#   uninstall  undo all of that (TMDS again, stock module, units removed)
#   status     show what is installed and running; changes nothing
#   allm       choose the HDMI ALLM default of the patched module for the next
#              boot (default: the module's own default, always on)
#
#   --json      with status: print one JSON object (schema 1) instead of text;
#               for tools such as the Decky plugin, see "Status as JSON" in the
#               README
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
ALLM_ARG=""
YES=0
NO_REBOOT=0
DRY=0
JSON=0
DIR_ARG=${HDMI21_DIR:-}
LOG=${HDMI21_LOG:-$HOME/steam-machine-hdmi21-setup.log}
VERSION=$(cat "$SELF_DIR/VERSION" 2>/dev/null || echo unknown)

UNIT_PATH=/etc/systemd/system/hdmi-frl-grub.service
CACHE_DIR=$HOME/.cache/steam-machine-hdmi21
MARKER_FILE=.installed-by-setup
SB_VAR=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
MIRROR_URL=https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources/
EXEC_FILES="build.sh install.sh uninstall.sh hdmi-mode.sh hdmi-allm.sh setup-selfheal.sh setup.sh get.sh
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
usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
usage_error() { printf '[setup] %s (see --help)\n' "$*" >&2; exit 2; }
run() {
	if [ "$DRY" = 1 ]; then log "would run: $*"; else "$@"; fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		install|uninstall|status|allm)
			[ -z "$CMD" ] || usage_error "more than one command given: $CMD and $1"
			CMD=$1; shift ;;
		--yes|-y) YES=1; shift ;;
		--no-reboot) NO_REBOOT=1; shift ;;
		--dry-run) DRY=1; shift ;;
		--json) JSON=1; shift ;;
		--dir)
			[ $# -ge 2 ] || usage_error "--dir needs a path"
			DIR_ARG=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*)
			if [ "$CMD" = allm ] && [ -z "$ALLM_ARG" ] && [[ $1 != -* ]]; then
				ALLM_ARG=$1; shift
			else
				usage_error "unknown argument: $1"
			fi ;;
	esac
done
[ -n "$CMD" ] || usage_error "no command given (install, uninstall, status or allm)"
if [ "$CMD" = allm ]; then
	case "$ALLM_ARG" in
		disabled|dynamic|always-on|default) ;;
		'') usage_error "allm needs disabled, dynamic, always-on or default" ;;
		*) usage_error "unknown ALLM mode: $ALLM_ARG (use disabled, dynamic, always-on or default)" ;;
	esac
fi
[ "$JSON" = 0 ] || [ "$CMD" = status ] || usage_error "--json only works with status"

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

	STEP=2; log "step 2/4: back to TMDS and the default ALLM setting in grub"
	run sudo sh "$SELF_DIR/hdmi-mode.sh" tmds
	run sudo sh "$SELF_DIR/hdmi-allm.sh" default

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

# --- allm -----------------------------------------------------------------
do_allm() {
	local k
	k=$(uname -r)
	if [ "$DRY" = 0 ] && [ ! -f "/lib/modules/$k/updates/amdgpu.ko.zst" ]; then
		warn "the patched amdgpu module is not installed for $k; the setting is stored and used once it is"
	fi
	log "ALLM default: $ALLM_ARG"
	run sudo sh "$SELF_DIR/hdmi-allm.sh" "$ALLM_ARG"
	log "only the patched amdgpu module reads this setting, and the TV needs its"
	log "Instant Game Response (ALLM) option on"
	offer_reboot "apply the ALLM setting"
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
	sh "$SELF_DIR/hdmi-allm.sh" status || true
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

# --- status json ----------------------------------------------------------
# status --json prints one JSON object (schema 1) and nothing else on stdout:
# no log(), every probe tolerates a missing tool or file, diagnostics go into
# "warnings". It does not call hdmi-mode.sh or preflight_basic, and as root it
# never falls back to $HOME for install_dir or state_dir.
#
# rebuild.state is read from the journal of this boot and depends on the log
# strings of selfheal/hdmi-frl-selfheal.sh and hdmi-frl-resume.sh: lines that
# start with "hdmi-frl: ", "rebuild complete", "ERROR" and "rebuilding inline".
# Change them together.
REBUILD_UNIT=${HDMI21_REBUILD_UNIT:-hdmi-frl-rebuild}
# Test-only overrides, the same ones selfheal/hdmi-frl-resume.sh honours (the
# link probe below inherits them from the environment).
JSON_SYSFS=${HDMI_FRL_TEST_SYSFS:-/sys/class/drm}
JSON_DEBUGFS=${HDMI_FRL_TEST_DEBUGFS:-/sys/kernel/debug/dri}
JSON_WARN=""
UJ=""
UJ_ACTIVE=""

t5() { if command -v timeout >/dev/null 2>&1; then timeout 5 "$@"; else "$@"; fi; }

# Printable ASCII only, then escape backslash, double quote and tab.
json_str() {
	local s=$1 bs=\\ q='"' tab=$'\t'
	s=$(printf '%s' "$s" | LC_ALL=C tr -cd '\11\40-\176')
	s=${s//"$bs"/"$bs$bs"}
	s=${s//"$q"/"$bs$q"}
	s=${s//"$tab"/"${bs}t"}
	printf '"%s"' "$s"
}
json_nstr() { if [ -n "$1" ]; then json_str "$1"; else printf 'null'; fi; }
json_bool() { if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi; }
json_tri() { case "$1" in 1) printf 'true' ;; 0) printf 'false' ;; *) printf 'null' ;; esac; }
json_int_or_null() {
	case "$1" in
		''|*[!0-9]*) printf 'null' ;;
		*) printf '%s' "$((10#$1))" ;;
	esac
}
json_num_or_null() {
	if [[ $1 =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}
add_warn() { JSON_WARN="${JSON_WARN:+$JSON_WARN,}$(json_str "$1")"; }

# Classifies the link with the rules of selfheal/hdmi-frl-resume.sh (the
# 1.0.1 link rules), not a copy of them. The script is sourced in a child
# process: it defines log/die/usage and its own thresholds, which must not
# replace setup.sh's. The script is passed as $1 because while $0 equals the
# sourced file it would run its main instead of just defining functions.
# modetest -e -c -p output, already captured by the caller, comes in on stdin
# and stands in for modetest inside the child, so the display is queried once.
# Prints key=value lines; fails when the script is missing or the child fails.
# $1 = card number, $2 = sysfs name, $3 = connector name
link_probe() {
	local script=$SELF_DIR/selfheal/hdmi-frl-resume.sh
	[ -r "$script" ] || return 1
	# shellcheck disable=SC2016 # the child expands these, not this shell
	t5 bash -c '
		mt=$(cat)
		modetest() { [ -n "$mt" ] && printf "%s\n" "$mt"; }
		. "$1" || exit 1
		read_link_state "$2" "$3" "$4"
		printf "state=%s\nrule=%s\ndump=%s\nmax_khz=%s\nactive_khz=%s\nfrl_only_khz=%s\n" \
			"$STATE" "$RULE" "$DUMP" "$MAX_KHZ" "$ACTIVE_KHZ" "$FRL_ONLY_KHZ"
		printf "hpo_header=%s\nhpo_row=%s\nhpo_rows=%s\n" "$HPO_HEADER" \
			"$(printf "%s\n" "$HPO_ROWS" | sed -n 1p)" \
			"$(printf "%s" "$HPO_ROWS" | awk "END { print NR }")"
	' _ "$script" "$1" "$2" "$3"
}

# Reads modetest -e -c -p on stdin and prints "name<TAB>value" for every
# property of connector $1. Enums are resolved to their names, ranges stay
# numbers and blobs are their bytes as one hex string (empty for an empty blob).
# An enum list reads "Disabled=0 Dynamic=1 Always On=2": split on "=", the first
# piece is the first name and every later piece is "N next-name".
modetest_connector_props() { # connector
	awk -v conn="$1" '
		function flush(   v, n, t, i, sp, num, nm, nx) {
			if (name == "") return
			v = val
			if (kind == "blob") v = blob
			else if (kind == "enum") {
				n = split(enums, t, "=")
				nm = t[1]
				for (i = 2; i <= n; i++) {
					if (i < n) { sp = index(t[i], " "); num = substr(t[i], 1, sp - 1); nx = substr(t[i], sp + 1) }
					else { num = t[i]; nx = "" }
					if (num == val) { v = nm; break }
					nm = nx
				}
			}
			print name "\t" v
			name = ""
		}
		/^Connectors:/ { sect = "conn"; next }
		/^(Encoders|CRTCs|Planes|Frame buffers):/ { flush(); sect = ""; want = 0; next }
		sect != "conn" { next }
		/^[0-9]/ && ($3 == "connected" || $3 == "disconnected" || $3 == "unknown") {
			flush(); want = ($4 == conn); inprops = 0; next
		}
		!want { next }
		/^[ \t]*props:/ { inprops = 1; next }
		!inprops { next }
		/^\t[0-9]+ / {
			flush()
			name = $0; sub(/^\t[0-9]+ /, "", name); sub(/:[ \t]*$/, "", name)
			kind = ""; val = ""; enums = ""; blob = ""; inblob = 0
			next
		}
		/^\t\tflags:/ { kind = ($0 ~ /blob/) ? "blob" : (($0 ~ /enum/) ? "enum" : "num"); next }
		/^\t\tenums:/ { enums = $0; sub(/^\t\tenums:[ \t]*/, "", enums); next }
		/^\t\tvalue:/ { val = $0; sub(/^\t\tvalue:[ \t]*/, "", val); sub(/[ \t\r]+$/, "", val); inblob = 1; next }
		inblob && /^\t\t\t[0-9a-fA-F]+[ \t\r]*$/ { b = $0; gsub(/[ \t\r]/, "", b); blob = blob b; next }
		END { flush() }
	'
}

# Reads modetest -e -c -p on stdin and prints the index of the CRTC that
# connector $1 is driven by: its encoder's CRTC, as a position in the CRTCs:
# list. That is the N of the debugfs crtc-N directory. Prints nothing when the
# connector has no encoder or the CRTC is not listed.
modetest_crtc_index() { # connector
	awk -v conn="$1" '
		/^Encoders:/ { sect = "enc"; next }
		/^Connectors:/ { sect = "conn"; next }
		/^CRTCs:/ { sect = "crtc"; next }
		/^Planes:/ { sect = "plane"; next }
		sect == "enc" && $1 ~ /^[0-9]+$/ && NF >= 3 { enc[$1] = $2; next }
		sect == "conn" && $1 ~ /^[0-9]+$/ && ($3 == "connected" || $3 == "disconnected" || $3 == "unknown") {
			if ($4 == conn) cenc = $2
			next
		}
		sect == "crtc" && $1 ~ /^[0-9]+$/ && $3 ~ /^\(/ { idx[$1] = n++; next }
		END { if ((cenc in enc) && (enc[cenc] in idx)) print idx[enc[cenc]] }
	'
}

# Splits one HPO table (the header line and one row of amdgpu_dm_dtn_log, as
# classify_dtn_log header|rows prints them) by column name and prints
# "pixel_format=..." and "depth=...". The columns are found by name, never by
# position: the header is cut on runs of two or more spaces (names such as
# "Pixel Format" hold one), the row on whitespace. Fails when the two do not
# have the same number of cells.
hpo_fields() { # header row
	awk -v h="$1" -v r="$2" 'BEGIN {
		sub(/^HPO:[ \t]*/, "", h); sub(/[ \t\r]+$/, "", h)
		sub(/^\[[ 0-9]+\]:[ \t]*/, "", r); sub(/[ \t\r]+$/, "", r)
		n = split(h, hn, /  +/); m = split(r, rv, /[ \t]+/)
		if (n == 0 || n != m) exit 1
		for (i = 1; i <= n; i++) {
			if (hn[i] == "Pixel Format") print "pixel_format=" rv[i]
			else if (hn[i] == "Depth") print "depth=" rv[i]
		}
	}'
}

# Works out the signal fields of the connected display. Called from
# do_status_json and writes its locals (bash scoping): s_model, s_chroma,
# s_chroma_src, s_bpc, s_bpc_src, s_colorimetry, hdr_active, hdr_eotf,
# content_type and the allm_* values.
derive_display() {
	local hf hp_fmt="" hp_depth="" bf cf txt crtc_bpc="" crtc_cs="" byte

	if [ -n "$l_hpo_row" ] && [ -n "$l_hpo_header" ]; then
		if [[ $l_hpo_rows =~ ^[0-9]+$ ]] && [ "$l_hpo_rows" -gt 1 ]; then
			add_warn "the HPO table has $l_hpo_rows rows: using the first"
		fi
		hf=$(hpo_fields "$l_hpo_header" "$l_hpo_row" 2>/dev/null) || hf=""
		hp_fmt=$({ printf '%s\n' "$hf" | sed -n 's/^pixel_format=//p'; } || true)
		hp_depth=$({ printf '%s\n' "$hf" | sed -n 's/^depth=//p'; } || true)
		case "$hp_fmt" in 4:4:4|4:2:2|4:2:0) ;; *) hp_fmt="" ;; esac
		[[ $hp_depth =~ ^[0-9]+$ ]] || hp_depth=""
		if [ -z "$hp_fmt" ] || [ -z "$hp_depth" ]; then
			add_warn "the HPO row could not be read by column name"
		fi
	fi

	if [ -n "$d_crtc" ]; then
		bf=$JSON_DEBUGFS/$d_card/crtc-$d_crtc/amdgpu_current_bpc
		cf=$JSON_DEBUGFS/$d_card/crtc-$d_crtc/amdgpu_current_colorspace
		# an idle CRTC fails with ENODEV, which reads as nothing
		if [ -r "$bf" ]; then
			txt=$(cat "$bf" 2>/dev/null || true)
			if [[ $txt =~ ^Current:[[:space:]]*([0-9]+) ]]; then crtc_bpc=${BASH_REMATCH[1]}; fi
		fi
		if [ -r "$cf" ]; then
			txt=$(cat "$cf" 2>/dev/null || true)
			crtc_cs=$(printf '%s' "$txt" | LC_ALL=C tr -cd 'A-Za-z0-9_')
		fi
		if [ "$as_root" = 0 ] && [ ! -r "$bf" ] && [ ! -r "$cf" ]; then
			add_warn "not root: pixel format, bit depth and colorimetry (debugfs) cannot be read"
		fi
	fi

	# bit depth: the HPO table is the encoder's own word, the CRTC the fallback
	if [ -n "$hp_depth" ]; then
		s_bpc=$hp_depth; s_bpc_src=hpo
		if [ -n "$crtc_bpc" ] && [ "$crtc_bpc" != "$hp_depth" ]; then
			add_warn "bit depth: the HPO table says $hp_depth but the CRTC says $crtc_bpc; using the HPO table"
		fi
	elif [ -n "$crtc_bpc" ]; then
		s_bpc=$crtc_bpc; s_bpc_src=crtc
	fi

	# colour model: the driver picks the colorspace by encoding only for Default
	# and BT2020, so a BT601/BT709 YCC reading counts only while the connector
	# Colorspace property is Default
	case "$crtc_cs" in
		sRGB|BT2020_RGB) s_model=rgb ;;
		BT2020_YCC) s_model=ycbcr ;;
		BT601_YCC|BT709_YCC) if [ "$p_cs" = Default ]; then s_model=ycbcr; fi ;;
	esac
	[ -z "$crtc_cs" ] || s_colorimetry=$crtc_cs

	# chroma: the HPO table, else what the link or the colour model implies
	if [ -n "$hp_fmt" ]; then
		s_chroma=$hp_fmt; s_chroma_src=hpo
	elif [ "$l_state" = tmds ]; then
		s_chroma=4:2:0; s_chroma_src=tmds-clock
	elif [ "$s_model" = rgb ]; then
		s_chroma=4:4:4; s_chroma_src=rgb
	fi
	if [ "$s_model" = rgb ] && { [ "$s_chroma" = 4:2:0 ] || [ "$s_chroma" = 4:2:2 ]; }; then
		s_model=""
		add_warn "colour model: the colorspace reads RGB but the link carries $s_chroma; colour model left unknown"
	fi

	# HDR: byte 4 of HDR_OUTPUT_METADATA is the EOTF (after the 4-byte type)
	if [ "$p_hdr" = - ]; then
		:
	elif [ -z "$p_hdr" ]; then
		hdr_active=0
	elif [[ $p_hdr =~ ^[0-9a-fA-F]{10,}$ ]]; then
		byte=$((16#${p_hdr:8:2}))
		if [ "$byte" -ge 1 ]; then hdr_active=1; else hdr_active=0; fi
		case "$byte" in 0) hdr_eotf=sdr ;; 1) hdr_eotf=hdr_gamma ;; 2) hdr_eotf=pq ;; 3) hdr_eotf=hlg ;; esac
	fi

	case "$p_ct" in
		"No Data") content_type=no_data ;;
		Graphics) content_type=graphics ;;
		Photo) content_type=photo ;;
		Cinema) content_type=cinema ;;
		Game) content_type=game ;;
	esac
}

unit_env() { # VAR: value from the installed hdmi-frl-grub.service
	{ sed -n "s/^Environment=$1=//p" "$UNIT_PATH" 2>/dev/null | head -1; } || true
}

# unit Environment=STATE_DIR= -> $STATE_DIR -> $SUDO_USER's home -> the home of
# the user who owns the install dir -> $HOME. Where the marker file lives.
resolve_state_dir() { # install dir
	local d u
	d=$(unit_env STATE_DIR)
	[ -n "$d" ] || d=${STATE_DIR:-}
	if [ -z "$d" ] && [ -n "${SUDO_USER:-}" ]; then
		d=$({ getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6; } || true)
	fi
	if [ -z "$d" ] && [ -d "$1" ]; then
		u=$(stat -c %U "$1" 2>/dev/null || true)
		if [ -n "$u" ]; then d=$({ getent passwd "$u" 2>/dev/null | cut -d: -f6; } || true); fi
	fi
	[ -n "$d" ] || d=${HOME:-}
	printf '%s' "${d%/}"
}

# The same test as hdmi-frl-resume.sh: bit 0x400 of the last dcfeaturemask.
frl_mask_has() { # mask
	[[ $1 =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 1
	( if (( ($1 & 0x400) != 0 )); then exit 0; else exit 1; fi ) 2>/dev/null
}

# This boot's output of the unit's own processes. A plain -u would also return
# the messages systemd (PID 1) logs about the unit ("Deactivated successfully."),
# which are not the last line of the script; the _SYSTEMD_UNIT match is not.
unit_journal() { # unit
	local n=$1
	case "$n" in *.*) ;; *) n=$n.service ;; esac
	t5 journalctl -b "_SYSTEMD_UNIT=$n" -o cat -q --no-pager 2>/dev/null
}

# Sets UJ to the unit object and UJ_ACTIVE to its ActiveState. A transient unit
# that has finished is gone (--collect): LoadState not-found is normal.
unit_json() { # unit
	local out line load="" ufs="" act="" sub="" res=""
	UJ_ACTIVE=""
	if command -v systemctl >/dev/null 2>&1; then
		out=$(t5 systemctl show -p LoadState -p UnitFileState -p ActiveState -p SubState -p Result "$1" 2>/dev/null || true)
		while IFS= read -r line; do
			case "$line" in
				LoadState=*) load=${line#*=} ;;
				UnitFileState=*) ufs=${line#*=} ;;
				ActiveState=*) act=${line#*=} ;;
				SubState=*) sub=${line#*=} ;;
				Result=*) res=${line#*=} ;;
			esac
		done <<EOF
$out
EOF
	fi
	UJ_ACTIVE=$act
	UJ="{\"load\":$(json_str "$load"),\"enabled\":$(json_str "$ufs"),\"active\":$(json_str "$act"),\"sub\":$(json_str "$sub"),\"result\":$(json_str "$res")}"
}

do_status_json() {
	local k now boot_id as_root installed install_dir state_dir
	local marker dropin configured running cmdline mask consistent
	local zst bmod=0 bvm="" bmatch=0
	local upd m_inst=0 m_vm="" m_match=0 m_res=0 m_loaded=0 m_taint=0 m_after=0
	local m_srcmatch="" m_state=stock fn ls fs btime mt ed
	local p d_sys="" d_conn="" d_card="" d_connected=0 d_clock="" d_vrr="" d_frl="" d_sink=""
	local probe line l_state="" l_rule="" l_dump="" l_max="" l_active="" l_frl_only=""
	local l_hpo_header="" l_hpo_row="" l_hpo_rows="" mt props pk pv d_crtc=""
	local p_cs="" p_ct="" p_hdr=- p_allm_cap="" p_allm_mode=""
	local s_model="" s_chroma="" s_chroma_src="" s_bpc="" s_bpc_src="" s_colorimetry=""
	local hdr_active="" hdr_eotf="" content_type="" allm_mode=""
	local cm cm_name cm_hz d_mode="null" vr vtxt vmin vmax vrr_range="null"
	local tools_modetest=0 tools_edid=0 jreadable=0
	local u_grub u_resume u_rebuild a_grub a_rebuild
	local src rb_state=idle rb_h="" rb_l="" grubj jout
	local reasons="" reason_txt="" reboot_needed=0 sep

	k=$(uname -r 2>/dev/null || true)
	now=$(date +%s 2>/dev/null || true)
	boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
	as_root=0; [ "$(id -u 2>/dev/null || true)" = 0 ] && as_root=1
	installed=0; [ -e "$UNIT_PATH" ] && installed=1
	command -v modetest >/dev/null 2>&1 && tools_modetest=1
	command -v edid-decode >/dev/null 2>&1 && tools_edid=1

	install_dir=$(unit_env HDMI_FRL_REPO)
	[ -n "$install_dir" ] || install_dir=${DIR_ARG:-$SELF_DIR}
	install_dir=${install_dir%/}
	state_dir=$(resolve_state_dir "$install_dir")

	# build output for this kernel
	zst=$install_dir/out/amdgpu-$k.ko.zst
	[ -f "$zst" ] && bmod=1
	if [ -f "$zst.vermagic" ]; then
		bvm=$(head -1 "$zst.vermagic" 2>/dev/null || true)
	elif [ "$bmod" = 1 ] && command -v modinfo >/dev/null 2>&1; then
		bvm=$({ modinfo -F vermagic "$zst" 2>/dev/null | head -1; } || true)
	fi
	[ "$bmod" = 1 ] && [ -n "$k" ] && [ "${bvm%% *}" = "$k" ] && bmatch=1

	# link mode: running (cmdline), configured (marker), grub drop-in
	cmdline=$(cat /proc/cmdline 2>/dev/null || true)
	mask=$({ printf '%s\n' "$cmdline" | tr -s '[:space:]' '\n' | sed -n 's/^amdgpu\.dcfeaturemask=//p' | tail -1; } || true)
	running=TMDS
	if [ -n "$mask" ] && frl_mask_has "$mask"; then running=FRL; fi
	marker=0; [ -f "$state_dir/.hdmi-frl-enabled" ] && marker=1
	dropin=0; [ -f /etc/default/grub.d/hdmi-frl.cfg ] && dropin=1
	configured=TMDS; [ "$marker" = 1 ] && configured=FRL
	consistent=0; [ "$marker" = "$dropin" ] && consistent=1

	# amdgpu module: installed override vs the one that is loaded
	upd=/lib/modules/$k/updates/amdgpu.ko.zst
	[ -f "$upd" ] && m_inst=1
	if command -v modinfo >/dev/null 2>&1; then
		if [ "$m_inst" = 1 ]; then
			m_vm=$({ modinfo -F vermagic "$upd" 2>/dev/null | head -1; } || true)
		fi
		fn=$({ modinfo -F filename amdgpu 2>/dev/null | head -1; } || true)
		case "$fn" in */updates/amdgpu.ko*) m_res=1 ;; esac
	fi
	[ "$m_inst" = 1 ] && [ -n "$k" ] && [ "${m_vm%% *}" = "$k" ] && m_match=1
	[ -d /sys/module/amdgpu ] && m_loaded=1
	case "$(cat /sys/module/amdgpu/taint 2>/dev/null || true)" in *O*) m_taint=1 ;; esac
	if [ "$m_inst" = 1 ]; then
		btime=$({ awk '$1 == "btime" { print $2 }' /proc/stat 2>/dev/null; } || true)
		mt=$(stat -c %Y "$upd" 2>/dev/null || true)
		case "$btime$mt" in
			''|*[!0-9]*) ;;
			*) [ -n "$btime" ] && [ -n "$mt" ] && [ "$mt" -ge "$btime" ] && m_after=1 ;;
		esac
		if [ "$m_loaded" = 1 ] && command -v modinfo >/dev/null 2>&1; then
			ls=$(cat /sys/module/amdgpu/srcversion 2>/dev/null || true)
			fs=$({ modinfo -F srcversion "$upd" 2>/dev/null | head -1; } || true)
			if [ -n "$ls" ] && [ -n "$fs" ]; then
				if [ "$ls" = "$fs" ]; then m_srcmatch=1; else m_srcmatch=0; fi
			fi
		fi
		if [ "$m_srcmatch" = 1 ] || { [ -z "$m_srcmatch" ] && [ "$m_taint" = 1 ] && [ "$m_after" = 0 ]; }; then
			m_state=patched-loaded
		else
			m_state="installed-needs-reboot"
		fi
	fi

	# display: the first connected HDMI connector, else the first one
	for p in "$JSON_SYSFS"/card*-HDMI-A-*; do
		[ -e "$p" ] || continue
		[ -n "$d_sys" ] || d_sys=${p##*/}
		if [ "$(cat "$p/status" 2>/dev/null || true)" = connected ]; then d_sys=${p##*/}; break; fi
	done
	if [ -n "$d_sys" ]; then
		d_card=${d_sys%%-*}
		d_conn=${d_sys#"$d_card"-}
		d_card=${d_card#card}
		[ "$(cat "$JSON_SYSFS/$d_sys/status" 2>/dev/null || true)" = connected ] && d_connected=1
	fi
	# one modetest run feeds the link probe, the connector properties, the CRTC
	# index and the current mode
	if [ "$tools_modetest" = 1 ] && [ -n "$d_conn" ]; then
		mt=$(t5 modetest -M amdgpu -e -c -p 2>/dev/null || true)
	else
		mt=""
	fi
	if [ "$tools_modetest" = 0 ]; then
		add_warn "modetest is missing: display, VRR and ALLM fields are unavailable"
	fi
	if [ -n "$d_sys" ]; then
		if probe=$(link_probe "$d_card" "$d_sys" "$d_conn" 2>/dev/null <<< "$mt"); then
			while IFS= read -r line; do
				case ${line%%=*} in
					state) l_state=${line#*=} ;;
					rule) l_rule=${line#*=} ;;
					dump) l_dump=${line#*=} ;;
					max_khz) l_max=${line#*=} ;;
					active_khz) l_active=${line#*=} ;;
					frl_only_khz) l_frl_only=${line#*=} ;;
					hpo_header) l_hpo_header=${line#*=} ;;
					hpo_row) l_hpo_row=${line#*=} ;;
					hpo_rows) l_hpo_rows=${line#*=} ;;
				esac
			done <<< "$probe"
			case "$l_state" in frl|tmds|unknown) ;; *) l_state="" ;; esac
			[ "$l_active" != 0 ] || l_active=""
			# modetest unavailable or failed reads as a highest mode of 0
			if [[ $l_max =~ ^[1-9][0-9]*$ ]]; then
				d_clock=$l_max
				if [ "$d_connected" = 1 ] && [[ $l_frl_only =~ ^[0-9]+$ ]]; then
					if [ "$l_max" -gt "$l_frl_only" ]; then d_frl=1; else d_frl=0; fi
				fi
			fi
		else
			add_warn "the link state could not be classified: selfheal/hdmi-frl-resume.sh is missing or its probe failed"
		fi
	fi
	if [ -n "$mt" ]; then
		props=$(printf '%s\n' "$mt" | modetest_connector_props "$d_conn")
		while IFS=$'\t' read -r pk pv; do
			case "$pk" in
				vrr_capable) d_vrr=$pv ;;
				Colorspace) p_cs=$pv ;;
				"content type") p_ct=$pv ;;
				HDR_OUTPUT_METADATA) p_hdr=$pv ;;
				allm_capable) p_allm_cap=$pv ;;
				allm_mode) p_allm_mode=$pv ;;
			esac
		done <<< "$props"
		case "$d_vrr" in 0|1) ;; *) d_vrr="" ;; esac
		d_crtc=$(printf '%s\n' "$mt" | modetest_crtc_index "$d_conn")
		if [ "$d_connected" = 1 ]; then
			# same CRTC/mode pairing as hdmi-mode.sh status: the mode line after
			# the CRTC at (0,0); a CRTC without a mode (0x0) is skipped
			cm=$(printf '%s\n' "$mt" | awk '
				/^[0-9]+[ \t]+[0-9]+[ \t]+\(0,0\)/ { grab = 1; next }
				grab && $1 ~ /^#[0-9]+$/ {
					split($2, a, "x")
					if (a[1] + 0 > 0) { print $2, $3; exit }
				}
				grab { grab = 0 }
			') || true
			read -r cm_name cm_hz <<< "$cm"
			if [[ $cm_name =~ ^([0-9]+)x([0-9]+) ]]; then
				d_mode="{\"width\":${BASH_REMATCH[1]},\"height\":${BASH_REMATCH[2]},\"refresh_hz\":$(json_num_or_null "$cm_hz"),\"name\":$(json_str "$cm_name")}"
			fi
		fi
	fi
	if [ "$d_connected" = 1 ]; then derive_display; fi
	if [ "$d_connected" = 1 ]; then
		if [ "$tools_edid" = 1 ] && [ -s "$JSON_SYSFS/$d_sys/edid" ]; then
			ed=$(t5 edid-decode < "$JSON_SYSFS/$d_sys/edid" 2>/dev/null || true)
			case "$ed" in
				'') ;;
				*"Max Fixed Rate Link"*) d_sink=1 ;;
				*) d_sink=0 ;;
			esac
		fi
	fi
	if [ -n "$d_sys" ]; then
		vr=$JSON_DEBUGFS/$d_card/$d_conn/vrr_range
		if [ -r "$vr" ]; then
			vtxt=$(cat "$vr" 2>/dev/null | tr '\n' ' ' || true)
			vmin=$(printf '%s\n' "$vtxt" | sed -n 's/.*Min: *\([0-9][0-9]*\).*/\1/p')
			vmax=$(printf '%s\n' "$vtxt" | sed -n 's/.*Max: *\([0-9][0-9]*\).*/\1/p')
			if [ -n "$vmin" ] && [ -n "$vmax" ] && [ "$vmax" -gt 0 ]; then
				vrr_range="{\"min_hz\":$vmin,\"max_hz\":$vmax}"
			fi
		elif [ "$as_root" = 0 ]; then
			add_warn "not root: the VRR range (debugfs) cannot be read"
		fi
	fi

	# units
	if ! command -v systemctl >/dev/null 2>&1; then add_warn "systemctl is missing: unit states are unavailable"; fi
	unit_json hdmi-frl-grub; u_grub=$UJ; a_grub=$UJ_ACTIVE
	unit_json hdmi-frl-resume; u_resume=$UJ
	unit_json "$REBUILD_UNIT"; u_rebuild=$UJ; a_rebuild=$UJ_ACTIVE

	# rebuild: the transient unit is gone after it exits, so read this boot's journal
	src=$REBUILD_UNIT
	if command -v journalctl >/dev/null 2>&1; then
		jout=$(t5 journalctl -b -n 1 -o cat -q --no-pager 2>/dev/null || true)
		[ -n "$jout" ] && jreadable=1
	fi
	if [ "$jreadable" = 1 ]; then
		grubj=$(unit_journal hdmi-frl-grub || true)
		case "$grubj" in *"rebuilding inline"*) src=hdmi-frl-grub ;; esac
		jout=$(unit_journal "$src" | awk '/^hdmi-frl: / { h = $0 } NF { l = $0 } END { print h; print l }') || true
		rb_h=$(printf '%s\n' "$jout" | sed -n 1p)
		rb_l=$(printf '%s\n' "$jout" | sed -n 2p)
		rb_l=${rb_l:0:300}
	else
		add_warn "the journal is not readable: the rebuild state may be incomplete"
	fi
	local src_active=$a_rebuild
	[ "$src" = hdmi-frl-grub ] && src_active=$a_grub
	case "$src_active" in
		active|activating|reloading) rb_state=running ;;
		*)
			if [ -z "$rb_h" ]; then
				rb_state=idle
			elif [[ $rb_h == *"rebuild complete"* ]] && [ "$m_inst" = 1 ] && [ "$m_match" = 1 ]; then
				rb_state=succeeded-needs-reboot
			else
				rb_state=failed
			fi ;;
	esac

	# reboot reasons
	sep=""
	if [ "$m_state" = installed-needs-reboot ]; then
		reasons="${reasons}${sep}\"module_installed_not_loaded\""; sep=","
		reason_txt="${reason_txt:+$reason_txt; }the patched amdgpu module is installed but not loaded"
	fi
	if [ "$rb_state" = succeeded-needs-reboot ]; then
		reasons="${reasons}${sep}\"rebuild_succeeded\""; sep=","
		reason_txt="${reason_txt:+$reason_txt; }the patched amdgpu module was rebuilt for this kernel"
	fi
	if [ "$running" != "$configured" ]; then
		reasons="${reasons}${sep}\"mode_configured_differs\""; sep=","
		reason_txt="${reason_txt:+$reason_txt; }the next boot is set to $configured but $running is running"
	fi
	[ -z "$reasons" ] || reboot_needed=1

	case "$p_allm_mode" in
		Disabled) allm_mode=disabled ;;
		Dynamic) allm_mode=dynamic ;;
		"Always On") allm_mode=always_on ;;
	esac

	# one object, one write
	local J
	J="{\"schema\":1,\"version\":$(json_str "$VERSION"),\"generated_at\":$(json_int_or_null "$now"),\"boot_id\":$(json_nstr "$boot_id"),\"as_root\":$(json_bool "$as_root")"
	J="$J,\"install_dir\":$(json_str "$install_dir"),\"state_dir\":$(json_str "$state_dir"),\"installed\":$(json_bool "$installed"),\"kernel\":$(json_str "$k")"
	J="$J,\"build\":{\"module\":$(json_bool "$bmod"),\"vermagic\":$(json_nstr "$bvm"),\"matches_kernel\":$(json_bool "$bmatch")}"
	J="$J,\"mode\":{\"running\":\"$running\",\"cmdline_mask\":$(json_nstr "$mask"),\"configured\":\"$configured\",\"marker\":$(json_bool "$marker"),\"dropin\":$(json_bool "$dropin"),\"consistent\":$(json_bool "$consistent")}"
	J="$J,\"module\":{\"installed\":$(json_bool "$m_inst"),\"installed_vermagic\":$(json_nstr "$m_vm"),\"installed_matches_kernel\":$(json_bool "$m_match"),\"resolves_to_updates\":$(json_bool "$m_res"),\"loaded\":$(json_bool "$m_loaded"),\"taint_o\":$(json_bool "$m_taint"),\"srcversion_match\":$(json_tri "$m_srcmatch"),\"installed_after_boot\":$(json_bool "$m_after"),\"state\":\"$m_state\"}"
	J="$J,\"display\":{\"connector\":$(json_nstr "$d_conn"),\"connected\":$(json_bool "$d_connected"),\"current_mode\":$d_mode,\"max_pixel_clock_khz\":$(json_int_or_null "$d_clock"),\"frl_modes_present\":$(json_tri "$d_frl"),\"sink_frl\":$(json_tri "$d_sink"),\"link\":{\"state\":$(json_nstr "$l_state"),\"rule\":$(json_nstr "$l_rule"),\"dump\":$(json_nstr "$l_dump"),\"active_pixel_clock_khz\":$(json_int_or_null "$l_active")}"
	J="$J,\"pixel\":{\"color_model\":$(json_nstr "$s_model"),\"chroma\":$(json_nstr "$s_chroma"),\"chroma_source\":$(json_nstr "$s_chroma_src"),\"bpc\":$(json_int_or_null "$s_bpc"),\"bpc_source\":$(json_nstr "$s_bpc_src"),\"colorimetry\":$(json_nstr "$s_colorimetry")}"
	J="$J,\"hdr\":{\"active\":$(json_tri "$hdr_active"),\"eotf\":$(json_nstr "$hdr_eotf")},\"content_type\":$(json_nstr "$content_type"),\"content_type_sent\":null}"
	J="$J,\"vrr\":{\"capable\":$(json_tri "$d_vrr"),\"range\":$vrr_range}"
	J="$J,\"allm\":{\"capable\":$(json_tri "$p_allm_cap"),\"mode\":$(json_nstr "$allm_mode"),\"active\":null,\"driver_default\":null,\"configured\":null}"
	J="$J,\"units\":{\"hdmi-frl-grub\":$u_grub,\"hdmi-frl-resume\":$u_resume,\"hdmi-frl-rebuild\":$u_rebuild}"
	J="$J,\"rebuild\":{\"state\":\"$rb_state\",\"last_line\":$(json_nstr "$rb_l"),\"source_unit\":$(json_str "$src"),\"log_command\":$(json_str "journalctl -b -u $REBUILD_UNIT -u hdmi-frl-grub")}"
	J="$J,\"reboot_needed\":$(json_bool "$reboot_needed"),\"reboot_reasons\":[$reasons],\"reboot_reason\":$(json_nstr "$reason_txt")"
	J="$J,\"tools\":{\"modetest\":$(json_bool "$tools_modetest"),\"edid_decode\":$(json_bool "$tools_edid"),\"journal_readable\":$(json_bool "$jreadable")},\"warnings\":[$JSON_WARN]}"
	printf '%s\n' "$J"
}

# --- main -----------------------------------------------------------------
case "$CMD" in
	status) if [ "$JSON" = 1 ]; then do_status_json; else do_status; fi ;;
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
	allm)
		preflight_basic
		start_logging
		do_allm ;;
