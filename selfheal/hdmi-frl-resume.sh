#!/usr/bin/env bash
# Runs after resume from hdmi-frl-resume.service and forces the HDMI connector
# to be re-detected when the driver has dropped the FRL modes.
#
#   sudo selfheal/hdmi-frl-resume.sh [--check] [--force]
#
#   --check  report what it sees and exit without writing anything
#   --force  run one re-detect cycle even if the FRL modes are still present
#
# After an s2idle suspend/resume the connector's mode list loses everything
# above the TMDS pixel clock ceiling (3840x2160@143.99 at 1332750 kHz goes, only
# modes <= 600000 kHz remain) although the EDID is byte-identical. The link
# capability, not the EDID, is what was lost.
#
# The fix is the debugfs trigger_hotplug file. Writing 1 to it returns early
# while the connector already reads connected, so on its own it does nothing
# after a resume. Writing 0 tears the link down (releases the local sink, sets
# the link type to none); the following 1 is then a real disconnected-to-
# connected detect, which re-reads the FRL link capability. Neither write emits
# a uevent, so a successful restore is followed by a synthetic one for the
# compositor.
#
# Only acts while the FRL mask (bit 0x400 of amdgpu.dcfeaturemask) is on the
# kernel cmdline; the TMDS configuration has nothing to restore.
set -euo pipefail

CHECK=0
FORCE=0

TMDS_MAX_KHZ=1200000	# above this pixel clock only an FRL link works: TMDS tops out
			# at 600 MHz character rate, and 4:2:0 halves it, so 4K120 4:2:0
			# (1188000 kHz) still fits TMDS while 4K144 (1332750 kHz) does not
CONNECT_WAIT=60		# seconds to wait for the sink to come back
ATTEMPTS=5		# re-detect cycles before giving up

log() { printf 'hdmi-frl-resume: %s\n' "$*"; }
die() { printf 'hdmi-frl-resume: ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK=1; shift ;;
		--force) FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (see --help)" ;;
	esac
done

# --- FRL mask -------------------------------------------------------------
frl_mask_set() {
	local mask
	mask=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^amdgpu\.dcfeaturemask=//p' | tail -1)
	[ -n "$mask" ] || return 1
	(( (mask & 0x400) != 0 ))
}

if ! frl_mask_set; then
	log "no FRL mask on the cmdline, nothing to do"
	exit 0
fi

# --- helpers --------------------------------------------------------------
# Highest pixel clock in kHz across the connector's current mode list. modetest
# prints one line per mode, the clock is the 12th field:
#   #12 3840x2160 143.99 3840 3888 3920 4000 2160 2163 2168 2314 1332750 flags:
max_pixel_clock() {
	local out
	out=$(modetest -M amdgpu -c 2>/dev/null || true)
	printf '%s\n' "$out" | awk -v conn="$1" '
		$1 ~ /^[0-9]+$/ && NF >= 4 && ($3 == "connected" || $3 == "disconnected") {
			want = ($4 == conn); next
		}
		want && $1 ~ /^#[0-9]+$/ && $12 + 0 > max { max = $12 + 0 }
		END { print max + 0 }
	'
}

# The sink itself has to advertise FRL, otherwise a re-detect can never help.
sink_has_frl() {
	local edid=/sys/class/drm/$1/edid
	command -v edid-decode >/dev/null 2>&1 || return 0
	[ -s "$edid" ] || return 0
	edid-decode < "$edid" 2>/dev/null | grep -q "Max Fixed Rate Link"
}

wait_connected() {
	local status=/sys/class/drm/$1/status i
	for (( i = 0; i < CONNECT_WAIT; i++ )); do
		[ "$(cat "$status" 2>/dev/null || true)" = connected ] && return 0
		sleep 1
	done
	return 1
}

redetect() {
	local hotplug=$1
	echo 0 > "$hotplug"
	sleep 2
	echo 1 > "$hotplug"
	sleep 5
}

# --- one connector --------------------------------------------------------
# $1 = sysfs name (card0-HDMI-A-1), $2 = card number, $3 = connector name
handle_connector() {
	local sysname=$1 card=$2 conn=$3
	local hotplug=/sys/kernel/debug/dri/$card/$conn/trigger_hotplug
	local clock i

	if ! wait_connected "$sysname"; then
		log "$conn: still not connected after ${CONNECT_WAIT}s, skipping"
		return 0
	fi

	if ! command -v modetest >/dev/null 2>&1; then
		log "$conn: modetest is missing, cannot determine whether FRL modes are present"
		return 0
	fi

	if ! sink_has_frl "$sysname"; then
		log "$conn: the sink EDID advertises no FRL capability, skipping"
		return 0
	fi

	clock=$(max_pixel_clock "$conn")
	log "$conn: highest mode clock ${clock} kHz (FRL needs > ${TMDS_MAX_KHZ} kHz)"

	if [ "$clock" -gt "$TMDS_MAX_KHZ" ]; then
		if [ "$FORCE" = 0 ]; then
			log "$conn: FRL modes present, nothing to do"
			return 0
		fi
		log "$conn: FRL modes present but --force was given, re-detecting anyway"
	fi

	if [ "$CHECK" = 1 ]; then
		log "$conn: --check, not writing to $hotplug"
		return 0
	fi

	[ -w "$hotplug" ] || { log "$conn: $hotplug is not writable (run as root)"; return 1; }

	for (( i = 1; i <= ATTEMPTS; i++ )); do
		log "$conn: re-detect attempt $i/$ATTEMPTS (0 then 1 to $hotplug)"
		redetect "$hotplug"
		clock=$(max_pixel_clock "$conn")
		if [ "$clock" -gt "$TMDS_MAX_KHZ" ]; then
			log "$conn: FRL modes restored, highest mode clock ${clock} kHz"
			if udevadm trigger --action=change --subsystem-match=drm \
				--sysname-match="card$card" 2>/dev/null; then
				log "$conn: emitted a change uevent on card$card"
			else
				log "$conn: could not emit a change uevent on card$card (ignored)"
			fi
			return 0
		fi
		log "$conn: still ${clock} kHz after attempt $i"
		if [ "$i" -lt "$ATTEMPTS" ]; then sleep 5; fi
	done

	log "$conn: FRL modes did not come back after $ATTEMPTS attempts"
	return 1
}

# --- connectors -----------------------------------------------------------
shopt -s nullglob
connectors=(/sys/class/drm/card*-HDMI-A-*)
shopt -u nullglob

[ ${#connectors[@]} -gt 0 ] || { log "no HDMI connectors in /sys/class/drm"; exit 0; }

rc=0
for path in "${connectors[@]}"; do
	sysname=${path##*/}
	card=${sysname%%-*}		# card0
	conn=${sysname#"$card"-}	# HDMI-A-1
	card=${card#card}		# 0
	# handle_connector waits for the sink itself: the TV is often still asleep
	# when this runs, so a disconnected status here is not a reason to skip.
	handle_connector "$sysname" "$card" "$conn" || rc=1
done
exit "$rc"
