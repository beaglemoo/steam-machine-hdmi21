#!/usr/bin/env bash
# Install the patched amdgpu module built by build.sh into
# /lib/modules/$(uname -r)/updates/amdgpu.ko.zst.
#
#   sudo ./install.sh [--dry-run] [--module PATH]
#
# The stock module in kernel/drivers/gpu/drm/amd/amdgpu/ is never touched;
# modules in updates/ simply take precedence. Reboot afterwards.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT_DIR=${OUT_DIR:-$REPO_DIR/out}
DRY=0
MODULE=""

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
run() {
	if [ "$DRY" = 1 ]; then printf '[install] would run: %s\n' "$*"; else "$@"; fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY=1; shift ;;
		--module) MODULE=${2:?--module needs a path}; shift 2 ;;
		-h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

KREL=$(uname -r)
NEPTUNE=$(printf '%s\n' "$KREL" | grep -o 'neptune-[0-9]\+' | head -1)
KPKG="linux-${NEPTUNE:-neptune}"
[ -n "$MODULE" ] || MODULE="$OUT_DIR/amdgpu-$KREL.ko.zst"
TARGET="/lib/modules/$KREL/updates/amdgpu.ko.zst"

[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root (sudo ./install.sh)"
[ -f "$MODULE" ] || die "$MODULE not found - run ./build.sh first"

VERMAGIC=$(modinfo -F vermagic "$MODULE" | head -1)
[ "${VERMAGIC%% *}" = "$KREL" ] \
	|| die "module vermagic '${VERMAGIC%% *}' != running kernel '$KREL' - rebuild with ./build.sh"

log "kernel   $KREL"
log "module   $MODULE ($(stat -c %s "$MODULE") bytes)"
log "vermagic $VERMAGIC"
log "target   $TARGET"

# mkinitcpio writes this image; used to tell a real failure from the harmless
# pre-existing 'module not found: blake2b_generic' error that makes it exit 1.
PRESET="/etc/mkinitcpio.d/$KPKG.preset"
IMAGE=""
[ -f "$PRESET" ] && IMAGE=$(sed -n 's/^default_image="\?\([^"]*\)"\?$/\1/p' "$PRESET" | head -1)
[ -n "$IMAGE" ] || IMAGE="/boot/initramfs-$KPKG.img"

img_stamp() { [ -f "$IMAGE" ] && stat -c '%Y:%s' "$IMAGE" || echo "none"; }

readonly_enable() { run steamos-readonly enable; }

run steamos-readonly disable
[ "$DRY" = 1 ] || trap readonly_enable EXIT

run install -D -m644 "$MODULE" "$TARGET"
run depmod -a "$KREL"

if [ "$DRY" = 0 ]; then
	if modprobe --show-depends amdgpu 2>/dev/null | grep -q "/updates/amdgpu.ko"; then
		log "modprobe now resolves amdgpu to updates/"
	else
		die "modprobe still resolves the stock amdgpu - depmod did not pick up $TARGET"
	fi
else
	log "would run: modprobe --show-depends amdgpu  (must resolve to updates/)"
fi

BEFORE=$(img_stamp)
log "regenerating initramfs ($IMAGE)"
if [ "$DRY" = 1 ]; then
	log "would run: mkinitcpio -P"
else
	rc=0
	mkinitcpio -P || rc=$?
	AFTER=$(img_stamp)
	if [ "$rc" != 0 ]; then
		size=${AFTER##*:}
		if [ "$AFTER" != "$BEFORE" ] && [ "$size" -gt 1000000 ]; then
			log "mkinitcpio exited $rc but wrote $IMAGE ($size bytes) - continuing"
			log "(SteamOS ships a preset referencing blake2b_generic, which does not exist)"
		else
			die "mkinitcpio failed ($rc) and $IMAGE was not written"
		fi
	fi
fi

if [ "$DRY" = 1 ]; then
	readonly_enable
else
	trap - EXIT
	readonly_enable
fi

log "installed. Reboot to load the patched module."
