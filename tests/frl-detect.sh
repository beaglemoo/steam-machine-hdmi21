#!/usr/bin/env bash
# Tests selfheal/hdmi-frl-resume.sh against fixture amdgpu_dm_dtn_log dumps.
#
#   bash tests/frl-detect.sh
#
# Part 1 feeds the fixtures to classify_dtn_log, modetest_clocks and
# read_link_state and checks the three link states (frl, tmds, unknown) and the
# rule that decided each. Part 2 runs the whole script
# against a fake sysfs/debugfs tree, with the HDMI_FRL_TEST_* overrides the
# script offers for this purpose and stub sleep, modetest and udevadm, and
# checks what it does to trigger_hotplug and in which order. Part 3 checks that setup.sh keeps a module built by 1.0.0
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

# --- stubs ----------------------------------------------------------------
# sleep never sleeps. modetest prints the fixture named by STUB_MODETEST
# (nothing and rc 1 for "none"). Each stub appends to $STUB_DIR/order so the
# tests can check the sequence of events. STUB_FLIP says when the world turns
# into the FRL fixture: "first" at the first sleep (the link comes up by
# itself), "hotplug" once trigger_hotplug holds the final 1, "udev" once a
# change uevent has been emitted (the compositor only follows the event).
mkdir -p "$T/bin"
cat > "$T/bin/sleep" <<'STUB'
#!/bin/sh
n=$(cat "$STUB_DIR/sleeps" 2>/dev/null || echo 0)
echo $((n + 1)) > "$STUB_DIR/sleeps"
echo "sleep hp=$(cat "$STUB_HOTPLUG" 2>/dev/null)" >> "$STUB_DIR/order"
case "${STUB_FLIP:-}" in
	first) cp "$STUB_FRL" "$STUB_DTN" ;;
	hotplug) [ "$(cat "$STUB_HOTPLUG")" = 1 ] && cp "$STUB_FRL" "$STUB_DTN" ;;
esac
exit 0
STUB
cat > "$T/bin/udevadm" <<'STUB'
#!/bin/sh
echo udev >> "$STUB_DIR/order"
[ "${STUB_FLIP:-}" = udev ] && cp "$STUB_FRL" "$STUB_DTN"
exit 0
STUB
cat > "$T/bin/modetest" <<'STUB'
#!/bin/sh
echo poll >> "$STUB_DIR/order"
[ "$STUB_MODETEST" != none ] || exit 1
cat "$STUB_MODETEST"
STUB
chmod +x "$T/bin/sleep" "$T/bin/udevadm" "$T/bin/modetest"

# --- part 1: classification ------------------------------------------------
# shellcheck disable=SC1090
. "$SCRIPT"

dump_of() { classify_dtn_log < "$1"; }

expect "frl fixture has an HPO row" hpo "$(dump_of "$FX/dtn_log.frl")"
expect "tmds fixture (with DP HPO tables) has none" nohpo "$(dump_of "$FX/dtn_log.tmds")"
expect "truncated dump is incomplete" incomplete "$(dump_of "$FX/dtn_log.truncated")"
expect "complete dump with no OTG row is incomplete" incomplete "$(dump_of "$FX/dtn_log.idle")"
expect "empty dump is incomplete" incomplete "$(dump_of "$FX/dtn_log.empty")"
expect "garbage is incomplete" incomplete "$(dump_of "$FX/dtn_log.garbage")"
expect "dump without [dtn end] is incomplete" incomplete \
	"$(grep -v '^\[dtn end\]' "$FX/dtn_log.tmds" | classify_dtn_log)"
expect "dump without [dtn begin] is incomplete" incomplete \
	"$(grep -v '^\[dtn begin\]' "$FX/dtn_log.tmds" | classify_dtn_log)"
expect "HPO row alone, dump cut short, still counts" hpo \
	"$(grep -A1 '^HPO:' "$FX/dtn_log.frl" | classify_dtn_log)"
expect "HPO header with no row does not count" nohpo \
	"$(grep -v '^\[0\]:          0   Training' "$FX/dtn_log.frl" | classify_dtn_log)"
expect "an indented HPO: is not a header" nohpo \
	"$(sed 's/^HPO:/ HPO:/' "$FX/dtn_log.frl" | classify_dtn_log)"
expect "two HPO blocks count" hpo \
	"$( { cat "$FX/dtn_log.frl"; sed -n '/^HPO:/,/^\[0\]:.*Training/p' "$FX/dtn_log.frl"; } | classify_dtn_log)"
