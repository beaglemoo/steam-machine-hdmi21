#!/usr/bin/env bash
# Checks the signal, HDR, content type and ALLM fields of `setup.sh status
# --json`, and the parsers behind them, against fixtures (tests/fixtures/README
# says which are real captures and which are derived). setup.sh runs against a
# fake sysfs/debugfs tree (the HDMI_FRL_TEST_* overrides) and a stub modetest.
#
#   bash tests/status-json-display.sh
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SETUP=$HERE/../setup.sh
FX=$HERE/fixtures
T=$(mktemp -d)
trap 'chmod -R u+rwx "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/modetest" <<'STUB'
#!/bin/sh
echo run >> "$STUB_COUNT"
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

# --- parsers --------------------------------------------------------------
# Pull the functions out of setup.sh and run them on the fixtures.
for fn in modetest_connector_props modetest_crtc_index hpo_fields; do
	eval "$(sed -n "/^$fn() {/,/^}/p" "$SETUP")"
done
prop() { # fixture, connector, name -> value
	modetest_connector_props "$2" < "$FX/$1" | awk -F'\t' -v n="$3" '$1 == n { print $2 }'
}

expect "props: enum resolved to its name" Game "$(prop modetest.frl-hdr HDMI-A-1 'content type')"
# set_prop fixture prop-name value > file: change the value line of one property
set_prop() {
	awk -v n="$2" -v v="$3" '
		/^\t[0-9]+ / { hit = ($0 ~ ("^\t[0-9]+ " n ":")) }
		hit && /^\t\tvalue: / { print "\t\tvalue: " v; hit = 0; next }
		{ print }' "$FX/$1"
}
set_prop modetest.frl-hdr allm_mode 2 > "$T/mt.allm2"
set_prop modetest.frl-hdr allm_mode 1 > "$T/mt.allm1"
set_prop modetest.frl-hdr 'Broadcast RGB' 2 > "$T/mt.limited"
set_prop modetest.frl-hdr 'content type' 0 > "$T/mt.nodata"
propf() { modetest_connector_props "$2" < "$1" | awk -F'\t' -v n="$3" '$1 == n { print $2 }'; }
expect "props: enum name with a space (Always On)" "Always On" "$(propf "$T/mt.allm2" HDMI-A-1 allm_mode)"
expect "props: enum name with a space and a colon" "Limited 16:235" "$(propf "$T/mt.limited" HDMI-A-1 'Broadcast RGB')"
expect "props: the last enum name" "No Data" "$(propf "$T/mt.nodata" HDMI-A-1 'content type')"
expect "props: Colorspace enum" BT2020_RGB "$(prop modetest.frl-hdr HDMI-A-1 Colorspace)"
expect "props: Colorspace at Default" Default "$(prop modetest.tmds-4k60-default HDMI-A-1 Colorspace)"
expect "props: first enum name" "Automatic" "$(prop modetest.frl-hdr HDMI-A-1 'Broadcast RGB')"
expect "props: range stays a number" 1 "$(prop modetest.frl-hdr HDMI-A-1 vrr_capable)"
expect "props: allm_capable" 1 "$(prop modetest.frl-hdr HDMI-A-1 allm_capable)"
expect "props: allm_mode Disabled" Disabled "$(prop modetest.frl-hdr HDMI-A-1 allm_mode)"
expect "props: blob is one hex string" "000000000200ee7c78408e3a1c75601da30b093d47401f0300001f031f030000" \
	"$(prop modetest.frl-hdr HDMI-A-1 HDR_OUTPUT_METADATA)"
expect "props: empty blob is empty" "" "$(prop modetest.frl-hdr HDMI-A-1 TILE)"
expect "props: EDID blob is all its bytes (512 bytes, 1024 hex digits)" 1024 "$(prop modetest.frl-hdr HDMI-A-1 EDID | awk '{ print length($0) }')"
expect "props: a property name with a space" None "$(prop modetest.frl-hdr HDMI-A-1 'scaling mode')"
expect "props: CRTC properties do not leak in" "" "$(prop modetest.frl-hdr HDMI-A-1 VRR_ENABLED)"
expect "props: unknown connector prints nothing" "" "$(modetest_connector_props HDMI-A-9 < "$FX/modetest.frl-hdr")"
expect "props: empty input prints nothing" "" "$(modetest_connector_props HDMI-A-1 < /dev/null)"

