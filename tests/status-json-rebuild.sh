#!/usr/bin/env bash
# Checks rebuild.state and rebuild.last_line of `setup.sh status --json` against
# stubbed systemctl and journalctl. The stub journal returns systemd's own
# messages about a unit ("Deactivated successfully.") for -u, as the real one
# does, and only the unit's processes for a _SYSTEMD_UNIT= match.
#
#   bash tests/status-json-rebuild.sh
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SETUP=$HERE/../setup.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/journal"

cat > "$T/bin/journalctl" <<'STUB'
#!/bin/sh
unit="" own=0
while [ $# -gt 0 ]; do
	case "$1" in
		-u) unit=$2; own=0; shift 2 ;;
		_SYSTEMD_UNIT=*) unit=${1#_SYSTEMD_UNIT=}; unit=${unit%.service}; own=1; shift ;;
		*) shift ;;
	esac
done
if [ -z "$unit" ]; then echo "some boot line"; exit 0; fi
[ -f "$STUB_DIR/journal/$unit" ] && cat "$STUB_DIR/journal/$unit"
if [ "$own" = 0 ] && [ -f "$STUB_DIR/journal/$unit" ]; then
	echo "$unit.service: Deactivated successfully."
	echo "$unit.service: Failed with result 'exit-code'."
fi
exit 0
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
for a; do u=$a; done
if [ "$u" = "$STUB_UNIT" ]; then
	printf 'LoadState=loaded\nUnitFileState=\nActiveState=%s\nSubState=x\nResult=success\n' "$STUB_ACTIVE"
else
	printf 'LoadState=not-found\nUnitFileState=\nActiveState=inactive\nSubState=dead\nResult=success\n'
fi
STUB
chmod +x "$T/bin/journalctl" "$T/bin/systemctl"

fail=0
check() { # name, active, journal text, want state, want last_line
	local name=$1 active=$2 text=$3 want_state=$4 want_line=$5 got
	printf '%s\n' "$text" > "$T/journal/hdmi21-test"
	got=$(STUB_DIR=$T STUB_UNIT=hdmi21-test STUB_ACTIVE=$active HDMI21_REBUILD_UNIT=hdmi21-test \
		PATH="$T/bin:$PATH" bash "$SETUP" status --json --dir "$T" \
		| python3 -I -c 'import json,sys; r=json.load(sys.stdin)["rebuild"]; print(r["state"]); print(r["last_line"])')
	if [ "$got" = "$want_state
$want_line" ]; then
		echo "ok   $name"
	else
		echo "FAIL $name: got [$got], want [$want_state / $want_line]"
		fail=1
	fi
}

check "failed: last line is the script's, not systemd's" inactive \
'hdmi-frl: rebuilding the patched amdgpu module for 7.0.1
[build 09:59:40] done kernel config
hdmi-frl: ERROR build.sh failed' \
	failed 'hdmi-frl: ERROR build.sh failed'

check "complete without a module installed is failed" inactive \
'hdmi-frl: rebuilding the patched amdgpu module for 7.0.1
hdmi-frl: rebuild complete, reboot to load the patched module' \
	failed 'hdmi-frl: rebuild complete, reboot to load the patched module'

check "running: build progress lines are eligible" active \
'hdmi-frl: rebuilding the patched amdgpu module for 7.0.1
[build 09:59:40] done kernel config' \
	running '[build 09:59:40] done kernel config'

check "interrupted rebuild" inactive \
'hdmi-frl: rebuilding the patched amdgpu module for 7.0.1
[build 09:59:40] done kernel config' \
	failed '[build 09:59:40] done kernel config'

exit "$fail"
