#!/usr/bin/env bash
# Runs after resume from hdmi-frl-resume.service and forces the HDMI connector
# to be re-detected when the driver has dropped the FRL link.
#
#   sudo selfheal/hdmi-frl-resume.sh [--check] [--force]
#
#   --check  report what it sees and exit without writing anything
#   --force  run one re-detect cycle even if the FRL link is up or unreadable
#
# After an s2idle suspend/resume the link can come back as TMDS although the
# EDID is byte-identical: the FRL link capability, not the EDID, is lost. On a
# TV that tops out at 144 Hz the mode list shows it (3840x2160@143.99 is
# 1332750 kHz and disappears), but a 120 Hz TV such as the LG C9 lists 4K120 at
# 1188000 kHz over FRL and over TMDS 4:2:0 alike, so the mode list cannot tell
# the two apart. The script therefore asks the driver which link it is running.
#
# amdgpu_dm_dtn_log (debugfs, read as root) is the driver's hardware state
# dump. Its "HPO:" table lists the active HDMI FRL stream encoders and is only
# printed when one is enabled, so a row there means FRL and a complete dump
# that drives an output but has no such table means TMDS. Anything else (file
# unreadable, dump cut short, nothing lit yet, connector not enabled) is
# reported as unknown, and unknown never touches the link.
#
# The TV is often still waking when this runs and patch 0002 retrains FRL on
# the resume hotplug by itself, so the link is polled for up to FRL_WAIT
# seconds first; if it comes up the script only logs and exits. Only a link
# that is still TMDS after that wait is re-detected.
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

CONNECT_WAIT=60		# seconds to wait for the sink to come back
FRL_WAIT=20		# seconds to wait for the driver to bring FRL up by itself
REDETECT_WAIT=10	# seconds to wait for FRL after each re-detect cycle
POLL_INTERVAL=2		# seconds between link state reads
ATTEMPTS=5		# re-detect cycles before giving up

# Test-only overrides, used by tests/frl-detect.sh. The defaults are the real
# paths and nothing in the units or the installer sets these.
CMDLINE=${HDMI_FRL_TEST_CMDLINE:-/proc/cmdline}
DRM_SYSFS=${HDMI_FRL_TEST_SYSFS:-/sys/class/drm}
DEBUGFS=${HDMI_FRL_TEST_DEBUGFS:-/sys/kernel/debug/dri}

STATE=unknown		# set by read_link_state: frl, tmds or unknown
WHY=""			# why STATE is what it is, for the log
HPO_ROWS=""		# the HPO table rows of the last read, if any

log() { printf 'hdmi-frl-resume: %s\n' "$*"; }
die() { printf 'hdmi-frl-resume: ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- FRL mask -------------------------------------------------------------
frl_mask_set() {
	local mask
	mask=$(tr ' ' '\n' < "$CMDLINE" | sed -n 's/^amdgpu\.dcfeaturemask=//p' | tail -1)
	[ -n "$mask" ] || return 1
	(( (mask & 0x400) != 0 ))
}

# --- link state -----------------------------------------------------------
# Reads a dtn_log dump on stdin. "rows" prints the HPO table rows, anything
# else prints the verdict:
#   frl      at least one row under the "HPO:" header
#   tmds     no such row, but the dump is complete ([dtn begin] and [dtn end])
#            and an OTG row shows that something is being driven
#   unknown  everything else
# A header is only recognised at the start of a line, so the "DP HPO S_ENC:"
# and "DP HPO L_ENC:" tables of a DisplayPort output do not count. The Link
# column is ignored: a healthy FRL link has been seen reading "Training".
classify_dtn_log() { # [rows]
	awk -v want="${1:-state}" '
		/^\[dtn begin\]/ { begin = 1; next }
		/^\[dtn end\]/ { end = 1; next }
		/^[ \t\r]*$/ { sect = ""; next }
		/^\[[0-9]+\]:/ {
			if (sect == "otg") otg++
			else if (sect == "hpo") { hpo++; rows = rows (rows == "" ? "" : "\n") $0 }
			next
		}
		/^OTG:/ { sect = "otg"; next }
		/^HPO:/ { sect = "hpo"; next }
		{ sect = "" }
		END {
			if (want == "rows") { if (rows != "") print rows; exit }
			if (hpo > 0) print "frl"
			else if (begin && end && otg > 0) print "tmds"
			else print "unknown"
		}
	'
}

# Sets STATE, WHY and HPO_ROWS from the driver for one connector.
# $1 = card number, $2 = sysfs name (card0-HDMI-A-1)
read_link_state() {
	local dtn=$DEBUGFS/$1/amdgpu_dm_dtn_log
	local enabled=$DRM_SYSFS/$2/enabled text

	STATE=unknown
	HPO_ROWS=""

	if [ -r "$enabled" ] && [ "$(cat "$enabled" 2>/dev/null || true)" != enabled ]; then
		WHY="the connector is not enabled, nothing is driving it"
		return 0
	fi
	if [ ! -e "$dtn" ]; then
		WHY="$dtn does not exist (debugfs not mounted, or this module has no dtn_log)"
		return 0
	fi
	if ! text=$(cat "$dtn" 2>/dev/null); then
		WHY="cannot read $dtn (run as root)"
		return 0
	fi
	if [ -z "$text" ]; then
		WHY="$dtn is empty"
		return 0
	fi

	STATE=$(printf '%s\n' "$text" | classify_dtn_log)
	HPO_ROWS=$(printf '%s\n' "$text" | classify_dtn_log rows)
	case "$STATE" in
		frl) WHY="an HPO FRL encoder is active" ;;
		tmds) WHY="no HPO FRL encoder is active" ;;
		*) WHY="$dtn is incomplete or nothing is being driven yet" ;;
	esac
}

