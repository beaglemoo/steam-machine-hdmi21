# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.1] - 2026-10-23

### Fixed

- `hdmi-frl-resume.sh` no longer judges the link by the highest mode pixel
  clock. On a TV that tops out at 120 Hz (an LG C9) 4K120 is 1188000 kHz over
  FRL and over TMDS 4:2:0 alike, so the 1.0.0 check could never see FRL: every
  resume forced five `trigger_hotplug` cycles, each blanking the screen, and
  then failed the unit while FRL was running fine. It now reads the `HPO:` table
  of `amdgpu_dm_dtn_log`, which the driver prints only while an HDMI FRL stream
  encoder is active, and reports `frl`, `tmds` or `unknown`.
- After a resume the link is polled for up to 20 s before anything is decided,
  so a TV that is still waking, or patch 0002 retraining FRL by itself, no
  longer triggers a re-detect. Only a link that is still `tmds` after that is
  re-detected, re-checking after each cycle. `unknown` does nothing and exits 0.
- `--check` prints the link state and the `HPO` row.
- `setup.sh install` over an existing copy install no longer downloads and
  builds the module again when `out/` already holds one for the running kernel
  that was built from the same patches. `build.sh` stamps each module with the
  hash of its patch set; `HDMI21_REBUILD=1` forces a rebuild.

### Added

- `tests/frl-detect.sh`: fixture dumps for the three link states, the resume
  script against a fake debugfs tree, and the module reuse rule.

### Removed

- The `TMDS_MAX_KHZ` mode clock discriminator and the `modetest` dependency of
  the resume script. The `modetest` warning in `setup.sh` now only concerns
  `status`.

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
