#!/usr/bin/env bash
# Build a patched amdgpu.ko.zst for the running SteamOS kernel so that HDMI 2.1
# FRL sinks get FreeSync/VRR. Unattended and idempotent: safe to re-run, safe to
# run from a systemd unit at boot.
#
#   ./build.sh [--src-tarball PATH] [--jobs N] [--cache-dir DIR]
#              [--work-dir DIR] [--out-dir DIR]
#
# Produces out/amdgpu-<uname -r>.ko.zst and out/amdgpu-<uname -r>.ko.zst.vermagic
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PATCH="$REPO_DIR/patches/0001-amdgpu-dm-frl-vrr-freesync-caps.patch"

CACHE_DIR=${CACHE_DIR:-/home/deck/.cache/steam-machine-hdmi21}
WORK_DIR=${WORK_DIR:-$REPO_DIR/work}
OUT_DIR=${OUT_DIR:-$REPO_DIR/out}
SRC_TARBALL=${SRC_TARBALL:-}
JOBS=${JOBS:-$(nproc)}

MIRROR_BASE=https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources
MIRROR_REPOS="jupiter-main jupiter-3.9"

log() { printf '[build %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[build %s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--src-tarball) SRC_TARBALL=${2:?--src-tarball needs a path}; shift 2 ;;
		--jobs) JOBS=${2:?--jobs needs a number}; shift 2 ;;
		--cache-dir) CACHE_DIR=${2:?--cache-dir needs a path}; shift 2 ;;
		--work-dir) WORK_DIR=${2:?--work-dir needs a path}; shift 2 ;;
		--out-dir) OUT_DIR=${2:?--out-dir needs a path}; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (see --help)" ;;
	esac
done

as_root() {
	if [ "$(id -u)" = 0 ]; then "$@"
	elif sudo -n true 2>/dev/null; then sudo -n "$@"
	else die "need root for: $*  (run build.sh as root, or pre-install ${KPKG}-headers)"
	fi
}

# --- running kernel ------------------------------------------------------
KREL=$(uname -r)
case "$KREL" in
	*-g*) KHASH=${KREL##*-g} ;;
	*) die "kernel release '$KREL' has no -g<hash> suffix, cannot match a Valve tag" ;;
esac
NEPTUNE=$(printf '%s\n' "$KREL" | grep -o 'neptune-[0-9]\+' | head -1)
[ -n "$NEPTUNE" ] || die "kernel release '$KREL' is not a linux-neptune kernel"
KPKG="linux-$NEPTUNE"
BUILD_TREE="/lib/modules/$KREL/build"

log "kernel        $KREL"
log "kernel commit $KHASH"
log "kernel package $KPKG"
log "jobs          $JOBS"

# --- kernel headers ------------------------------------------------------
ensure_headers() {
	[ -d "$BUILD_TREE" ] && { log "headers       $BUILD_TREE (present)"; return 0; }
	log "headers       missing, installing $KPKG-headers"
	as_root steamos-readonly disable
	if [ ! -d /etc/pacman.d/gnupg ]; then
		log "initialising pacman keyring"
		as_root pacman-key --init
		as_root pacman-key --populate archlinux holo
	fi
	as_root pacman -Sy --needed --noconfirm "$KPKG-headers" || {
		as_root steamos-readonly enable
		die "pacman could not install $KPKG-headers"
	}
	as_root steamos-readonly enable
	[ -d "$BUILD_TREE" ] || die "$KPKG-headers installed but $BUILD_TREE still missing"
}
ensure_headers

if command -v pacman >/dev/null 2>&1; then
	kver=$(pacman -Q "$KPKG" 2>/dev/null | awk '{print $2}')
	hver=$(pacman -Q "$KPKG-headers" 2>/dev/null | awk '{print $2}')
	if [ -n "$kver" ] && [ -n "$hver" ] && [ "$kver" != "$hver" ]; then
		log "WARNING $KPKG is $kver but $KPKG-headers is $hver"
	fi
fi

