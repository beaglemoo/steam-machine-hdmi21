# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - unreleased

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
