#!/bin/sh
# hdmi-mode.sh frl|tmds|status -- switch the Steam Machine HDMI link between
#   frl : HDMI 2.1 FRL (4K144, 10-bit 4:4:4, HDR; VRR needs the patched amdgpu)
#   tmds: HDMI 2.0 TMDS (4K120 4:2:0 8-bit HDR, VRR works with the stock module)
#
# Writes or removes /etc/default/grub.d/hdmi-frl.cfg and the marker file
# $STATE_DIR/.hdmi-frl-enabled, then regenerates grub. The marker is what
# selfheal/hdmi-frl-selfheal.sh enforces after a SteamOS update.
# A reboot is required afterwards.
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

F=/etc/default/grub.d/hdmi-frl.cfg
M=$STATE_DIR/.hdmi-frl-enabled
MASK=amdgpu.dcfeaturemask=0x402

need_root() { [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }; }

case "${1:-status}" in
  frl)
	need_root
	mkdir -p /etc/default/grub.d
	cat > "$F" <<CFG
# HDMI 2.1 FRL on kernel 7.2 (DC_FRL_MASK 0x400 + default 0x2).
# Managed by steam-machine-hdmi21/hdmi-mode.sh
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT} $MASK"
CFG
	touch "$M"
	if [ -n "${SUDO_USER:-}" ]; then chown "$SUDO_USER" "$M" 2>/dev/null || true; fi
	update-grub
	echo "FRL enabled in grub (marker $M). Reboot to apply."
	;;
  tmds)
	need_root
	rm -f "$F" "$M"
	update-grub
	echo "FRL disabled in grub (TMDS + VRR). Reboot to apply."
	;;
  status)
	if grep -q "$MASK" /proc/cmdline; then echo "running: FRL"; else echo "running: TMDS"; fi
	if [ -f "$M" ]; then echo "configured: FRL (next boot)"; else echo "configured: TMDS (next boot)"; fi
	K=$(uname -r)
	if [ -f "/lib/modules/$K/updates/amdgpu.ko.zst" ]; then
		echo "amdgpu: patched override installed for $K"
	else
		echo "amdgpu: stock module (no VRR on an FRL link)"
	fi
	if command -v modetest >/dev/null 2>&1; then
		modetest -M amdgpu -p 2>/dev/null \
			| grep -A1 -E "^[0-9]+\s+[0-9]+\s+\(0,0\)" \
			| sed -n 2p | awk '{print "mode: " $2 " @ " $3 " Hz"}'
	fi
	;;
  *) echo "usage: $0 frl|tmds|status"; exit 2 ;;
esac
