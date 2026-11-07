#!/bin/sh
# hdmi-allm.sh disabled|dynamic|always-on|default|restore|status -- choose the
# HDMI ALLM (Auto Low Latency Mode) default of the patched amdgpu module.
#
#   disabled   amdgpu.hdmi_allm_default=0  ALLM never signalled by default
#   dynamic    amdgpu.hdmi_allm_default=1  ALLM while VRR varies or content type is Game
#   always-on  amdgpu.hdmi_allm_default=2  ALLM signalled on every stream
#   default    remove the setting; the module's own default (always on) applies
#   restore    write the drop-in again from the marker (used by the self-heal)
#   status     show the configured and the running value
#
# Writes /etc/default/grub.d/hdmi21-allm.cfg and the marker
# $STATE_DIR/.hdmi21-allm (which holds the number), then regenerates grub. The
# marker is what selfheal/hdmi-frl-selfheal.sh enforces after a SteamOS update.
# Only patch 0003 knows the parameter; the stock module ignores it. A reboot is
# required afterwards.
#
# STATE_DIR defaults to the home directory of the user who invoked sudo, or to
# $HOME when run directly.
set -eu

if [ -z "${STATE_DIR:-}" ]; then
	if [ -n "${SUDO_USER:-}" ]; then
		STATE_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)
	else
		STATE_DIR=${HOME:-/home/deck}
	fi
fi

# Test-only override, used by tests/allm-config.sh: a directory standing in for
# /etc/default/grub.d. It also lifts the root check.
GRUBD=${HDMI_ALLM_TEST_GRUBD:-/etc/default/grub.d}
F=$GRUBD/hdmi21-allm.cfg
M=$STATE_DIR/.hdmi21-allm
PARAM=/sys/module/amdgpu/parameters/hdmi_allm_default

need_root() {
	[ -n "${HDMI_ALLM_TEST_GRUBD:-}" ] && return 0
	[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
}

# The drop-in text for mode number $1.
render() {
	cat <<CFG
# HDMI ALLM default for the patched amdgpu module (0 disabled, 1 dynamic, 2 always on).
# Managed by steam-machine-hdmi21/hdmi-allm.sh
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT} amdgpu.hdmi_allm_default=$1"
CFG
}

name_of() {
	case "$1" in 0) echo disabled ;; 1) echo dynamic ;; 2) echo always-on ;; *) echo "unknown ($1)" ;; esac
}

regen_grub() {
	if [ -n "${HDMI_ALLM_TEST_GRUBD:-}" ]; then
		if command -v update-grub >/dev/null 2>&1; then update-grub; fi
	else
		update-grub
	fi
}

write_config() { # number
	need_root
	mkdir -p "$GRUBD"
	render "$1" > "$F"
	printf '%s\n' "$1" > "$M"
	if [ -n "${SUDO_USER:-}" ]; then chown "$SUDO_USER" "$M" 2>/dev/null || true; fi
	regen_grub
	echo "ALLM default set to $(name_of "$1") in grub (marker $M). Reboot to apply."
}

case "${1:-status}" in
  disabled) write_config 0 ;;
  dynamic) write_config 1 ;;
  always-on) write_config 2 ;;
  default)
	need_root
	rm -f "$F" "$M"
	regen_grub
	echo "ALLM setting removed from grub (the module default applies). Reboot to apply."
	;;
  restore)
	need_root
	n=$(cat "$M" 2>/dev/null || true)
	case "$n" in
		0|1|2) write_config "$n" ;;
		*) echo "no valid ALLM setting in $M" >&2; exit 1 ;;
	esac
	;;
  render)
	render "${2:?mode number}"
	;;
  status)
	if [ -f "$F" ]; then
		n=$(sed -n 's/.*amdgpu\.hdmi_allm_default=\([0-9]*\).*/\1/p' "$F" | head -1)
		echo "allm configured: $(name_of "$n") (next boot)"
	else
		echo "allm configured: module default (next boot)"
	fi
	if [ -r "$PARAM" ]; then
		echo "allm running: $(name_of "$(cat "$PARAM")")"
	else
		echo "allm running: patched module not loaded"
	fi
	;;
  *) echo "usage: $0 disabled|dynamic|always-on|default|restore|status"; exit 2 ;;
esac
