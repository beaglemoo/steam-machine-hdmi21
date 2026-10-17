#!/usr/bin/env bash
# Bootstrap for setup.sh: downloads a release of steam-machine-hdmi21 to a
# temporary directory and runs its setup.sh. Meant for
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/beaglemoo/steam-machine-hdmi21/main/get.sh) \
#        [install|uninstall|status] [--ref REF] [setup.sh flags...]
#
# The default command is install and the default ref is the latest GitHub
# release (--ref main gives the development version; HDMI21_REF works too).
# Every other argument is passed to setup.sh. uninstall and status use the
# installed copy and download nothing.
set -euo pipefail

REPO=beaglemoo/steam-machine-hdmi21
UNIT_PATH=/etc/systemd/system/hdmi-frl-grub.service

log() { printf '[get] %s\n' "$*" >&2; }
die() { printf '[get] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

SUB=""
REF=${HDMI21_REF:-}
PASS=()
while [ $# -gt 0 ]; do
	case "$1" in
		install|uninstall|status)
			if [ -z "$SUB" ] && [ ${#PASS[@]} -eq 0 ]; then SUB=$1; else PASS+=("$1"); fi
			shift ;;
		--ref)
			[ $# -ge 2 ] || { printf '[get] --ref needs a value (see --help)\n' >&2; exit 2; }
			REF=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) PASS+=("$1"); shift ;;
	esac
done
SUB=${SUB:-install}

if [ "$(id -u)" = 0 ]; then
	printf '[get] run as deck without sudo; setup.sh asks for your password itself\n' >&2
	exit 3
fi

# uninstall and status act on what is installed, so use that copy as it is.
if [ "$SUB" != install ]; then
	dir=$(sed -n 's/^Environment=HDMI_FRL_REPO=//p' "$UNIT_PATH" 2>/dev/null | head -1 || true)
	if [ -z "$dir" ] || [ ! -f "$dir/setup.sh" ]; then dir=$HOME/steam-machine-hdmi21; fi
	if [ -f "$dir/setup.sh" ]; then
		exec bash "$dir/setup.sh" "$SUB" ${PASS[@]+"${PASS[@]}"}
	fi
fi

if [ -z "$REF" ]; then
	url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
		|| die "cannot reach github.com to find the latest release"
	case "$url" in
		*/releases/tag/*) REF=${url##*/} ;;
		*) die "no release published yet; pass --ref main for the development version" ;;
	esac
fi
log "using ref $REF"

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xzf - --strip-components=1 -C "$tmp" \
	|| die "could not download or extract $REF from $REPO"
[ -f "$tmp/setup.sh" ] || die "$REF has no setup.sh; it predates the one-step installer"
[ -f "$tmp/VERSION" ] || die "$REF has no VERSION file"
log "version $(cat "$tmp/VERSION")"

# A child, not exec: the temporary directory has to be removed afterwards.
rc=0
bash "$tmp/setup.sh" "$SUB" ${PASS[@]+"${PASS[@]}"} || rc=$?
cleanup
trap - EXIT
exit "$rc"
