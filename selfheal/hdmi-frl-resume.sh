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
# EDID is byte-identical: the FRL link capability, not the EDID, is lost. The
# mode list alone cannot show it on every TV (a 120 Hz TV such as the LG C9
# lists 4K120 at 1188000 kHz over FRL and over TMDS 4:2:0 alike), and neither
# can the driver's link state alone (an FRL-capable TV that runs a TMDS-sized
# mode on purpose, such as 4K60, has no FRL encoder either). So the link is
# classified from three inputs, first match wins:
#
#   1. hpo-row      the "HPO:" table of amdgpu_dm_dtn_log (debugfs, root) has a
#                   row. The driver prints it only while an HDMI FRL stream
#                   encoder is active, so the link is FRL right now.
#   2. mode-list    the connector lists a mode above 1200000 kHz (modetest).
#                   TMDS tops out at 600 MHz and 4:2:0 halves that, so only an
#                   FRL-capable link can offer one: the capability is intact.
#   3. active mode  the dump is complete, shows an OTG row and no HPO row, and
#                   the CRTC driving the connector runs a mode above 600000 kHz.
#                   Above 600 MHz TMDS can carry a mode only as 4:2:0 and FRL
#                   always uses the HPO encoder, so a 4K120 stream without HPO
#                   is the lost-FRL fallback. This is the only "tmds" verdict.
#
# Rules 1 and 2 give "frl", rule 3 gives "tmds" (FRL lost, recovery warranted),
# everything else gives "unknown" and nothing is touched. That includes a 120 Hz
# TV running 4K60 or lower, an incomplete dump, an unreadable file and a missing
# modetest. Deliberately fail safe: a lost link on a 120 Hz TV can only be seen
# while it is driving a mode above 600 MHz, and a missed recovery costs less
# than blanking the screen on a guess.
#
# The TV is often still waking when this runs and patch 0002 retrains FRL on
# the resume hotplug by itself, so the link is polled for up to FRL_WAIT
# seconds first; if it comes up the script only logs and exits. Only a link
# that is still "tmds" after that is re-detected.
#
# The fix is the debugfs trigger_hotplug file. Writing 1 to it returns early
# while the connector already reads connected, so on its own it does nothing
# after a resume. Writing 0 tears the link down (releases the local sink, sets
# the link type to none); the following 1 is then a real disconnected-to-
# connected detect, which re-reads the FRL link capability. Neither write emits
# a uevent, and the compositor needs one to re-read the connector and switch to
# an FRL stream, so every cycle is followed by a synthetic one before the link
# state is read again.
#
# Only acts while the FRL mask (bit 0x400 of amdgpu.dcfeaturemask) is on the
# kernel cmdline; the TMDS configuration has nothing to restore.
set -euo pipefail

CHECK=0
FORCE=0

TMDS_MAX_KHZ=600000	# a TMDS link carries nothing faster than this except as 4:2:0
FRL_ONLY_KHZ=1200000	# a mode above this exists only over FRL (4K144 is 1332750)
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
RULE=""			# which rule decided STATE
INPUTS=""		# what the rule saw, for the log
DUMP=incomplete		# dtn_log verdict: hpo, nohpo or incomplete
DUMP_WHY=""		# why DUMP is incomplete, when it is
MAX_KHZ=0		# highest mode clock the connector lists
ACTIVE_KHZ=0		# clock of the mode its CRTC runs, 0 if none
MODETEST_OK=0		# 1 when modetest ran
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
# else prints the verdict on the dump:
#   hpo         at least one row under the "HPO:" header
#   nohpo       no such row, but the dump is complete ([dtn begin] and
#               [dtn end]) and an OTG row shows that something is being driven
#   incomplete  everything else
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
			if (hpo > 0) print "hpo"
			else if (begin && end && otg > 0) print "nohpo"
			else print "incomplete"
		}
	'
}

