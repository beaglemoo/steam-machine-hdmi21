#!/usr/bin/env bash
# Checks the ALLM setting: setup.sh allm argument validation, the drop-in and
# marker hdmi-allm.sh writes (into a temp directory, with a stub update-grub),
# and the self-heal block that recreates the drop-in from the marker. Needs no
# root and does not touch /etc.
#
#   bash tests/allm-config.sh
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SETUP=$HERE/../setup.sh
ALLM=$HERE/../hdmi-allm.sh
SELFHEAL=$HERE/../selfheal/hdmi-frl-selfheal.sh
FX=$HERE/fixtures
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/update-grub" <<'STUB'
#!/bin/sh
echo run >> "$STUB_DIR/grub"
STUB
chmod +x "$T/bin/update-grub"

fail=0
pass=0
ok() { pass=$((pass + 1)); printf 'ok      %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAILED  %s\n' "$1"; }
expect() { # name, want, got
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi
}

# --- setup.sh allm: arguments --------------------------------------------
# Validation happens before anything needs root or SteamOS.
rc_of() { local rc=0; bash "$SETUP" "$@" > /dev/null 2>&1 || rc=$?; echo "$rc"; }
expect "allm bogus exits 2" 2 "$(rc_of allm bogus)"
expect "allm with no mode exits 2" 2 "$(rc_of allm)"
expect "allm with an option and no mode exits 2" 2 "$(rc_of allm --yes)"
expect "allm with two modes exits 2" 2 "$(rc_of allm dynamic disabled)"
expect "a mode with no command exits 2" 2 "$(rc_of dynamic)"
expect "allm always_on (underscore) exits 2" 2 "$(rc_of allm always_on)"
expect "install with an ALLM mode exits 2" 2 "$(rc_of install dynamic)"
expect "--json with allm exits 2" 2 "$(rc_of allm dynamic --json)"
expect "allm --help exits 0" 0 "$(rc_of allm --help)"
expect "usage mentions allm" 1 "$(bash "$SETUP" --help | grep -c 'setup.sh allm disabled|dynamic|always-on|default')"

# --- hdmi-allm.sh ---------------------------------------------------------
G=$T/grub.d
S=$T/state
mkdir -p "$S"
allm_sh() { # args... ; sets OUT and RC
	RC=0
	OUT=$(STUB_DIR=$T HDMI_ALLM_TEST_GRUBD=$G STATE_DIR=$S PATH="$T/bin:$PATH" sh "$ALLM" "$@" 2>&1) || RC=$?
}
grub_runs() { wc -l < "$T/grub" 2>/dev/null | tr -d ' ' || echo 0; }
: > "$T/grub"

expect "render 1 is the dynamic fixture" "$(cat "$FX/grubd/dynamic/hdmi21-allm.cfg")" "$(sh "$ALLM" render 1)"
expect "render 2 is the always-on fixture" "$(cat "$FX/grubd/always-on/hdmi21-allm.cfg")" "$(sh "$ALLM" render 2)"

allm_sh always-on
expect "always-on: exit 0" 0 "$RC"
expect "always-on: drop-in is the fixture" "$(cat "$FX/grubd/always-on/hdmi21-allm.cfg")" "$(cat "$G/hdmi21-allm.cfg")"
expect "always-on: marker holds 2" 2 "$(cat "$S/.hdmi21-allm")"
expect "always-on: grub regenerated once" 1 "$(grub_runs)"

allm_sh dynamic
expect "dynamic: drop-in replaced" "$(cat "$FX/grubd/dynamic/hdmi21-allm.cfg")" "$(cat "$G/hdmi21-allm.cfg")"
expect "dynamic: marker holds 1" 1 "$(cat "$S/.hdmi21-allm")"
expect "dynamic: exactly one amdgpu.hdmi_allm_default" 1 "$(grep -c 'amdgpu.hdmi_allm_default=' "$G/hdmi21-allm.cfg")"

allm_sh disabled
expect "disabled: marker holds 0" 0 "$(cat "$S/.hdmi21-allm")"
expect "disabled: drop-in says 0" 1 "$(grep -c 'amdgpu.hdmi_allm_default=0"' "$G/hdmi21-allm.cfg")"
# shellcheck disable=SC2016 # the literal text of the drop-in, not an expansion
expect "disabled: the drop-in only appends to the cmdline" 1 \
	"$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} ' "$G/hdmi21-allm.cfg")"