# --- source tarball ------------------------------------------------------
mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUT_DIR"

# tar -tzf piped into an early-quitting sed makes tar die on SIGPIPE; contain
# that inside a subshell with pipefail off.
list_head() { ( set +o pipefail; tar -tzf "$1" | sed -n '1,400p;400q' ); }

remote_newest() {
	local repo url name
	for repo in $MIRROR_REPOS; do
		url="$MIRROR_BASE/$repo/"
		name=$(curl -fsSL --max-time 60 "$url" \
			| grep -o "$KPKG-[0-9][^\"<]*\.src\.tar\.gz" \
			| grep -v -- "-devel-" | sort -u | sort -V | tail -1) || true
		if [ -n "$name" ]; then printf '%s%s\n' "$url" "$name"; return 0; fi
	done
	return 1
}

download_newest() {
	local url name dest
	url=$(remote_newest) || die "no $KPKG source tarball found on the mirror"
	name=${url##*/}
	dest="$CACHE_DIR/$name"
	if [ -s "$dest" ]; then log "tarball       $dest (cached)"; printf '%s\n' "$dest"; return 0; fi
	log "downloading   $url"
	curl -fL --retry 3 --continue-at - -o "$dest.part" "$url" || die "download failed: $url"
	mv -f "$dest.part" "$dest"
	log "downloaded    $dest ($(stat -c %s "$dest") bytes)"
	printf '%s\n' "$dest"
}

# Extract only the bare git repository out of a source tarball. Returns its path.
extract_repo() {
	local tarball=$1 stem dest member listing
	stem=$(basename "$tarball" .src.tar.gz)
	dest="$CACHE_DIR/extract/$stem"
	if [ -f "$dest/.bare-repo" ]; then
		local cached; cached=$(cat "$dest/.bare-repo")
		[ -d "$cached" ] && { printf '%s\n' "$cached"; return 0; }
	fi
	listing=$(list_head "$tarball") || die "cannot read $tarball"
	member=$(printf '%s\n' "$listing" | grep -m1 -E '^[^/]+/[^/]+/HEAD$' || true)
	[ -n "$member" ] || die "no bare git repository found in $tarball"
	member=${member%/HEAD}
	log "extracting    $member from $(basename "$tarball") (this takes a few minutes)"
	rm -rf "$dest"
	mkdir -p "$dest"
	tar -xzf "$tarball" -C "$dest" "$member"
	[ -d "$dest/$member" ] || die "extraction of $member failed"
	printf '%s\n' "$dest/$member" > "$dest/.bare-repo"
	log "extracted     $dest/$member"
	printf '%s\n' "$dest/$member"
}

# Resolve the tag in a bare repo whose commit matches the running kernel.
resolve_tag() {
	local bare=$1 tag
	tag=$(git -C "$bare" tag --points-at "$KHASH" 2>/dev/null | head -1 || true)
	if [ -z "$tag" ]; then
		# Fall back to the pacman-version-to-tag rule: 7.2.0.valve1 -> 7.2.0-valve1
		local pkgver guess
		pkgver=$(pacman -Q "$KPKG" 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//') || true
		guess=$(printf '%s\n' "$pkgver" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)\.(.*)$/\1-\2/; s/(-.*)\./\1-/g')
		if [ -n "$guess" ] && git -C "$bare" rev-parse -q --verify "$guess^{commit}" >/dev/null 2>&1; then
			tag=$guess
		fi
	fi
	[ -n "$tag" ] || return 1
	local got
	got=$(git -C "$bare" rev-parse --short="${#KHASH}" "$tag^{commit}")
	[ "$got" = "$KHASH" ] || return 1
	printf '%s\n' "$tag"
}

BARE=""; TAG=""
try_tarball() {
	local tarball=$1 bare tag
	[ -s "$tarball" ] || return 1
	bare=$(extract_repo "$tarball") || return 1
	tag=$(resolve_tag "$bare") || {
		log "              $(basename "$tarball") has no tag for $KHASH, trying the next source"
		return 1
	}
	BARE=$bare; TAG=$tag; return 0
}

if [ -n "$SRC_TARBALL" ]; then
	[ -s "$SRC_TARBALL" ] || die "--src-tarball $SRC_TARBALL does not exist"
	try_tarball "$SRC_TARBALL" || die "$SRC_TARBALL does not contain the tag for $KHASH"
else
	mapfile -t cached_list < <(printf '%s\n' "$CACHE_DIR"/"$KPKG"-[0-9]*.src.tar.gz \
		| grep -v -- '-devel-' | sort -V -r)
	for cached in "${cached_list[@]}"; do
		try_tarball "$cached" && break
	done
	if [ -z "$BARE" ]; then
		tb=$(download_newest)
		try_tarball "$tb" || die "$tb does not contain the tag for $KHASH"
	fi
fi

log "source repo   $BARE"
log "tag           $TAG ($KHASH)"

# --- patched checkout ----------------------------------------------------
SRC="$WORK_DIR/src"
TAG_COMMIT=$(git -C "$BARE" rev-parse "$TAG^{commit}")

reusable_src() {
	[ -d "$SRC/.git" ] || return 1
	git -C "$SRC" merge-base --is-ancestor "$TAG_COMMIT" HEAD 2>/dev/null || return 1
	grep -q 'dc_is_hdmi_signal(sink->sink_signal)' \
		"$SRC/drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c" 2>/dev/null || return 1
}

if reusable_src; then
	log "checkout      $SRC (existing, already patched)"
else
	log "checkout      cloning $TAG into $SRC"
	rm -rf "$SRC"
	git clone --shared --quiet --branch "$TAG" "$BARE" "$SRC"
	got=$(git -C "$SRC" rev-parse --short="${#KHASH}" HEAD)
	[ "$got" = "$KHASH" ] || die "checkout is at $got but the running kernel is $KHASH"
	log "applying      $(basename "$PATCH")"
	git -C "$SRC" -c user.name='steam-machine-hdmi21' \
		-c user.email='hdmi21@localhost' am "$PATCH"
	grep -q 'dc_is_hdmi_signal(sink->sink_signal)' \
		"$SRC/drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c" \
		|| die "patch applied but the expected line is not in amdgpu_dm.c"
fi

# --- build ---------------------------------------------------------------
# Out-of-tree only: SteamOS has no glibc headers, so the kernel host tools
# cannot be compiled and an in-tree build is impossible. The installed headers
# package ships those host tools prebuilt.
# CFLAGS_amdgpu_trace_points.o is needed because amdgpu_trace.h sets
# TRACE_INCLUDE_PATH relative to include/trace/define_trace.h, which resolves
# inside the headers tree where the driver sources do not exist.
MDIR="$SRC/drivers/gpu/drm/amd/amdgpu"
log "building      amdgpu against $BUILD_TREE"
start=$(date +%s)
make -C "$BUILD_TREE" M="$MDIR" -j"$JOBS" \
	"CFLAGS_amdgpu_trace_points.o=-I$SRC/include/trace" \
	modules
log "built         in $(( $(date +%s) - start ))s"
[ -f "$MDIR/amdgpu.ko" ] || die "make finished but $MDIR/amdgpu.ko is missing"

KO="$OUT_DIR/amdgpu-$KREL.ko"
ZST="$KO.zst"
install -m644 "$MDIR/amdgpu.ko" "$KO"
strip --strip-debug "$KO"
log "stripped      $(stat -c %s "$KO") bytes"
zstd -19 -T0 -q -f -o "$ZST" "$KO"
rm -f "$KO"
log "compressed    $ZST ($(stat -c %s "$ZST") bytes)"

VERMAGIC=$(modinfo -F vermagic "$ZST")
[ "${VERMAGIC%% *}" = "$KREL" ] \
	|| die "vermagic '$VERMAGIC' does not match the running kernel $KREL"
printf '%s\n' "$VERMAGIC" > "$ZST.vermagic"
log "vermagic      $VERMAGIC"
log "done          $ZST"
