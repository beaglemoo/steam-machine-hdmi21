# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Deprecated

- Valve's kernel 7.2.10-valve1 (SteamOS Preview Candidate build 20261106.100)
  has native HDMI 2.1 FRL and VRR support. This package is not needed there
  and cannot build against it.
- Uninstall before switching to Preview Candidate, or before the update
  reaches Stable (`setup.sh uninstall`, then reboot). See the notice at the top
  of the README.
- Stable and Preview users on SteamOS 3.9.5 (kernel 7.2.7) can keep using this
  package.
- The repository will be archived once 7.2.10 reaches Stable. The install and
  uninstall one-liner will keep working.

## [1.1.0] - 2026-11-07

### Added

- `setup.sh status --json` prints the whole state (build, mode, module,
  display, VRR, units, rebuild progress, reboot reasons) as one JSON object for
  tools such as a Decky plugin. Plain `status` is unchanged.
- The JSON reports the live signal: link state and the rule that decided it,
  pixel format (RGB or YCbCr and chroma), bits per colour, HDR and its transfer
  function, and the HDMI content type. Fields the driver does not expose read
  as null rather than a guess.
- HDMI ALLM (Auto Low Latency Mode) is on by default. Patch 0003 adds the
  module parameter `amdgpu.hdmi_allm_default` (0 disabled, 1 dynamic, 2 always
  on) and applies it whenever the display output is set up, because gamescope
  never sets ALLM itself. `setup.sh allm disabled|dynamic|always-on|default`
  changes it for the next boot. The patch is optional: if it stops applying on
  a future kernel the build continues without it.
- A debugfs file, `crtc-N/amdgpu_current_hdmi`, reads back whether ALLM is
  being sent and which content type the stream carries.

### Changed

- `status --json` classifies the link with the 1.0.1 rules instead of a pixel
  clock threshold, so 120 Hz TVs on FRL report correctly.
- Upgrading from 1.0.x rebuilds the module once, because the patch set changed.

## [1.0.1] - 2026-10-23

### Fixed

- `hdmi-frl-resume.sh` no longer judges the link by the highest mode pixel
  clock alone. On a TV that tops out at 120 Hz (an LG C9) 4K120 is 1188000 kHz
  over FRL and over TMDS 4:2:0 alike, so the 1.0.0 check could never see FRL:
  every resume forced five `trigger_hotplug` cycles, each blanking the screen,
  and then failed the unit while FRL was running fine. The link is now classified
  by rule, first match wins: an `HPO:` row in `amdgpu_dm_dtn_log` (the driver
  prints it only while an HDMI FRL stream encoder is active) is `frl`; a
  connector mode above 1200000 kHz is `frl`; a complete dump with no HPO row
  while the CRTC runs a mode above 600000 kHz is `tmds` (FRL lost); anything else
  is `unknown`, which does nothing and exits 0. A 120 Hz TV running 4K60 or lower
  is therefore left alone, and a 144 Hz TV keeps the 1.0.0 behaviour.
- After a resume the link is polled for up to 20 s before anything is decided,
  so a TV that is still waking, or patch 0002 retraining FRL by itself, no
  longer triggers a re-detect.
- The synthetic `change` uevent is now emitted after every re-detect cycle,
  before the link state is read again. 1.0.0 only sent it once the modes were
  back, but the compositor needs it to re-read the connector.
- `--check` prints the link state, the rule that decided it, its inputs and the
  `HPO` row.
- `setup.sh install` over an existing copy install no longer downloads and
  builds the module again when `out/` already holds one for the running kernel
  that was built from the same patches. `build.sh` stamps each module with the
  hash of its patch set; `HDMI21_REBUILD=1` forces a rebuild.

### Added

- `tests/frl-detect.sh`: fixture dtn_log and modetest output for every link
  rule, the resume script against a fake debugfs tree, and the module reuse
  rule.

## [1.0.0] - 2026-10-18

### Added

- Patch 0001: FreeSync/VRR capability detection for HDMI FRL sinks.
- Patch 0002: verify the link capability destructively on hotplug, so FRL
  survives a TV re-handshake, an input switch and a resume.
- `build.sh`, `install.sh` and `uninstall.sh` to build, install and remove the
  patched `amdgpu` module for the running kernel.
- `hdmi-mode.sh` to switch between FRL and TMDS and report the state.
- Boot self-heal: `hdmi-frl-grub.service` re-asserts the grub mode and the
  module after a SteamOS update, and rebuilds it when the kernel changed.
- Resume self-heal: `hdmi-frl-resume.service` restores the FRL modes after
  suspend.
- `setup.sh`: one-step `install`, `uninstall` and `status`, with preflight
  checks, a log and an offer to reboot.
- `get.sh`: bootstrap that downloads a release and runs `setup.sh`.
- Desktop Mode launchers for installing and uninstalling.
- `VERSION` file.

### Fixed

- `build.sh` now installs `base-devel`; the stock SteamOS image has no `gcc` or
  `make`.
- The tag lookup no longer fails on a source repository owned by another user
  (git's dubious ownership check), and git errors are no longer hidden.
- `steamos-readonly` is re-enabled when `pacman-key` or `pacman` fails.
- `setup-selfheal.sh --remove` succeeds when the units are already missing.
- Build output is handed back to the owner of the checkout instead of being
  left root-owned, and concurrent builds are serialised.