# Reads the link state until it is frl or $3 seconds have passed. The last
# reading is the verdict (STATE, WHY, HPO_ROWS).
# $1 = card number, $2 = sysfs name, $3 = seconds, $4 = connector name
poll_link_state() {
	local waited=0 last=""
	while :; do
		read_link_state "$1" "$2"
		if [ "$STATE/$WHY" != "$last" ]; then
			log "$4: link state $STATE ($WHY)"
			last="$STATE/$WHY"
		fi
		if [ "$STATE" = frl ] || [ "$waited" -ge "$3" ]; then
			return 0
		fi
		sleep "$POLL_INTERVAL"
		waited=$(( waited + POLL_INTERVAL ))
	done
}

# --- helpers --------------------------------------------------------------
# The sink itself has to advertise FRL, otherwise a re-detect can never help.
sink_has_frl() {
	local edid=$DRM_SYSFS/$1/edid
	command -v edid-decode >/dev/null 2>&1 || return 0
	[ -s "$edid" ] || return 0
	edid-decode < "$edid" 2>/dev/null | grep -q "Max Fixed Rate Link"
}

wait_connected() {
	local status=$DRM_SYSFS/$1/status i
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

log_hpo_rows() { # connector
	local row
	[ -n "$HPO_ROWS" ] || return 0
	while IFS= read -r row; do
		log "$1: HPO row: $row"
	done <<< "$HPO_ROWS"
}

# --- one connector --------------------------------------------------------
# $1 = sysfs name (card0-HDMI-A-1), $2 = card number, $3 = connector name
handle_connector() {
	local sysname=$1 card=$2 conn=$3
	local hotplug=$DEBUGFS/$card/$conn/trigger_hotplug
	local i

	if ! wait_connected "$sysname"; then
		log "$conn: still not connected after ${CONNECT_WAIT}s, skipping"
		return 0
	fi

	# --check is a single read; the wait is for the unit, not for a report.
	if [ "$CHECK" = 1 ]; then
		poll_link_state "$card" "$sysname" 0 "$conn"
		if [ -n "$HPO_ROWS" ]; then
			log_hpo_rows "$conn"
		else
			log "$conn: HPO row: none"
		fi
	else
		poll_link_state "$card" "$sysname" "$FRL_WAIT" "$conn"
		log_hpo_rows "$conn"
	fi

	case "$STATE" in
		frl)
			if [ "$FORCE" = 0 ]; then
				log "$conn: FRL link is up, nothing to do"
				return 0
			fi
			log "$conn: FRL link is up but --force was given, re-detecting anyway" ;;
		tmds)
			log "$conn: link is TMDS" ;;
		*)
			if [ "$FORCE" = 0 ]; then
				log "$conn: cannot tell which link is running, leaving it alone"
				return 0
			fi
			log "$conn: link state unknown but --force was given, re-detecting anyway" ;;
	esac

	if ! sink_has_frl "$sysname"; then
		log "$conn: the sink EDID advertises no FRL capability, skipping"
		return 0
	fi

	if [ "$CHECK" = 1 ]; then
		log "$conn: --check, not writing to $hotplug"
		return 0
	fi

	[ -w "$hotplug" ] || { log "$conn: $hotplug is not writable (run as root)"; return 1; }

	for (( i = 1; i <= ATTEMPTS; i++ )); do
		log "$conn: re-detect attempt $i/$ATTEMPTS (0 then 1 to $hotplug)"
		redetect "$hotplug"
		poll_link_state "$card" "$sysname" "$REDETECT_WAIT" "$conn"
		case "$STATE" in
			frl)
				log "$conn: FRL link restored"
				log_hpo_rows "$conn"
				if udevadm trigger --action=change --subsystem-match=drm \
					--sysname-match="card$card" 2>/dev/null; then
					log "$conn: emitted a change uevent on card$card"
				else
					log "$conn: could not emit a change uevent on card$card (ignored)"
				fi
				return 0 ;;
			tmds)
				log "$conn: still TMDS after attempt $i" ;;
			*)
				log "$conn: link state unreadable after attempt $i, not trying again"
				return 0 ;;
		esac
		if [ "$i" -lt "$ATTEMPTS" ]; then sleep 5; fi
	done

	log "$conn: FRL link did not come back after $ATTEMPTS attempts"
	return 1
}

# --- connectors -----------------------------------------------------------
main() {
	local connectors path sysname card conn rc=0

	while [ $# -gt 0 ]; do
		case "$1" in
			--check) CHECK=1; shift ;;
			--force) FORCE=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) die "unknown argument: $1 (see --help)" ;;
		esac
	done

	if ! frl_mask_set; then
		log "no FRL mask on the cmdline, nothing to do"
		exit 0
	fi

	shopt -s nullglob
	connectors=("$DRM_SYSFS"/card*-HDMI-A-*)
	shopt -u nullglob

	[ ${#connectors[@]} -gt 0 ] || { log "no HDMI connectors in $DRM_SYSFS"; exit 0; }

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
}

# Sourcing the file (tests/frl-detect.sh) defines the functions and runs nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