allm_sh status
case "$OUT" in *"allm configured: disabled (next boot)"*) ok "status shows the configured value" ;; *) bad "status shows the configured value ($OUT)" ;; esac

# restore: the self-heal path
rm -f "$G/hdmi21-allm.cfg"
allm_sh restore
expect "restore: exit 0" 0 "$RC"
expect "restore: drop-in rebuilt from the marker" 1 "$(grep -c 'amdgpu.hdmi_allm_default=0"' "$G/hdmi21-allm.cfg")"
echo 9 > "$S/.hdmi21-allm"; rm -f "$G/hdmi21-allm.cfg"
allm_sh restore
expect "restore: a bad marker exits 1" 1 "$RC"
expect "restore: a bad marker writes no drop-in" no "$([ -e "$G/hdmi21-allm.cfg" ] && echo yes || echo no)"

allm_sh dynamic
allm_sh default
expect "default: exit 0" 0 "$RC"
expect "default: drop-in removed" no "$([ -e "$G/hdmi21-allm.cfg" ] && echo yes || echo no)"
expect "default: marker removed" no "$([ -e "$S/.hdmi21-allm" ] && echo yes || echo no)"
allm_sh default
expect "default again is harmless" 0 "$RC"
allm_sh status
case "$OUT" in *"allm configured: module default"*) ok "status after default" ;; *) bad "status after default ($OUT)" ;; esac
allm_sh bogus
expect "hdmi-allm.sh bogus exits 2" 2 "$RC"

# --- self-heal block ------------------------------------------------------
# The ALLM section of hdmi-frl-selfheal.sh runs at the top level of the script
# (the rest needs root, update-grub and a kernel), so cut it out and run it
# with the paths pointed at the temp tree.
sed -n '/^# --- ALLM drop-in/,/^# --- marker/p' "$SELFHEAL" | sed '$d' > "$T/heal.sh"
expect "the self-heal ALLM block was found" 1 "$([ -s "$T/heal.sh" ] && echo 1 || echo 0)"
heal() { # sets OUT
	OUT=$(STUB_DIR=$T HDMI_ALLM_TEST_GRUBD=$G PATH="$T/bin:$PATH" REPO_DIR=$HERE/.. STATE_DIR=$S \
		ALLM_MARKER=$S/.hdmi21-allm ALLM_DROPIN=$G/hdmi21-allm.cfg \
		bash -c 'log() { echo "hdmi-frl: $*"; }; . "$1"' _ "$T/heal.sh" 2>&1)
}
rm -rf "$G"; rm -f "$S/.hdmi21-allm"
heal
expect "self-heal: no marker, no drop-in, nothing to do" "" "$OUT"
echo 1 > "$S/.hdmi21-allm"
heal
case "$OUT" in *"recreated from the marker"*) ok "self-heal: marker without drop-in recreates it" ;; *) bad "self-heal: recreate ($OUT)" ;; esac
expect "self-heal: the recreated drop-in is the fixture" "$(cat "$FX/grubd/dynamic/hdmi21-allm.cfg")" "$(cat "$G/hdmi21-allm.cfg")"
before=$(grub_runs)
heal
expect "self-heal: marker and drop-in present, nothing to do" "" "$OUT"
expect "self-heal: grub not touched then" "$before" "$(grub_runs)"
rm -f "$S/.hdmi21-allm"
heal
case "$OUT" in *"removed stale grub drop-in"*) ok "self-heal: drop-in without a marker is removed" ;; *) bad "self-heal: stale ($OUT)" ;; esac
expect "self-heal: stale drop-in is gone" no "$([ -e "$G/hdmi21-allm.cfg" ] && echo yes || echo no)"

# The keep list carries the drop-in.
expect "atomic-update keep list has the ALLM drop-in" 1 \
	"$(grep -c '^/etc/default/grub.d/hdmi21-allm.cfg$' "$HERE/../selfheal/atomic-update-keep.conf")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
