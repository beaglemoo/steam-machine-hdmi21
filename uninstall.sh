#!/usr/bin/env bash
# Remove the patched amdgpu module override, restoring the stock module.
#
#   sudo ./uninstall.sh [--dry-run]
#
# Reboot afterwards. This does not change the grub HDMI mode; use
# ./hdmi-mode.sh tmds for that.
set -euo pipefail

DRY=0
log() { printf '[uninstall] %s\n' "$*"; }
die() { printf '[uninstall] ERROR: %s\n' "$*" >&2; exit 1; }
run() {
	if [ "$DRY" = 1 ]; then printf '[uninstall] would run: %s\n' "$*"; else "$@"; fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY=1; shift ;;
		-h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

KREL=$(uname -r)
NEPTUNE=$(printf '%s\n' "$KREL" | grep -o 'neptune-[0-9]\+' | head -1)
KPKG="linux-${NEPTUNE:-neptune}"
TARGET="/lib/modules/$KREL/updates/amdgpu.ko.zst"

[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root (sudo ./uninstall.sh)"

if [ ! -f "$TARGET" ]; then
	log "$TARGET is not installed, nothing to do"
	exit 0
fi
log "removing $TARGET"

PRESET="/etc/mkinitcpio.d/$KPKG.preset"
IMAGE=""
[ -f "$PRESET" ] && IMAGE=$(sed -n 's/^default_image="\?\([^"]*\)"\?$/\1/p' "$PRESET" | head -1)
[ -n "$IMAGE" ] || IMAGE="/boot/initramfs-$KPKG.img"
img_stamp() { [ -f "$IMAGE" ] && stat -c '%Y:%s' "$IMAGE" || echo "none"; }

readonly_enable() { run steamos-readonly enable; }

run steamos-readonly disable
[ "$DRY" = 1 ] || trap readonly_enable EXIT

run rm -f "$TARGET"
run rmdir --ignore-fail-on-non-empty "/lib/modules/$KREL/updates"
run depmod -a "$KREL"

BEFORE=$(img_stamp)
if [ "$DRY" = 1 ]; then
	log "would run: mkinitcpio -P"
else
	rc=0
	mkinitcpio -P || rc=$?
	AFTER=$(img_stamp)
	if [ "$rc" != 0 ]; then
		size=${AFTER##*:}
		if [ "$AFTER" != "$BEFORE" ] && [ "$size" -gt 1000000 ]; then
			log "mkinitcpio exited $rc but wrote $IMAGE - continuing"
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

log "removed. Reboot to go back to the stock amdgpu module."
