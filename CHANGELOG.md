# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
