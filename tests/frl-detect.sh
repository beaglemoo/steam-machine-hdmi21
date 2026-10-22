#!/usr/bin/env bash
# Tests selfheal/hdmi-frl-resume.sh against fixture amdgpu_dm_dtn_log dumps.
#
#   bash tests/frl-detect.sh
#
# Part 1 feeds the fixtures to classify_dtn_log and read_link_state and checks
# the three link states (frl, tmds, unknown). Part 2 runs the whole script
# against a fake sysfs/debugfs tree, with the HDMI_FRL_TEST_* overrides the
# script offers for this purpose and a stub sleep, and checks what it does to
# trigger_hotplug. Part 3 checks that setup.sh keeps a module built by 1.0.0
# when upgrading. Needs no root, no GPU and no SteamOS.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT=$HERE/../selfheal/hdmi-frl-resume.sh
FX=$HERE/fixtures
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
pass=0
ok() { pass=$((pass + 1)); printf 'ok      %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAILED  %s\n' "$1"; }
expect() { # name, want, got
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi
}
expect_in() { # name, needle, haystack
	case "$3" in
		*"$2"*) ok "$1" ;;
		*) bad "$1 (no '$2' in: $3)" ;;
	esac
}
expect_not_in() { # name, needle, haystack
	case "$3" in
		*"$2"*) bad "$1 ('$2' found in: $3)" ;;
		*) ok "$1" ;;
	esac
}

# --- part 1: detection ----------------------------------------------------
# shellcheck disable=SC1090
. "$SCRIPT"

state_of() { classify_dtn_log < "$1"; }

expect "frl fixture is frl" frl "$(state_of "$FX/dtn_log.frl")"
expect "tmds fixture (with DP HPO tables) is tmds" tmds "$(state_of "$FX/dtn_log.tmds")"
expect "truncated dump is unknown" unknown "$(state_of "$FX/dtn_log.truncated")"
expect "complete dump with no OTG row is unknown" unknown "$(state_of "$FX/dtn_log.idle")"
expect "empty dump is unknown" unknown "$(state_of "$FX/dtn_log.empty")"
expect "garbage is unknown" unknown "$(state_of "$FX/dtn_log.garbage")"
expect "dump without [dtn end] is unknown" unknown \
	"$(grep -v '^\[dtn end\]' "$FX/dtn_log.tmds" | classify_dtn_log)"
expect "dump without [dtn begin] is unknown" unknown \
	"$(grep -v '^\[dtn begin\]' "$FX/dtn_log.tmds" | classify_dtn_log)"
expect "frl row alone, dump cut short, is still frl" frl \
	"$(grep -A1 '^HPO:' "$FX/dtn_log.frl" | classify_dtn_log)"
expect "HPO header with no row is not frl" tmds \
	"$(grep -v '^\[0\]:          0   Training' "$FX/dtn_log.frl" | classify_dtn_log)"
expect "an indented HPO: is not a header" tmds \
	"$(sed 's/^HPO:/ HPO:/' "$FX/dtn_log.frl" | classify_dtn_log)"
expect "two HPO blocks are frl" frl \
	"$( { cat "$FX/dtn_log.frl"; sed -n '/^HPO:/,/^\[0\]:.*Training/p' "$FX/dtn_log.frl"; } | classify_dtn_log)"
expect "HPO rows are printed for --check" \
	"[0]:          0   Training        4:4:4      10              1       4   ACTIVE       3840        160" \
	"$(classify_dtn_log rows < "$FX/dtn_log.frl")"
expect "tmds fixture has no HPO rows" "" "$(classify_dtn_log rows < "$FX/dtn_log.tmds")"

mk_tree() { # dir: fake /sys/class/drm and debugfs for card0 / HDMI-A-1
	mkdir -p "$1/sys/card0-HDMI-A-1" "$1/dri/0/HDMI-A-1"
	echo connected > "$1/sys/card0-HDMI-A-1/status"
	echo enabled > "$1/sys/card0-HDMI-A-1/enabled"
	echo sentinel > "$1/dri/0/HDMI-A-1/trigger_hotplug"
	echo "quiet amdgpu.dcfeaturemask=0x402 splash" > "$1/cmdline"
}

read_state() { # dir -> "state|why"
	# shellcheck disable=SC2034 # read by read_link_state from the sourced script
	DRM_SYSFS=$1/sys DEBUGFS=$1/dri
	read_link_state 0 card0-HDMI-A-1
	printf '%s|%s' "$STATE" "$WHY"
}

