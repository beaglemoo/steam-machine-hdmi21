#!/bin/sh
# Runs at boot from hdmi-frl-grub.service and re-asserts the HDMI mode chosen
# with hdmi-mode.sh after a SteamOS atomic update has replaced /etc and
# /lib/modules:
#   1. the grub drop-in and the amdgpu.dcfeaturemask=0x402 cmdline
#   2. the patched amdgpu module in /lib/modules/<running>/updates/
#
# If the running kernel changed and no matching module has been built yet, the
# rebuild (build.sh, then install.sh) is started as a detached transient unit
# so that it does not hold up the boot. Follow it with
#   journalctl -fu hdmi-frl-rebuild
#
# Everything keys off the marker file $STATE_DIR/.hdmi-frl-enabled. No marker
# means TMDS was chosen: the drop-in is removed and nothing else happens.
set -u

REPO_DIR=${HDMI_FRL_REPO:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
STATE_DIR=${STATE_DIR:-/home/deck}
MARKER=$STATE_DIR/.hdmi-frl-enabled
DROPIN=/etc/default/grub.d/hdmi-frl.cfg
MASK=amdgpu.dcfeaturemask=0x402
K=$(uname -r)
TARGET=/lib/modules/$K/updates/amdgpu.ko.zst
MODULE=$REPO_DIR/out/amdgpu-$K.ko.zst

log() { echo "hdmi-frl: $*"; }

vermagic_ok() {
	[ -f "$1" ] || return 1
	v=$(modinfo -F vermagic "$1" 2>/dev/null | awk '{print $1}')
	[ "$v" = "$K" ]
}

do_rebuild() {
	log "rebuilding the patched amdgpu module for $K"
	if ! "$REPO_DIR/build.sh"; then log "ERROR build.sh failed"; exit 1; fi
	if ! "$REPO_DIR/install.sh"; then log "ERROR install.sh failed"; exit 1; fi
	log "rebuild complete, reboot to load the patched module"
}

if [ "${1:-}" = "rebuild" ]; then
	do_rebuild
	exit 0
fi

# --- marker ---------------------------------------------------------------
if [ ! -f "$MARKER" ]; then
	if [ -f "$DROPIN" ]; then
		rm -f "$DROPIN"
		update-grub
		log "marker absent, removed stale grub drop-in"
	fi
	log "TMDS mode configured, nothing to do"
	exit 0
fi

# --- grub -----------------------------------------------------------------
if [ ! -f "$DROPIN" ]; then
	STATE_DIR=$STATE_DIR "$REPO_DIR/hdmi-mode.sh" frl
	log "grub drop-in was missing, recreated"
elif ! grep -q "$MASK" /proc/cmdline; then
	log "FRL mask missing from the cmdline, regenerating grub (applies next reboot)"
	update-grub
else
	log "FRL mask present"
fi

# --- patched amdgpu module ------------------------------------------------
if vermagic_ok "$TARGET"; then
	log "patched amdgpu override present for $K"
	exit 0
fi

if vermagic_ok "$MODULE"; then
	log "installing prebuilt module $MODULE"
	"$REPO_DIR/install.sh" || log "ERROR install.sh failed"
	exit 0
fi

log "no module for $K, starting a detached rebuild"
if command -v systemd-run >/dev/null 2>&1; then
	systemd-run --collect --unit=hdmi-frl-rebuild \
		--description="Rebuild the patched amdgpu module for $K" \
		--property=TimeoutStartSec=0 \
		--setenv=HDMI_FRL_REPO="$REPO_DIR" \
		--setenv=STATE_DIR="$STATE_DIR" \
		"$REPO_DIR/selfheal/hdmi-frl-selfheal.sh" rebuild \
		|| { log "systemd-run failed, rebuilding inline"; do_rebuild; }
else
	do_rebuild
fi
