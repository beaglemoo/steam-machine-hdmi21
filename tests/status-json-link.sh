#!/usr/bin/env bash
# Checks display.link and display.frl_modes_present of `setup.sh status --json`
# against a fake sysfs/debugfs tree (the HDMI_FRL_TEST_* overrides) and a stub
# modetest, using the same fixtures as tests/frl-detect.sh. The link must be
# classified by the rules of selfheal/hdmi-frl-resume.sh, which setup.sh runs in
# a child process.
#
#   bash tests/status-json-link.sh
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SETUP=$HERE/../setup.sh
FX=$HERE/fixtures
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/modetest" <<'STUB'
#!/bin/sh
[ "$STUB_MODETEST" != none ] || exit 1
cat "$STUB_MODETEST"
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
printf 'LoadState=not-found\nUnitFileState=\nActiveState=inactive\nSubState=dead\nResult=success\n'
STUB
chmod +x "$T/bin/modetest" "$T/bin/systemctl"

fail=0
pass=0
ok() { pass=$((pass + 1)); printf 'ok      %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAILED  %s\n' "$1"; }
expect() { # name, want, got
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi
}

mk_tree() { # dir
	mkdir -p "$1/sys/card0-HDMI-A-1" "$1/dri/0/HDMI-A-1"
	echo connected > "$1/sys/card0-HDMI-A-1/status"
	echo enabled > "$1/sys/card0-HDMI-A-1/enabled"
}

# run_status setup-script dump modetest : writes $T/out.json, sets RC
run_status() {
	local setup=$1 dump=$2 mt=$3
	local d=$T/tree
	rm -rf "$d"; mk_tree "$d"
	[ "$dump" = none ] || cp "$FX/$dump" "$d/dri/0/amdgpu_dm_dtn_log"
	RC=0
	STUB_MODETEST=$mt HDMI_FRL_TEST_SYSFS=$d/sys HDMI_FRL_TEST_DEBUGFS=$d/dri \
		PATH="$T/bin:$PATH" bash "$setup" status --json --dir "$T" > "$T/out.json" 2>"$T/err" || RC=$?
}
field() { # python expression on the parsed object d -> printed
	python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$T/out.json" "$1"
}
link_of() { field 'json.dumps([d["display"]["link"][k] for k in ("state","rule","dump","active_pixel_clock_khz")] + [d["display"]["frl_modes_present"]])'; }

M120=$FX/modetest.120hz-active120

# An LG C9 on FRL: the HPO row says frl, yet no mode is above 1200000 kHz.
run_status "$SETUP" dtn_log.frl "$M120"
expect "frl by the HPO row: exit 0" 0 "$RC"
expect "frl by the HPO row, 120 Hz TV" '["frl", "hpo-row", "hpo", 1188000, false]' "$(link_of)"

run_status "$SETUP" dtn_log.tmds "$FX/modetest.144hz"
expect "mode list above 1200000 kHz: frl, modes present" \
	'["frl", "mode-list >1200000 (1332750 kHz)", "nohpo", 1332750, true]' "$(link_of)"

run_status "$SETUP" dtn_log.tmds "$M120"
expect "no HPO row on 4K120: tmds" '["tmds", "active 1188000 kHz without HPO", "nohpo", 1188000, false]' "$(link_of)"

run_status "$SETUP" dtn_log.tmds "$FX/modetest.120hz-active60"
expect "no HPO row on 4K60 of a 120 Hz TV: unknown" '["unknown", "none -> unknown", "nohpo", 594000, false]' "$(link_of)"

run_status "$SETUP" dtn_log.truncated "$M120"
expect "truncated dump: unknown, incomplete" '["unknown", "none -> unknown", "incomplete", 1188000, false]' "$(link_of)"

run_status "$SETUP" dtn_log.tmds "$FX/modetest.120hz-idle"
expect "idle CRTC: no active clock" '["unknown", "none -> unknown", "nohpo", null, false]' "$(link_of)"

# modetest fails: no mode list, so frl_modes_present is unknown, not false.
run_status "$SETUP" dtn_log.frl none
expect "modetest fails: still frl by the HPO row" '["frl", "hpo-row", "hpo", null, null]' "$(link_of)"

# No resume script next to setup.sh: link fields are null, there is a warning,
# and status still exits 0 with valid JSON.
mkdir -p "$T/nosh"
cp "$SETUP" "$HERE/../VERSION" "$T/nosh/"
run_status "$T/nosh/setup.sh" dtn_log.frl "$M120"
expect "no resume script: exit 0" 0 "$RC"
expect "no resume script: link and frl_modes_present are null" '[null, null, null, null, null]' "$(link_of)"
expect "no resume script: one warning about it" 1 \
	"$(field 'sum("link state" in w for w in d["warnings"])')"

# The thresholds stay in the resume script: setup.sh must not define its own.
if grep -q 'TMDS_MAX_KHZ' "$SETUP"; then bad "setup.sh defines no TMDS_MAX_KHZ"; else ok "setup.sh defines no TMDS_MAX_KHZ"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
