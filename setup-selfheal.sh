#!/usr/bin/env bash
# Install the self-heal units: hdmi-frl-grub.service re-asserts the grub
# drop-in and the patched amdgpu module after a SteamOS atomic update, and
# rebuilds the module if the kernel changed; hdmi-frl-resume.service forces a
# connector re-detect after a resume that dropped the FRL modes.
#
#   sudo ./setup-selfheal.sh [--dry-run] [--remove]
#
# The services run this checkout in place, so keep it somewhere under /home,
# which survives atomic updates.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UNIT=hdmi-frl-grub.service
UNIT_PATH=/etc/systemd/system/$UNIT
RESUME_UNIT=hdmi-frl-resume.service
RESUME_UNIT_PATH=/etc/systemd/system/$RESUME_UNIT
KEEP_PATH=/etc/atomic-update.conf.d/hdmi-frl.conf
DRY=0
REMOVE=0

log() { printf '[setup-selfheal] %s\n' "$*"; }
die() { printf '[setup-selfheal] ERROR: %s\n' "$*" >&2; exit 1; }
run() {
	if [ "$DRY" = 1 ]; then printf '[setup-selfheal] would run: %s\n' "$*"; else "$@"; fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY=1; shift ;;
		--remove) REMOVE=1; shift ;;
		-h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root (sudo ./setup-selfheal.sh)"

if [ "$REMOVE" = 1 ]; then
	run systemctl disable --now "$UNIT"
	run systemctl disable --now "$RESUME_UNIT"
	run rm -f "$UNIT_PATH" "$RESUME_UNIT_PATH" "$KEEP_PATH"
	run systemctl daemon-reload
	log "self-heal removed"
	exit 0
fi

if [ -n "${STATE_DIR:-}" ]; then
	state_dir=$STATE_DIR
elif [ -n "${SUDO_USER:-}" ]; then
	state_dir=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
	state_dir=${HOME:-/home/deck}
fi

SELFHEAL="$REPO_DIR/selfheal/hdmi-frl-selfheal.sh"
[ -x "$SELFHEAL" ] || die "$SELFHEAL is missing or not executable"
RESUME="$REPO_DIR/selfheal/hdmi-frl-resume.sh"
[ -x "$RESUME" ] || die "$RESUME is missing or not executable"

log "repo      $REPO_DIR"
log "state dir $state_dir"
log "unit      $UNIT_PATH"
log "unit      $RESUME_UNIT_PATH"

unit_text=$(sed \
	-e "s#^ConditionPathExists=.*#ConditionPathExists=$SELFHEAL#" \
	-e "s#^Environment=HDMI_FRL_REPO=.*#Environment=HDMI_FRL_REPO=$REPO_DIR#" \
	-e "s#^Environment=STATE_DIR=.*#Environment=STATE_DIR=$state_dir#" \
	-e "s#^ExecStart=.*#ExecStart=$SELFHEAL#" \
	"$REPO_DIR/selfheal/$UNIT")

resume_text=$(sed \
	-e "s#^ConditionPathExists=.*#ConditionPathExists=$RESUME#" \
	-e "s#^ExecStart=.*#ExecStart=$RESUME#" \
	"$REPO_DIR/selfheal/$RESUME_UNIT")

if [ "$DRY" = 1 ]; then
	log "would write $UNIT_PATH:"
	printf '%s\n' "$unit_text" | sed 's/^/    /'
	log "would write $RESUME_UNIT_PATH:"
	printf '%s\n' "$resume_text" | sed 's/^/    /'
	log "would write $KEEP_PATH from selfheal/atomic-update-keep.conf"
else
	install -d -m755 "$(dirname "$UNIT_PATH")" "$(dirname "$KEEP_PATH")"
	printf '%s\n' "$unit_text" > "$UNIT_PATH"
	chmod 644 "$UNIT_PATH"
	printf '%s\n' "$resume_text" > "$RESUME_UNIT_PATH"
	chmod 644 "$RESUME_UNIT_PATH"
	install -m644 "$REPO_DIR/selfheal/atomic-update-keep.conf" "$KEEP_PATH"
fi

run systemctl daemon-reload
run systemctl enable "$UNIT"
run systemctl enable "$RESUME_UNIT"

log "enabled. $UNIT runs on every boot and does nothing while the marker file"
log "$state_dir/.hdmi-frl-enabled is absent. $RESUME_UNIT runs on every resume"
log "and does nothing while the FRL mask is off the running cmdline."