# Reads modetest -e -c -p on stdin and prints "<highest> <active>" in kHz for
# connector $1: the highest clock among its modes, and the clock of the mode on
# the CRTC its encoder is bound to (0 when there is none). The layout is
# libdrm's tests/modetest/modetest.c:
#   Encoders:   id <tab> crtc <tab> type <tab> possible crtcs <tab> clones
#   Connectors: id <tab> encoder <tab> status <tab> name <tab> size ...
#                 #N name refresh hdisp hss hse htot vdisp vss vse vtot clock flags: ...
#   CRTCs:      id <tab> fb <tab> (x,y) <tab> (WxH)
#                 #0 name refresh ... vtot clock flags: ...
# The clock is the last field before "flags:". It is taken from there rather
# than by position because an idle CRTC prints an empty mode name, which shifts
# every field.
modetest_clocks() {
	awk -v conn="$1" '
		function clk(   line, n, f) {
			line = $0; sub(/ flags:.*/, "", line)
			n = split(line, f, " ")
			return f[n] + 0
		}
		/^Encoders:/ { sect = "enc"; next }
		/^Connectors:/ { sect = "conn"; next }
		/^CRTCs:/ { sect = "crtc"; next }
		/^Planes:/ { sect = "plane"; next }
		sect == "enc" && $1 ~ /^[0-9]+$/ && NF >= 3 { enc[$1] = $2; next }
		sect == "conn" && $1 ~ /^[0-9]+$/ && ($3 == "connected" || $3 == "disconnected" || $3 == "unknown") {
			want = ($4 == conn)
			if (want) cenc = $2
			next
		}
		sect == "conn" && want && $1 ~ /^#[0-9]+$/ { c = clk(); if (c > max) max = c; next }
		sect == "crtc" && $1 ~ /^[0-9]+$/ && $3 ~ /^\(/ { cur = $1; next }
		sect == "crtc" && $1 == "#0" { crtc[cur] = clk(); next }
		END {
			ec = (cenc in enc) ? enc[cenc] : 0
			print max + 0, (ec in crtc) ? crtc[ec] + 0 : 0
		}
	'
}

# Reads dtn_log and modetest for one connector and applies the rules. Sets
# STATE, RULE, INPUTS and the values they came from.
# $1 = card number, $2 = sysfs name, $3 = connector name
read_link_state() {
	local dtn=$DEBUGFS/$1/amdgpu_dm_dtn_log
	local enabled=$DRM_SYSFS/$2/enabled text out

	STATE=unknown; RULE=""; INPUTS=""
	DUMP=incomplete; DUMP_WHY=""; HPO_ROWS=""
	MAX_KHZ=0; ACTIVE_KHZ=0; MODETEST_OK=0

	if [ -r "$enabled" ] && [ "$(cat "$enabled" 2>/dev/null || true)" != enabled ]; then
		DUMP_WHY="the connector is not enabled, nothing is driving it"
	elif [ ! -e "$dtn" ]; then
		DUMP_WHY="$dtn does not exist (debugfs not mounted, or this module has no dtn_log)"
	elif ! text=$(cat "$dtn" 2>/dev/null); then
		DUMP_WHY="cannot read $dtn (run as root)"
	elif [ -z "$text" ]; then
		DUMP_WHY="$dtn is empty"
	else
		DUMP=$(printf '%s\n' "$text" | classify_dtn_log)
		HPO_ROWS=$(printf '%s\n' "$text" | classify_dtn_log rows)
		[ "$DUMP" != incomplete ] || DUMP_WHY="the dump is cut short or nothing is being driven yet"
	fi

	if command -v modetest >/dev/null 2>&1 && out=$(modetest -M amdgpu -e -c -p 2>/dev/null) && [ -n "$out" ]; then
		MODETEST_OK=1
		out=$(printf '%s\n' "$out" | modetest_clocks "$3")
		MAX_KHZ=${out%% *}
		ACTIVE_KHZ=${out##* }
	fi

	INPUTS="dtn_log $DUMP${DUMP_WHY:+ ($DUMP_WHY)}"
	if [ "$MODETEST_OK" = 1 ]; then
		INPUTS="$INPUTS, highest mode $MAX_KHZ kHz, active mode $ACTIVE_KHZ kHz"
	else
		INPUTS="$INPUTS, modetest unavailable"
	fi

	if [ "$DUMP" = hpo ]; then
		STATE=frl; RULE="hpo-row"
	elif [ "$MAX_KHZ" -gt "$FRL_ONLY_KHZ" ]; then
		STATE=frl; RULE="mode-list >$FRL_ONLY_KHZ ($MAX_KHZ kHz)"
	elif [ "$DUMP" = nohpo ] && [ "$ACTIVE_KHZ" -gt "$TMDS_MAX_KHZ" ]; then
		STATE=tmds; RULE="active $ACTIVE_KHZ kHz without HPO"
	else
		RULE="none -> unknown"
	fi
}

# Reads the link state until it is frl or $3 seconds have passed. The last
# reading is the verdict (STATE, RULE, INPUTS, HPO_ROWS).
# $1 = card number, $2 = sysfs name, $3 = seconds, $4 = connector name
poll_link_state() {
	local waited=0 last=""
	while :; do
		read_link_state "$1" "$2" "$4"
		if [ "$STATE/$RULE/$INPUTS" != "$last" ]; then
			log "$4: link state $STATE (rule: $RULE; $INPUTS)"
			last="$STATE/$RULE/$INPUTS"
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

# Neither hotplug write emits a uevent and the compositor does not re-read the
# connector without one, so this has to come before the link state is read.
emit_change() { # card, connector
	if udevadm trigger --action=change --subsystem-match=drm \
		--sysname-match="card$1" 2>/dev/null; then
		log "$2: emitted a change uevent on card$1"
	else
		log "$2: could not emit a change uevent on card$1 (ignored)"
	fi
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
		log "$conn: rule: $RULE"
		log "$conn: inputs: $INPUTS"
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
			log "$conn: FRL was lost" ;;
		*)
			if [ "$FORCE" = 0 ]; then
				log "$conn: cannot tell whether FRL was lost, leaving the link alone"
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
		emit_change "$card" "$conn"
		poll_link_state "$card" "$sysname" "$REDETECT_WAIT" "$conn"
		case "$STATE" in
			frl)
				log "$conn: FRL link restored"
				log_hpo_rows "$conn"
				return 0 ;;
			tmds)
				log "$conn: still no FRL after attempt $i" ;;
			*)
				log "$conn: link state no longer clear after attempt $i, not trying again"
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