expect "HPO rows are printed for --check" \
	"[0]:          0   Training        4:4:4      10              1       4   ACTIVE       3840        160" \
	"$(classify_dtn_log rows < "$FX/dtn_log.frl")"
expect "tmds fixture has no HPO rows" "" "$(classify_dtn_log rows < "$FX/dtn_log.tmds")"

# modetest_clocks: "<highest> <active>" for one connector. The fixtures carry a
# DP-1 with a 1332750 kHz mode on its own CRTC, which must not leak in.
expect "modetest 144 Hz TV" "1332750 1332750" "$(modetest_clocks HDMI-A-1 < "$FX/modetest.144hz")"
expect "modetest 120 Hz TV on 4K120 ignores DP-1" "1188000 1188000" \
	"$(modetest_clocks HDMI-A-1 < "$FX/modetest.120hz-active120")"
expect "modetest 120 Hz TV on 4K60" "1188000 594000" \
	"$(modetest_clocks HDMI-A-1 < "$FX/modetest.120hz-active60")"
expect "modetest idle CRTC (empty mode name) is active 0" "1188000 0" \
	"$(modetest_clocks HDMI-A-1 < "$FX/modetest.120hz-idle")"
expect "modetest DP-1 is parsed on its own" "1332750 1332750" \
	"$(modetest_clocks DP-1 < "$FX/modetest.120hz-active120")"
expect "modetest unknown connector" "0 0" "$(modetest_clocks HDMI-A-9 < "$FX/modetest.144hz")"
expect "modetest empty input" "0 0" "$(modetest_clocks HDMI-A-1 < /dev/null)"

mk_tree() { # dir: fake /sys/class/drm and debugfs for card0 / HDMI-A-1
	mkdir -p "$1/sys/card0-HDMI-A-1" "$1/dri/0/HDMI-A-1"
	echo connected > "$1/sys/card0-HDMI-A-1/status"
	echo enabled > "$1/sys/card0-HDMI-A-1/enabled"
	echo sentinel > "$1/dri/0/HDMI-A-1/trigger_hotplug"
	echo "quiet amdgpu.dcfeaturemask=0x402 splash" > "$1/cmdline"
}

read_state() { # dir, modetest fixture -> "state|rule"
	# shellcheck disable=SC2034 # read by read_link_state from the sourced script
	DRM_SYSFS=$1/sys DEBUGFS=$1/dri
	STUB_DIR=$1 STUB_MODETEST=$2 PATH="$T/bin:$PATH" read_link_state 0 card0-HDMI-A-1 HDMI-A-1
	printf '%s|%s' "$STATE" "$RULE"
}
state_of() { read_state "$@" | cut -d'|' -f1; }
rule_of() { read_state "$@" | cut -d'|' -f2; }
set_dump() { cp "$FX/$2" "$1/dri/0/amdgpu_dm_dtn_log"; }

R=$T/read; mk_tree "$R"
M120=$FX/modetest.120hz-active120
M120_60=$FX/modetest.120hz-active60

# One test per rule.
set_dump "$R" dtn_log.frl
expect "(a) HPO row, 4K120 active: frl" frl "$(state_of "$R" "$M120")"
expect "(a) decided by hpo-row" hpo-row "$(rule_of "$R" "$M120")"
set_dump "$R" dtn_log.tmds
expect "(b) no HPO, mode list up to 1332750: frl" frl "$(state_of "$R" "$FX/modetest.144hz")"
expect_in "(b) decided by the mode list" "mode-list >1200000 (1332750 kHz)" "$(rule_of "$R" "$FX/modetest.144hz")"
expect "(c) no HPO, 4K120 active: tmds" tmds "$(state_of "$R" "$M120")"
expect "(c) decided by the active mode" "active 1188000 kHz without HPO" "$(rule_of "$R" "$M120")"
expect "(d) no HPO, 4K60 active on a 120 Hz TV: unknown" unknown "$(state_of "$R" "$M120_60")"
expect "(d) no rule matched" "none -> unknown" "$(rule_of "$R" "$M120_60")"
set_dump "$R" dtn_log.frl
expect "(e) LG C9: HPO row, highest mode 1188000: frl" frl "$(state_of "$R" "$M120")"