expect "crtc index: HDMI-A-1 is on the first CRTC" 0 "$(modetest_crtc_index HDMI-A-1 < "$FX/modetest.frl-hdr")"
expect "crtc index: a connector with no encoder has none" "" "$(modetest_crtc_index DP-1 < "$FX/modetest.frl-hdr")"
expect "crtc index: unknown connector" "" "$(modetest_crtc_index HDMI-A-9 < "$FX/modetest.frl-hdr")"
expect "crtc index: the position in the list, not the id (older fixture)" 0 \
	"$(modetest_crtc_index HDMI-A-1 < "$FX/modetest.144hz")"
# Move the encoder to the third CRTC: 119 is index 2 in the list.
expect "crtc index: third CRTC" 2 \
	"$(sed 's/^135\t109\tTMDS/135\t119\tTMDS/' "$FX/modetest.frl-hdr" | modetest_crtc_index HDMI-A-1)"

HDR=$(sed -n '/^HPO:/p' "$FX/dtn_log.frl-hdr")
ROW=$(sed -n '/^HPO:/{n;p;}' "$FX/dtn_log.frl-hdr")
expect "hpo_fields: header and row" "pixel_format=4:4:4
depth=10" "$(hpo_fields "$HDR" "$ROW")"
expect "hpo_fields: columns swapped, found by name" "depth=10
pixel_format=4:4:4" \
	"$(hpo_fields "$(sed -n '/^HPO:/p' "$FX/dtn_log.frl-reordered")" "$(sed -n '/^HPO:/{n;p;}' "$FX/dtn_log.frl-reordered")")"
expect "hpo_fields: a row with a cell missing is refused" "" "$(hpo_fields "$HDR" "[0]:  0   Training   4:4:4   10" || true)"