R=$T/read; mk_tree "$R"
cp "$FX/dtn_log.frl" "$R/dri/0/amdgpu_dm_dtn_log"
expect "read_link_state frl" frl "$(read_state "$R" | cut -d'|' -f1)"
cp "$FX/dtn_log.tmds" "$R/dri/0/amdgpu_dm_dtn_log"
expect "read_link_state tmds" tmds "$(read_state "$R" | cut -d'|' -f1)"
echo disabled > "$R/sys/card0-HDMI-A-1/enabled"
expect "read_link_state: connector not enabled is unknown" unknown "$(read_state "$R" | cut -d'|' -f1)"
echo enabled > "$R/sys/card0-HDMI-A-1/enabled"
rm "$R/dri/0/amdgpu_dm_dtn_log"
expect "read_link_state: missing dtn_log is unknown" unknown "$(read_state "$R" | cut -d'|' -f1)"
: > "$R/dri/0/amdgpu_dm_dtn_log"
expect "read_link_state: empty dtn_log is unknown" unknown "$(read_state "$R" | cut -d'|' -f1)"
cp "$FX/dtn_log.frl" "$R/dri/0/amdgpu_dm_dtn_log"
if [ "$(id -u)" != 0 ]; then
	chmod 000 "$R/dri/0/amdgpu_dm_dtn_log"
	expect "read_link_state: unreadable dtn_log is unknown" unknown "$(read_state "$R" | cut -d'|' -f1)"
	chmod 644 "$R/dri/0/amdgpu_dm_dtn_log"
fi

# --- part 2: the whole script ---------------------------------------------
# The stub sleep never sleeps. STUB_FLIP says when the stub swaps the dump for
# the FRL fixture, which is how a link coming up on its own (first) or after a
# re-detect (hotplug, once trigger_hotplug holds the final 1) is simulated.
mkdir -p "$T/bin"
cat > "$T/bin/sleep" <<'STUB'
#!/bin/sh
n=$(cat "$STUB_DIR/sleeps" 2>/dev/null || echo 0)
echo $((n + 1)) > "$STUB_DIR/sleeps"
case "${STUB_FLIP:-}" in
	first) cp "$STUB_FRL" "$STUB_DTN" ;;
	hotplug) [ "$(cat "$STUB_HOTPLUG")" = 1 ] && cp "$STUB_FRL" "$STUB_DTN" ;;
esac
exit 0
STUB
chmod +x "$T/bin/sleep"

run_script() { # dir, dump fixture, flip, args... ; sets OUT and RC
	local dir=$1 dump=$2 flip=$3
	shift 3
	rm -rf "$dir"; mk_tree "$dir"
	[ "$dump" = none ] || cp "$FX/$dump" "$dir/dri/0/amdgpu_dm_dtn_log"
	rm -f "$dir/sleeps"
	RC=0
	OUT=$(STUB_DIR=$dir STUB_FLIP=$flip STUB_FRL=$FX/dtn_log.frl \
		STUB_DTN=$dir/dri/0/amdgpu_dm_dtn_log STUB_HOTPLUG=$dir/dri/0/HDMI-A-1/trigger_hotplug \
		HDMI_FRL_TEST_CMDLINE=$dir/cmdline HDMI_FRL_TEST_SYSFS=$dir/sys HDMI_FRL_TEST_DEBUGFS=$dir/dri \
		PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>&1) || RC=$?
}
hotplug_of() { cat "$1/dri/0/HDMI-A-1/trigger_hotplug"; }

D=$T/run

run_script "$D" dtn_log.frl none
expect "state=frl: exit 0" 0 "$RC"
expect "state=frl: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "state=frl: says so" "FRL link is up, nothing to do" "$OUT"
expect_in "state=frl: logs the HPO row" "HPO row: [0]:" "$OUT"
expect_not_in "state=frl: no mode clock talk" "kHz" "$OUT"

run_script "$D" dtn_log.idle first
expect "link comes up during the wait: exit 0" 0 "$RC"
expect "link comes up during the wait: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "link comes up during the wait: says so" "FRL link is up, nothing to do" "$OUT"

run_script "$D" dtn_log.empty none
expect "state=unknown (empty dump): exit 0" 0 "$RC"
expect "state=unknown (empty dump): trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "state=unknown: says why and that it leaves the link alone" "leaving it alone" "$OUT"

run_script "$D" none none
expect "state=unknown (no dtn_log): exit 0" 0 "$RC"
expect "state=unknown (no dtn_log): trigger_hotplug never written" sentinel "$(hotplug_of "$D")"

run_script "$D" dtn_log.tmds hotplug
expect "state=tmds, FRL after one cycle: exit 0" 0 "$RC"
expect "state=tmds, FRL after one cycle: ends on a 1 write" 1 "$(hotplug_of "$D")"
expect_in "state=tmds, FRL after one cycle: restored" "FRL link restored" "$OUT"
expect_in "state=tmds, FRL after one cycle: only one attempt" "attempt 1/5" "$OUT"
expect_not_in "state=tmds, FRL after one cycle: no second attempt" "attempt 2/5" "$OUT"