# The edges between the rules.
set_dump "$R" dtn_log.tmds
expect "idle CRTC, no HPO: unknown" unknown "$(state_of "$R" "$FX/modetest.120hz-idle")"
expect "no HPO, modetest has nothing to say: unknown" unknown "$(state_of "$R" none)"
set_dump "$R" dtn_log.truncated
expect "incomplete dump, 4K120 active: unknown" unknown "$(state_of "$R" "$M120")"
set_dump "$R" dtn_log.idle
expect "dump with no OTG row, 4K120 active: unknown" unknown "$(state_of "$R" "$M120")"
set_dump "$R" dtn_log.tmds
echo disabled > "$R/sys/card0-HDMI-A-1/enabled"
expect "connector not enabled, 4K120 active: unknown" unknown "$(state_of "$R" "$M120")"
expect "connector not enabled, mode list up to 1332750: still frl" frl "$(state_of "$R" "$FX/modetest.144hz")"
echo enabled > "$R/sys/card0-HDMI-A-1/enabled"
rm "$R/dri/0/amdgpu_dm_dtn_log"
expect "missing dtn_log, 4K120 active: unknown" unknown "$(state_of "$R" "$M120")"
: > "$R/dri/0/amdgpu_dm_dtn_log"
expect "empty dtn_log, 4K120 active: unknown" unknown "$(state_of "$R" "$M120")"
set_dump "$R" dtn_log.tmds
if [ "$(id -u)" != 0 ]; then
	chmod 000 "$R/dri/0/amdgpu_dm_dtn_log"
	expect "unreadable dtn_log, 4K120 active: unknown" unknown "$(state_of "$R" "$M120")"
	chmod 644 "$R/dri/0/amdgpu_dm_dtn_log"
fi

# --- part 2: the whole script ---------------------------------------------
run_script() { # dir, dump fixture, modetest fixture, flip, args... ; sets OUT and RC
	local dir=$1 dump=$2 mt=$3 flip=$4
	shift 4
	rm -rf "$dir"; mk_tree "$dir"
	[ "$dump" = none ] || cp "$FX/$dump" "$dir/dri/0/amdgpu_dm_dtn_log"
	rm -f "$dir/sleeps" "$dir/order"
	RC=0
	OUT=$(STUB_DIR=$dir STUB_FLIP=$flip STUB_FRL=$FX/dtn_log.frl STUB_MODETEST=$mt \
		STUB_DTN=$dir/dri/0/amdgpu_dm_dtn_log STUB_HOTPLUG=$dir/dri/0/HDMI-A-1/trigger_hotplug \
		HDMI_FRL_TEST_CMDLINE=$dir/cmdline HDMI_FRL_TEST_SYSFS=$dir/sys HDMI_FRL_TEST_DEBUGFS=$dir/dri \
		PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>&1) || RC=$?
}
hotplug_of() { cat "$1/dri/0/HDMI-A-1/trigger_hotplug"; }

D=$T/run

# (a) and (e): FRL by the HPO row never writes, whatever the mode list says.
run_script "$D" dtn_log.frl "$M120" none
expect "(a) HPO row: exit 0" 0 "$RC"
expect "(a) HPO row: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "(a) HPO row: says so" "FRL link is up, nothing to do" "$OUT"
expect_in "(a) HPO row: logs the HPO row" "HPO row: [0]:" "$OUT"
expect_not_in "(a) HPO row: no change event" "emitted a change uevent" "$OUT"

# (b): no HPO but a mode only FRL can carry: capability intact, no writes.
run_script "$D" dtn_log.tmds "$FX/modetest.144hz" none
expect "(b) mode list: exit 0" 0 "$RC"
expect "(b) mode list: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "(b) mode list: says so" "FRL link is up, nothing to do" "$OUT"

# (d): a 120 Hz TV running 4K60 has no HPO encoder on purpose.
run_script "$D" dtn_log.tmds "$M120_60" none
expect "(d) 4K60 on a 120 Hz TV: exit 0" 0 "$RC"
expect "(d) 4K60 on a 120 Hz TV: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "(d) 4K60 on a 120 Hz TV: leaves the link alone" "leaving the link alone" "$OUT"
expect_not_in "(d) 4K60 on a 120 Hz TV: no change event" "emitted a change uevent" "$OUT"

run_script "$D" dtn_log.idle "$M120" first
expect "link comes up during the wait: exit 0" 0 "$RC"
expect "link comes up during the wait: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "link comes up during the wait: says so" "FRL link is up, nothing to do" "$OUT"

run_script "$D" dtn_log.empty "$M120" none
expect "empty dump: exit 0" 0 "$RC"
expect "empty dump: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "empty dump: leaves the link alone" "leaving the link alone" "$OUT"

run_script "$D" none "$M120" none
expect "no dtn_log: exit 0" 0 "$RC"
expect "no dtn_log: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"

run_script "$D" dtn_log.tmds none none
expect "modetest unavailable, no HPO: exit 0" 0 "$RC"
expect "modetest unavailable, no HPO: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"