# --- status --json --------------------------------------------------------
# run_status modetest-fixture dtn-fixture crtc-fixture : writes $T/out.json, sets RC
mk_tree() { # dir crtc-fixture
	mkdir -p "$1/sys/card0-HDMI-A-1" "$1/dri/0/HDMI-A-1"
	echo connected > "$1/sys/card0-HDMI-A-1/status"
	echo enabled > "$1/sys/card0-HDMI-A-1/enabled"
	if [ "$2" != none ]; then cp -R "$FX/crtc/$2" "$1/dri/0/crtc-0"; fi
}
# ALLM inputs: the module parameter and the grub drop-in. Empty directories by
# default so the machine running the tests never leaks in.
MODPARAM=none GRUBD=none
mkdir -p "$T/empty"
run_status() {
	local mt=$1 dtn=$2 crtc=$3 setup=${4:-$SETUP} mtpath mp gd
	case "$mt" in none|/*) mtpath=$mt ;; *) mtpath=$FX/$mt ;; esac
	local d=$T/tree
	chmod -R u+rwx "$d" 2>/dev/null || true
	rm -rf "$d"; mk_tree "$d" "$crtc"
	case "$dtn" in
		none) ;;
		/*) cp "$dtn" "$d/dri/0/amdgpu_dm_dtn_log" ;;
		*) cp "$FX/$dtn" "$d/dri/0/amdgpu_dm_dtn_log" ;;
	esac
	: > "$T/count"
	if [ "$MODPARAM" = none ]; then mp=$T/empty; else mp=$FX/modparam/$MODPARAM; fi
	if [ "$GRUBD" = none ]; then gd=$T/empty; else gd=$FX/grubd/$GRUBD; fi
	RC=0
	STUB_COUNT=$T/count STUB_MODETEST=$mtpath \
		HDMI_FRL_TEST_SYSFS=$d/sys HDMI_FRL_TEST_DEBUGFS=$d/dri \
		HDMI_FRL_TEST_MODPARAM=$mp HDMI_FRL_TEST_GRUBD=$gd \
		PATH="$T/bin:$PATH" bash "$setup" status --json --dir "$T" > "$T/out.json" 2> "$T/err" || RC=$?
}
field() { # python expression on the parsed object d -> printed
	python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$T/out.json" "$1"
}
signal() { field 'json.dumps([d["display"]["pixel"][k] for k in ("color_model","chroma","chroma_source","bpc","bpc_source","colorimetry")])'; }
hdr() { field 'json.dumps([d["display"]["hdr"]["active"], d["display"]["hdr"]["eotf"], d["display"]["content_type"], d["allm"]["capable"], d["allm"]["mode"]])'; }
warned() { field "sum('$1' in w for w in d['warnings'])"; }

# FRL 4K144 HDR, real capture: RGB 4:4:4, 10 bit from the HPO table.
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr
expect "frl hdr: exit 0" 0 "$RC"
expect "frl hdr: signal" '["rgb", "4:4:4", "hpo", 10, "hpo", "BT2020_RGB"]' "$(signal)"
expect "frl hdr: link" '["frl", "hpo-row"]' "$(field 'json.dumps([d["display"]["link"]["state"], d["display"]["link"]["rule"]])')"
expect "frl hdr: hdr, content type, allm" '[true, "pq", "game", true, "disabled"]' "$(hdr)"
expect "frl hdr: vrr capable from the same run" True "$(field 'd["vrr"]["capable"]')"
expect "frl hdr: modetest ran once" 1 "$(wc -l < "$T/count" | tr -d ' ')"
expect "frl hdr: no patched module readback: allm and content_type_sent null" '[None, None, None, None]' \
	"$(field '[d["allm"]["active"], d["allm"]["driver_default"], d["allm"]["configured"], d["display"]["content_type_sent"]]')"
expect "frl hdr: schema still 1" 1 "$(field 'd["schema"]')"
expect "frl hdr: no pixel warnings" 0 "$(warned 'HPO')"

# The same dump with the columns in another order is the same answer.
run_status modetest.frl-hdr dtn_log.frl-reordered frl-hdr
expect "reordered HPO columns: same signal" '["rgb", "4:4:4", "hpo", 10, "hpo", "BT2020_RGB"]' "$(signal)"

# 4:2:0 over FRL.
run_status modetest.frl-hdr dtn_log.frl-420 frl-420
expect "frl 4:2:0, 8 bit: ycbcr" '["ycbcr", "4:2:0", "hpo", 8, "hpo", "BT2020_YCC"]' "$(signal)"

# HPO and CRTC disagree on the depth: the HPO table wins, with a warning.
run_status modetest.frl-hdr dtn_log.frl-hdr tmds-4k60
expect "hpo and crtc disagree: hpo wins" '["rgb", "4:4:4", "hpo", 10, "hpo", "BT2020_RGB"]' "$(signal)"
expect "hpo and crtc disagree: warns" 1 "$(warned 'bit depth')"

# Two HPO rows: the first one is used, with a warning.
awk '{ print } /^\[0\]:.*Training/ { sub(/^\[0\]/, "[1]"); print }' "$FX/dtn_log.frl-hdr" > "$T/dtn_log.two-rows"
run_status modetest.frl-hdr "$T/dtn_log.two-rows" frl-hdr
expect "two HPO rows: first one used" '["rgb", "4:4:4", "hpo", 10, "hpo", "BT2020_RGB"]' "$(signal)"
expect "two HPO rows: warns" 1 "$(warned 'HPO table has 2 rows')"

# ALLM and content type come from the connector properties.
run_status "$T/mt.allm2" dtn_log.frl-hdr frl-hdr
expect "allm_mode Always On" '[true, "pq", "game", true, "always_on"]' "$(hdr)"
run_status "$T/mt.allm1" dtn_log.frl-hdr frl-hdr
expect "allm_mode Dynamic" '[true, "pq", "game", true, "dynamic"]' "$(hdr)"
run_status "$T/mt.nodata" dtn_log.frl-hdr frl-hdr
expect "content type No Data" '[true, "pq", "no_data", true, "disabled"]' "$(hdr)"
awk '/^\t8 HDR_OUTPUT_METADATA:/ { skip = 1; print; next } skip && /^\t\t\t/ { next } { print }' "$FX/modetest.frl-hdr" > "$T/mt.nohdr"
run_status "$T/mt.nohdr" dtn_log.frl-hdr frl-hdr
expect "empty HDR_OUTPUT_METADATA blob: not active, no eotf" '[false, null, "game", true, "disabled"]' "$(hdr)"
sed 's/^\t\t\t000000000200/\t\t\t000000000000/' "$FX/modetest.frl-hdr" > "$T/mt.sdr"
run_status "$T/mt.sdr" dtn_log.frl-hdr frl-hdr
expect "EOTF 0 is sdr" '[false, "sdr", "game", true, "disabled"]' "$(hdr)"
sed 's/^\t\t\t000000000200/\t\t\t000000000300/' "$FX/modetest.frl-hdr" > "$T/mt.hlg"
run_status "$T/mt.hlg" dtn_log.frl-hdr frl-hdr
expect "EOTF 3 is hlg" '[true, "hlg", "game", true, "disabled"]' "$(hdr)"

# TMDS 4K60, real capture: below 600 MHz the link rules say unknown (rule 3
# needs an active mode above 600000 kHz), RGB gives 4:4:4, the depth is the CRTC's.
run_status modetest.tmds-4k60 dtn_log.tmds-4k60 tmds-4k60
expect "tmds 4k60: link unknown, 594000 kHz active" '["unknown", "none -> unknown", "nohpo", 594000]' \
	"$(field 'json.dumps([d["display"]["link"][k] for k in ("state","rule","dump","active_pixel_clock_khz")])')"
expect "tmds 4k60: rgb, 4:4:4 from rgb, 8 bit from the crtc" '["rgb", "4:4:4", "rgb", 8, "crtc", "BT2020_RGB"]' "$(signal)"

# TMDS 4K120 (derived): rule 3, so 4:2:0 from the clock.
run_status modetest.tmds-4k120 dtn_log.tmds-4k60 tmds-4k120
expect "tmds 4k120: link tmds" tmds "$(field 'd["display"]["link"]["state"]')"
expect "tmds 4k120: 4:2:0 from the pixel clock" '["ycbcr", "4:2:0", "tmds-clock", 8, "crtc", "BT2020_YCC"]' "$(signal)"

# TMDS 4K60 YCbCr (derived): BT709_YCC counts only with Colorspace Default,
# and the chroma stays unknown below 600 MHz.
run_status modetest.tmds-4k60-default dtn_log.tmds-4k60 tmds-4k60-default
expect "tmds 4k60 BT709_YCC with Colorspace Default: ycbcr, chroma unknown" \
	'["ycbcr", null, null, 8, "crtc", "BT709_YCC"]' "$(signal)"
run_status modetest.tmds-4k60 dtn_log.tmds-4k60 tmds-4k60-default
expect "BT709_YCC while Colorspace is BT2020_RGB: colour model unknown" \
	'[null, null, null, 8, "crtc", "BT709_YCC"]' "$(signal)"

# 4:2:0 on the link but an RGB colorspace: colour model dropped, with a warning.
run_status modetest.frl-hdr dtn_log.frl-420 frl-hdr
expect "hpo 4:2:0 with an RGB colorspace: colour model unknown" '[null, "4:2:0", "hpo", 8, "hpo", "BT2020_RGB"]' "$(signal)"
expect "hpo 4:2:0 with an RGB colorspace: warns" 1 "$(warned 'colour model')"

# Truncated dump: no HPO source, the rest from the CRTC and the colorspace.
run_status modetest.frl-hdr dtn_log.truncated frl-hdr
expect "truncated dump: no hpo sources" '["rgb", "4:4:4", "rgb", 10, "crtc", "BT2020_RGB"]' "$(signal)"
expect "truncated dump: exit 0" 0 "$RC"

# No CRTC files at all (an idle CRTC fails with ENODEV; nothing readable).
run_status modetest.tmds-4k60 dtn_log.tmds-4k60 none
expect "no crtc files: signal null" '[null, null, null, null, null, null]' "$(signal)"
expect "no crtc files: exit 0" 0 "$RC"

# A CRTC file that fails to read (ENODEV on the real thing) reads as nothing.
run_status modetest.tmds-4k60 dtn_log.tmds-4k60 tmds-4k60
rm -f "$T/tree/dri/0/crtc-0/amdgpu_current_bpc" "$T/tree/dri/0/crtc-0/amdgpu_current_colorspace"
mkdir "$T/tree/dri/0/crtc-0/amdgpu_current_bpc" "$T/tree/dri/0/crtc-0/amdgpu_current_colorspace"
RC=0
STUB_COUNT=$T/count STUB_MODETEST=$FX/modetest.tmds-4k60 HDMI_FRL_TEST_SYSFS=$T/tree/sys HDMI_FRL_TEST_DEBUGFS=$T/tree/dri \
	PATH="$T/bin:$PATH" bash "$SETUP" status --json --dir "$T" > "$T/out.json" 2> "$T/err" || RC=$?
expect "unreadable crtc files that fail on read: signal null" '[null, null, null, null, null, null]' "$(signal)"
expect "unreadable crtc files that fail on read: exit 0" 0 "$RC"

# Not root: debugfs unreadable -> nulls and one warning. Root reads anything.
if [ "$(id -u)" != 0 ]; then
	run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr
	chmod 000 "$T/tree/dri"
	RC=0
	STUB_COUNT=$T/count STUB_MODETEST=$FX/modetest.frl-hdr HDMI_FRL_TEST_SYSFS=$T/tree/sys HDMI_FRL_TEST_DEBUGFS=$T/tree/dri \
		PATH="$T/bin:$PATH" bash "$SETUP" status --json --dir "$T" > "$T/out.json" 2> "$T/err" || RC=$?
	chmod 755 "$T/tree/dri"
	expect "debugfs unreadable: exit 0" 0 "$RC"
	expect "debugfs unreadable: signal null" '[null, null, null, null, null, null]' "$(signal)"
	expect "debugfs unreadable: says why" 1 "$(warned 'not root: pixel format, bit depth and colorimetry (debugfs) cannot be read')"
	expect "debugfs unreadable: hdr and allm come from modetest, still there" '[true, "pq", "game", true, "disabled"]' "$(hdr)"
else
	printf 'skipped debugfs-unreadable cases: running as root\n'
fi

# ALLM readback from the patched module: the live stream, the module parameter
# and the grub drop-in. content_type there is the DC enum (8 is game).
allm() { field 'json.dumps([d["allm"][k] for k in ("active","driver_default","configured")] + [d["display"]["content_type_sent"], d["reboot_needed"], d["reboot_reasons"]])'; }
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm
expect "live stream: allm active, content type sent game" '[true, null, null, "game", false, []]' "$(allm)"
MODPARAM=always-on
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm
expect "module parameter 2: driver default always_on, no drop-in" '[true, "always_on", null, "game", false, []]' "$(allm)"
GRUBD=dynamic
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm
expect "drop-in dynamic while 2 runs: reboot wanted" \
	'[true, "always_on", "dynamic", "game", true, ["allm_configured_differs"]]' "$(allm)"
expect "drop-in differs: the reason in words" \
	"the next boot sets the ALLM default to dynamic but always_on is running" "$(field 'd["reboot_reason"]')"
GRUBD=always-on
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm
expect "drop-in matches the running value: no reboot" '[true, "always_on", "always_on", "game", false, []]' "$(allm)"
MODPARAM=dynamic
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm
expect "drop-in always_on while 1 runs: reboot wanted" '[true, "dynamic", "always_on", "game", true, ["allm_configured_differs"]]' "$(allm)"
MODPARAM=none GRUBD=dynamic
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm
expect "stock module (no parameter), drop-in set: configured only, no reason" \
	'[true, null, "dynamic", "game", false, []]' "$(allm)"
MODPARAM=garbage GRUBD=none
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm
expect "parameter value that is not 0, 1 or 2: null" '[true, null, null, "game", false, []]' "$(allm)"
MODPARAM=none GRUBD=none
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm-off
expect "ALLM off, DC content type 1: graphics" '[false, null, null, "graphics", false, []]' "$(allm)"
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm-unknown
expect "DC content type 3 is not a value: null" '[true, null, null, null, false, []]' "$(allm)"
expect "DC content type 3: warns" 1 "$(warned 'unknown content type')"
for pair in 0:no_data 1:graphics 2:photo 4:cinema 8:game; do
	mkdir -p "$T/ct"; rm -rf "$T/ct/c"; cp -R "$FX/crtc/frl-hdr-allm" "$T/ct/c"
	printf 'allm_active: 1\ncontent_type: %s\n' "${pair%%:*}" > "$T/ct/c/amdgpu_current_hdmi"
	d=$T/tree; chmod -R u+rwx "$d" 2>/dev/null || true; rm -rf "$d"; mk_tree "$d" none; cp -R "$T/ct/c" "$d/dri/0/crtc-0"
	cp "$FX/dtn_log.frl-hdr" "$d/dri/0/amdgpu_dm_dtn_log"
	STUB_COUNT=$T/count STUB_MODETEST=$FX/modetest.frl-hdr HDMI_FRL_TEST_SYSFS=$d/sys HDMI_FRL_TEST_DEBUGFS=$d/dri \
		HDMI_FRL_TEST_MODPARAM=$T/empty HDMI_FRL_TEST_GRUBD=$T/empty PATH="$T/bin:$PATH" \
		bash "$SETUP" status --json --dir "$T" > "$T/out.json" 2> "$T/err" || true
	expect "DC content type ${pair%%:*} is ${pair##*:}" "${pair##*:}" "$(field 'd["display"]["content_type_sent"]')"
done
# An empty file (no stream) reads as nothing.
run_status modetest.frl-hdr dtn_log.frl-hdr frl-hdr-allm
: > "$T/tree/dri/0/crtc-0/amdgpu_current_hdmi"
STUB_COUNT=$T/count STUB_MODETEST=$FX/modetest.frl-hdr HDMI_FRL_TEST_SYSFS=$T/tree/sys HDMI_FRL_TEST_DEBUGFS=$T/tree/dri \
	HDMI_FRL_TEST_MODPARAM=$T/empty HDMI_FRL_TEST_GRUBD=$T/empty PATH="$T/bin:$PATH" \
	bash "$SETUP" status --json --dir "$T" > "$T/out.json" 2> "$T/err" || true
expect "empty amdgpu_current_hdmi: nulls" '[null, null, null, null, false, []]' "$(allm)"

# modetest fails: hdr, content type and allm are null.
run_status none dtn_log.frl-hdr frl-hdr
expect "modetest fails: hdr, content type, allm null" '[null, null, null, null, null]' "$(hdr)"
expect "modetest fails: exit 0" 0 "$RC"
expect "modetest fails: vrr capable null" None "$(field 'd["vrr"]["capable"]')"

# modetest missing altogether, when the machine has none.
if command -v modetest >/dev/null 2>&1; then
	printf 'skipped modetest-missing case: modetest is installed here\n'
else
	mkdir -p "$T/bin-nomt"; cp "$T/bin/systemctl" "$T/bin-nomt/"
	d=$T/nomt; mk_tree "$d" frl-hdr; cp "$FX/dtn_log.frl-hdr" "$d/dri/0/amdgpu_dm_dtn_log"
	RC=0
	HDMI_FRL_TEST_SYSFS=$d/sys HDMI_FRL_TEST_DEBUGFS=$d/dri PATH="$T/bin-nomt:$PATH" \
		bash "$SETUP" status --json --dir "$T" > "$T/out.json" 2> "$T/err" || RC=$?
	expect "modetest missing: exit 0" 0 "$RC"
	expect "modetest missing: hdr, content type, allm null" '[null, null, null, null, null]' "$(hdr)"
	expect "modetest missing: says so" 1 "$(warned 'modetest is missing')"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