run_script "$D" dtn_log.tmds none
expect "state=tmds throughout: exit 1" 1 "$RC"
expect_in "state=tmds throughout: all five attempts" "attempt 5/5" "$OUT"
expect_in "state=tmds throughout: gives up" "did not come back after 5 attempts" "$OUT"

run_script "$D" dtn_log.tmds none --check
expect "--check, tmds: exit 0" 0 "$RC"
expect "--check, tmds: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "--check, tmds: reports the state" "link state tmds" "$OUT"
expect_in "--check, tmds: reports no HPO row" "HPO row: none" "$OUT"

run_script "$D" dtn_log.frl none --check
expect "--check, frl: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "--check, frl: reports the state" "link state frl" "$OUT"
expect_in "--check, frl: reports the HPO row" "HPO row: [0]:          0   Training" "$OUT"

run_script "$D" dtn_log.frl none --force
expect "--force, frl: exit 0" 0 "$RC"
expect_in "--force, frl: runs a cycle" "attempt 1/5" "$OUT"
expect "--force, frl: trigger_hotplug written" 1 "$(hotplug_of "$D")"

rm -rf "$D"; mk_tree "$D"
cp "$FX/dtn_log.tmds" "$D/dri/0/amdgpu_dm_dtn_log"
echo "quiet splash" > "$D/cmdline"
RC=0
OUT=$(HDMI_FRL_TEST_CMDLINE=$D/cmdline HDMI_FRL_TEST_SYSFS=$D/sys HDMI_FRL_TEST_DEBUGFS=$D/dri \
	PATH="$T/bin:$PATH" bash "$SCRIPT" 2>&1) || RC=$?
expect "no FRL mask: exit 0" 0 "$RC"
expect "no FRL mask: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "no FRL mask: says so" "no FRL mask" "$OUT"

# --- part 3: upgrade path -------------------------------------------------
# setup.sh decides in module_is_current whether a 1.0.0 install, which carries
# no patch stamp, can keep its module. Pull the function out of setup.sh and
# run it against a fake out/ with a stub uname and modinfo.
SETUP=$HERE/../setup.sh
eval "$(sed -n '/^LEGACY_PATCHES_SHA=/p' "$SETUP")"
eval "$(sed -n '/^module_is_current() {/,/^}/p' "$SETUP")"
if ! command -v sha256sum >/dev/null 2>&1; then
	printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$T/bin/sha256sum"
	chmod +x "$T/bin/sha256sum"
fi
cat > "$T/bin/uname" <<'STUB'
#!/bin/sh
echo 7.2.4-valve1-1-neptune-72-g0123456789ab
STUB
cat > "$T/bin/modinfo" <<'STUB'
#!/bin/sh
echo "$STUB_VERMAGIC SMP preempt mod_unload"
STUB
chmod +x "$T/bin/uname" "$T/bin/modinfo"
KREL=7.2.4-valve1-1-neptune-72-g0123456789ab

U=$T/upgrade
mkdir -p "$U/out" "$U/patches"
cp "$HERE"/../patches/*.patch "$U/patches/"
printf 'x' > "$U/out/amdgpu-$KREL.ko.zst"
echo "$KREL SMP preempt mod_unload" > "$U/out/amdgpu-$KREL.ko.zst.vermagic"
current() { # vermagic kernel -> yes|no
	if SELF_DIR=$U STUB_VERMAGIC=$1 PATH="$T/bin:$PATH" module_is_current; then echo yes; else echo no; fi
}
expect "1.0.0 module (no stamp, shipped patches) is kept" yes "$(current "$KREL")"
echo "$LEGACY_PATCHES_SHA" > "$U/out/amdgpu-$KREL.ko.zst.patches"
expect "stamped module with the same patches is kept" yes "$(current "$KREL")"
echo deadbeef > "$U/out/amdgpu-$KREL.ko.zst.patches"
expect "stamp from different patches forces a rebuild" no "$(current "$KREL")"
rm "$U/out/amdgpu-$KREL.ko.zst.patches"
echo "# changed" >> "$U/patches/0001-amdgpu-dm-frl-vrr-freesync-caps.patch"
expect "changed patches force a rebuild even with no stamp" no "$(current "$KREL")"
cp "$HERE"/../patches/*.patch "$U/patches/"
expect "module built for another kernel forces a rebuild" no "$(current 7.2.5-other)"
expect "HDMI21_REBUILD=1 forces a rebuild" no \
	"$(HDMI21_REBUILD=1 current "$KREL")"
rm "$U/out/amdgpu-$KREL.ko.zst"
expect "no module in out/ builds" no "$(current "$KREL")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