# (c) and (f): lost FRL is recovered, and the change event comes before the
# post-cycle read. The stub world only turns FRL after the event.
run_script "$D" dtn_log.tmds "$M120" udev
expect "(c) lost FRL, recovers once the event is out: exit 0" 0 "$RC"
expect "(c) lost FRL: trigger_hotplug ends on a 1 write" 1 "$(hotplug_of "$D")"
expect_in "(c) lost FRL: restored" "FRL link restored" "$OUT"
expect_in "(c) lost FRL: says why" "FRL was lost" "$OUT"
expect_in "(c) lost FRL: one attempt" "attempt 1/5" "$OUT"
expect_not_in "(c) lost FRL: no second attempt" "attempt 2/5" "$OUT"
# After the final hotplug write (the sleep that sees hp=1) the next event must
# be the change event, and the first modetest read after it.
expect "(f) change event directly after the hotplug write, then a read" "udev poll" \
	"$(awk '/^sleep hp=1$/ { f = 1; next } f { printf "%s%s", sep, $0; sep = " "; if (++n == 2) exit }' "$D/order")"
expect "(f) no state read between the hotplug write and the event" 0 \
	"$(awk '/^sleep hp=1$/ { f = 1; next } /^udev$/ { f = 0 } f && /^poll$/ { n++ } END { print n + 0 }' "$D/order")"

# Recovery that comes with the hotplug alone (no event needed) still works.
run_script "$D" dtn_log.tmds "$M120" hotplug
expect "lost FRL, back after one cycle: exit 0" 0 "$RC"
expect_in "lost FRL, back after one cycle: restored" "FRL link restored" "$OUT"

run_script "$D" dtn_log.tmds "$M120" none
expect "lost FRL for good: exit 1" 1 "$RC"
expect_in "lost FRL for good: all five attempts" "attempt 5/5" "$OUT"
expect_in "lost FRL for good: gives up" "did not come back after 5 attempts" "$OUT"
expect "lost FRL for good: a change event after every cycle" 5 "$(grep -c '^udev$' "$D/order")"

# --check reports the rule and the inputs and writes nothing.
run_script "$D" dtn_log.tmds "$M120" none --check
expect "--check, lost: exit 0" 0 "$RC"
expect "--check, lost: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "--check, lost: reports the state" "link state tmds" "$OUT"
expect_in "--check, lost: reports the rule" "rule: active 1188000 kHz without HPO" "$OUT"
expect_in "--check, lost: reports the inputs" "inputs: dtn_log nohpo, highest mode 1188000 kHz, active mode 1188000 kHz" "$OUT"
expect_in "--check, lost: reports no HPO row" "HPO row: none" "$OUT"

run_script "$D" dtn_log.frl "$M120" none --check
expect "--check, hpo: trigger_hotplug never written" sentinel "$(hotplug_of "$D")"
expect_in "--check, hpo: reports the rule" "rule: hpo-row" "$OUT"
expect_in "--check, hpo: reports the HPO row" "HPO row: [0]:          0   Training" "$OUT"

run_script "$D" dtn_log.tmds "$FX/modetest.144hz" none --check
expect_in "--check, mode list: reports the rule" "rule: mode-list >1200000 (1332750 kHz)" "$OUT"

run_script "$D" dtn_log.tmds "$M120_60" none --check
expect_in "--check, 4K60: reports the rule" "rule: none -> unknown" "$OUT"
expect_in "--check, 4K60: reports the inputs" "highest mode 1188000 kHz, active mode 594000 kHz" "$OUT"

run_script "$D" dtn_log.frl "$M120" udev --force
expect "--force, frl: exit 0" 0 "$RC"
expect_in "--force, frl: runs a cycle" "attempt 1/5" "$OUT"
expect "--force, frl: trigger_hotplug written" 1 "$(hotplug_of "$D")"

run_script "$D" dtn_log.tmds "$M120_60" udev --force
expect_in "--force, unknown: runs a cycle" "attempt 1/5" "$OUT"

rm -rf "$D"; mk_tree "$D"
cp "$FX/dtn_log.tmds" "$D/dri/0/amdgpu_dm_dtn_log"
echo "quiet splash" > "$D/cmdline"
RC=0
OUT=$(STUB_DIR=$D STUB_MODETEST=$M120 HDMI_FRL_TEST_CMDLINE=$D/cmdline HDMI_FRL_TEST_SYSFS=$D/sys \
	HDMI_FRL_TEST_DEBUGFS=$D/dri PATH="$T/bin:$PATH" bash "$SCRIPT" 2>&1) || RC=$?
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
