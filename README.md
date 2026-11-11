# steam-machine-hdmi21

> **Notice: native HDMI 2.1 is coming to SteamOS.** Valve's kernel
> 7.2.10-valve1, currently in the SteamOS Preview Candidate channel (build
> 20261106.100), has native HDMI 2.1 support. FRL is on by default, VRR works
> over FRL, FRL survives a TV wake or input switch, and the kernel sends ALLM
> while VRR is active.
>
> This package is not needed on that kernel and cannot build there, because its
> patches no longer apply. Before switching to Preview Candidate, or before
> applying that update once it reaches Stable, uninstall and reboot:
>
> ```
> bash <(curl -fsSL https://raw.githubusercontent.com/beaglemoo/steam-machine-hdmi21/main/get.sh) uninstall
> ```
>
> Already updated? Run the same uninstall. Nothing breaks in the meantime: FRL
> works natively, the self-heal rebuild fails harmlessly at each boot, and the
> ALLM setting is ignored. On the native kernel ALLM is only sent while VRR is
> active and is not configurable.
>
> Stable and Preview users on SteamOS 3.9.5 (kernel 7.2.7) can keep using this
> package. The repository will be archived once 7.2.10 reaches Stable; the
> install and uninstall one-liner will keep working.

HDMI 2.1 FRL with working VRR on the Valve Steam Machine, on SteamOS kernel 7.2
(`linux-neptune-72`) up to 7.2.7. Kernel 7.2.10 and later have this natively.

Out of the box the Steam Machine drives an HDMI 2.1 display over TMDS, which
caps it at 4K120 4:2:0 8-bit. Booting with `amdgpu.dcfeaturemask=0x402` turns on
the DC FRL code path and gets the full HDMI 2.1 link: 4K144, 10-bit, 4:4:4, HDR.
What you lose in exchange is VRR, because the display driver stops recognising
the sink as HDMI once it is running FRL, and the FRL link itself, which is
dropped for TMDS on the first hotplug after boot. This repository contains the
two kernel patches that fix both, a build script that produces a patched
`amdgpu` module for the exact kernel you are running, a one-step installer, and
the glue that keeps it all working across SteamOS updates.

## Disclaimer

This is an unofficial community project. It is not affiliated with or endorsed
by Valve. It replaces a kernel display module (`amdgpu`) on your Steam Machine;
use it at your own risk. It is released under the GPL-2.0 with no warranty. The
stock module is never deleted, and the Recovery section below explains how to go
back.

## Quick install

### Desktop Mode

Open Konsole from the application launcher and paste:

```
bash <(curl -fsSL https://raw.githubusercontent.com/beaglemoo/steam-machine-hdmi21/main/get.sh)
```

That downloads the latest release and runs the installer. Add `--ref main` to
install the development version instead.

Alternatively, download the release from GitHub, extract it in Dolphin and
double-click "Install HDMI 2.1 FRL". KDE asks whether to trust the launcher;
accept. If you would rather use a terminal, run
`bash ~/Downloads/<extracted folder>/setup.sh install`.

### SSH

Run the same one-liner in an SSH session. Add `--yes` to take every default;
that includes the final reboot, which drops your session:

```
bash <(curl -fsSL https://raw.githubusercontent.com/beaglemoo/steam-machine-hdmi21/main/get.sh) install --yes
```

### That is the whole install

The installer does everything: it builds the module with both patches (VRR and
the hotplug fix, patch 0002), installs it, sets up the self-heal and switches
grub to FRL. There is nothing else to run afterwards. The rest of this README
explains how the fix works and how to do each step by hand; you do not need any
of it for a normal install. In particular, do not run `setup-selfheal.sh` or the
other scripts yourself after `setup.sh install`; it has already run them.

## Requirements

- A Steam Machine on SteamOS 3.9 with kernel `linux-neptune-72`, 7.2.0 to 7.2.7
  (7.2.10 and later need nothing from this package). The
  installer refuses older kernels, and asks for `HDMI21_ALLOW_UNTESTED_KERNEL=1`
  on a major version above 7.
- A sudo password for the `deck` user. Set one in Konsole with `passwd` if you
  never have; the installer stops and tells you if none is set.
- SSH enabled beforehand as a recovery path: `sudo systemctl enable --now sshd`.
- About 12 GB free in `/home` (about 4 GB once the source cache exists): the
  source cache takes about 7 GB (the 3.4 GB Valve kernel tarball plus its
  extracted git repository) and the patched kernel checkout about 4 GB.
- A network connection to the SteamOS package mirror.
- Secure Boot off (the default), because the module is unsigned.

## What it does

`setup.sh install` runs five steps and logs everything to
`~/steam-machine-hdmi21-setup.log`:

1. Builds a patched `amdgpu` module for the running kernel (`build.sh`). This
   installs the kernel headers and `base-devel` if they are missing, downloads
   the Valve source, applies the patches (the third, ALLM, is optional: if it
   does not apply to a newer kernel it is skipped with a warning) and compiles. The first run takes a
   while: the download is 3.4 GB, extracting it takes a few minutes and the
   build 2-4 minutes.
2. Installs the module as an override in `/lib/modules/<kernel>/updates/`
   (`install.sh`); the stock module is not touched.
3. Installs the self-heal units (`setup-selfheal.sh`).
4. Switches grub to the FRL mode (`hdmi-mode.sh frl`).
5. Verifies the result and offers a reboot.

The project is copied to `~/steam-machine-hdmi21`, which is where the self-heal
units run it from. It survives SteamOS updates (see "Surviving SteamOS
updates"), and after an update that changes the kernel it rebuilds the module by
itself; that needs one extra reboot to load.

After the reboot pick 3840x2160 at 144 Hz and turn on HDR in Steam Settings >
Display.

## Upgrading

Run the one-line install again. It replaces the scripts in
`~/steam-machine-hdmi21` and keeps `out/` and `work/`; when `out/` already holds a
module for the running kernel that was built from the same patches (1.0.1 changes
none), it does not download or build anything again and reinstalls that module.
`--no-reboot` skips the reboot prompt, which is not needed for a scripts-only
upgrade. `HDMI21_REBUILD=1` forces a rebuild.

## Verify

```
bash ~/steam-machine-hdmi21/setup.sh status
```

shows the installed version, the running and configured mode, the units and the
current display mode. The details:

```
cat /proc/cmdline | tr ' ' '\n' | grep dcfeaturemask      # amdgpu.dcfeaturemask=0x402
modinfo -F vermagic amdgpu                                 # matches uname -r
sudo cat /sys/kernel/debug/dri/0/HDMI-A-1/vrr_range        # Min: 40  Max: 144
modetest -M amdgpu -c | grep -A2 vrr_capable               # value: 1
sudo grep -A2 '^HPO:' /sys/kernel/debug/dri/0/amdgpu_dm_dtn_log
```

The last command prints the link state; on a working FRL link it shows the pixel
format and bit depth, for example:

```
HPO:   OTG Inst     Link   Pixel Format   Depth   ODM Segments   Lanes   Borrow   h_active   h_blank
[0]:          0   Training        4:4:4      10              1       4   ACTIVE       3840        160
```

`4:4:4` at depth `10` over `4` lanes is the HDMI 2.1 FRL link. An empty
`vrr_range` means the patched module is not loaded. On the TV, the LG C4 shows
`4K 144Hz` and VRR active in its own signal information panel.

### Status as JSON

```
bash ~/steam-machine-hdmi21/setup.sh status --json [--dir DIR]
```

prints one JSON object (schema 1) on stdout and nothing else, for other tools to
read. It changes nothing, exits 0 whenever it prints the object, and
puts problems it noticed into `warnings`. It reads the install and state
directories from `hdmi-frl-grub.service`, so it gives the same answer run as
root or as `deck`; some fields need root (the VRR range, the link dump, pixel format, bit depth and colorimetry) or the journal. `--json`
with `install` or `uninstall` is a usage error (exit 2). Text is reduced to
printable ASCII. A value that cannot be read is `null` (or `false` for a flag,
or `""` for a unit state).

| Field | Meaning |
| --- | --- |
| `schema`, `version`, `generated_at`, `boot_id`, `as_root` | Schema number, `VERSION`, epoch seconds, `/proc/sys/kernel/random/boot_id`, whether it ran as root |
| `install_dir`, `state_dir` | Unit `HDMI_FRL_REPO` (else `--dir`, else the script's own directory); unit `STATE_DIR` (else `$STATE_DIR`, the sudo user's home, the install dir owner's home, `$HOME`) |
| `installed`, `kernel` | `hdmi-frl-grub.service` exists; `uname -r` |
| `build` | `module`: `out/amdgpu-<kernel>.ko.zst` exists; `vermagic`; `matches_kernel` |
| `mode` | `running` (`FRL` if bit `0x400` is set in the last `amdgpu.dcfeaturemask` on the cmdline), `cmdline_mask`, `configured` (marker file present = `FRL`), `marker`, `dropin` (grub drop-in), `consistent` (marker and drop-in agree) |
| `module` | `installed` override in `updates/`, its `installed_vermagic` and `installed_matches_kernel`, `resolves_to_updates`, `loaded`, `taint_o`, `srcversion_match` (loaded vs installed, `null` if unknown), `installed_after_boot`, and `state`: `patched-loaded`, `installed-needs-reboot` or `stock` |
| `display` | `connector`, `connected`, `current_mode` (`width`, `height`, `refresh_hz`, `name`), `max_pixel_clock_khz`, `frl_modes_present` (a mode above 1,200,000 kHz in the mode list: the capability, not the link in use), `sink_frl` (the EDID advertises "Max Fixed Rate Link"), plus the objects below |
| `display.link` | The link in use, classified with the rules `selfheal/hdmi-frl-resume.sh` uses: `state` (`frl`, `tmds` or `unknown`), `rule` (which rule decided it), `dump` (`hpo`, `nohpo` or `incomplete`: what the `amdgpu_dm_dtn_log` debugfs dump showed, root only), `active_pixel_clock_khz` (the CRTC's mode, `null` when idle). All `null`, with a warning, when the script is missing or fails |
| `display.pixel` | `color_model` (`rgb` or `ycbcr`, from the CRTC colorspace; `null` when it cannot be told), `chroma` (`4:4:4`, `4:2:2` or `4:2:0`) with `chroma_source` (`hpo`: the dump's HPO row, FRL only; `rgb`: RGB implies 4:4:4; `tmds-clock`: a TMDS link above 600 MHz can only carry 4:2:0), `bpc` with `bpc_source` (`hpo` or `crtc`), `colorimetry` (the CRTC colorspace name, for example `BT2020_RGB`). The HPO row and the CRTC debugfs files need root; without them these are `null` and a warning says so. A TMDS link below 600 MHz with YCbCr leaves `chroma` `null` |
| `display.hdr` | `active` (the HDR_OUTPUT_METADATA EOTF is not SDR; `false` for an empty blob) and `eotf` (`sdr`, `hdr_gamma`, `pq`, `hlg`) |
| `display.content_type` | The connector's `content type` property: `no_data`, `graphics`, `photo`, `cinema` or `game`. This is the requested value |
| `display.content_type_sent` | The content type of the live stream, from `crtc-N/amdgpu_current_hdmi` (patched module, root only). The driver prints its own enum (0 no data, 1 graphics, 2 photo, 4 cinema, 8 game), which is mapped to the same names as `content_type`; any other number is `null` with a warning. `null` with no stream |
| `vrr` | `capable` (`vrr_capable` property) and `range` (`min_hz`, `max_hz` from debugfs, root only; `null` when 0 to 0) |
| `allm` | `capable` (`allm_capable` property) and `mode` (`allm_mode` property: `disabled`, `dynamic` or `always_on`); `null` when the property is missing. `active`: ALLM is being signalled on the live stream (`crtc-N/amdgpu_current_hdmi`, patched module, root only). `driver_default`: the value the loaded module runs with (`/sys/module/amdgpu/parameters/hdmi_allm_default`; `null` for a module without patch 0003). `configured`: the value in the grub drop-in `hdmi21-allm.cfg` (`null` when none: the module default applies) |
| `units` | `hdmi-frl-grub`, `hdmi-frl-resume`, `hdmi-frl-rebuild`, each with `load`, `enabled`, `active`, `sub`, `result`; the rebuild unit disappears once it has finished |
| `rebuild` | `state`: `idle`, `running`, `succeeded-needs-reboot` or `failed`, read from this boot's journal; `last_line`, `source_unit`, `log_command` |
| `reboot_needed`, `reboot_reasons`, `reboot_reason` | Reasons are `module_installed_not_loaded`, `rebuild_succeeded`, `mode_configured_differs`, `allm_configured_differs` (the value the next boot will use, the drop-in's or else the module default of always on, differs from the loaded `driver_default`); `reboot_reason` is the same in words |
| `tools` | `modetest`, `edid_decode` present; `journal_readable` |
| `warnings` | Strings; empty when everything could be read |

The rebuild log is `journalctl -b -u hdmi-frl-rebuild -u hdmi-frl-grub`. When the
transient rebuild unit could not be started, the boot unit rebuilds inline and
`source_unit` is `hdmi-frl-grub`.

## ALLM

With patch 0003 the HDMI link signals ALLM (Auto Low Latency Mode, the HDMI 2.1
flag that makes a TV switch to its low-latency game picture mode) by default.
The module parameter `amdgpu.hdmi_allm_default` sets the initial value of the
`allm_mode` connector property: `0` disabled, `1` dynamic (ALLM while VRR is
actively varying or the content type is Game), `2` always on. The default is
`2`, and the bit is in the HDMI Forum infoframe from the first frame of every
stream, on both TMDS and FRL links. Software can still change `allm_mode`
afterwards.

Because it is always on, everything gets ALLM, not just games: Desktop Mode and
video apps too, so the TV stays in its game picture mode. To keep it for games
only, or to turn it off:

```
bash ~/steam-machine-hdmi21/setup.sh allm dynamic      # ALLM while VRR varies or content type is Game
bash ~/steam-machine-hdmi21/setup.sh allm disabled     # never by default
bash ~/steam-machine-hdmi21/setup.sh allm always-on    # explicitly the default
bash ~/steam-machine-hdmi21/setup.sh allm default      # remove the setting, the module default applies
```

Each writes `/etc/default/grub.d/hdmi21-allm.cfg` (and the marker
`~/.hdmi21-allm`), runs `update-grub` and offers a reboot; the self-heal puts the
drop-in back after a SteamOS update, and `setup.sh uninstall` removes it. The
setting is a kernel parameter of the patched module only: the stock module
ignores it, so it does nothing before the module is built and loaded. The TV has
to have ALLM enabled as well (on an LG it is "Instant Game Response"). `setup.sh
status` shows the configured and the running value, and `status --json` reports
them as `allm.configured` and `allm.driver_default`, with the live state in
`allm.active` and `display.content_type_sent`.

## Uninstall

Any of these:

```
bash <(curl -fsSL https://raw.githubusercontent.com/beaglemoo/steam-machine-hdmi21/main/get.sh) uninstall
bash ~/steam-machine-hdmi21/setup.sh uninstall
```

or double-click "Uninstall HDMI 2.1 FRL" from the extracted release folder.

It switches grub back to TMDS, removes the module override and the self-heal
units, and offers to delete the build cache (about 7 GB) and the install
directory. The kernel headers and `base-devel` it installed stay until the next
SteamOS update, and the log stays. Reboot afterwards to load the stock module.

## Recovery

If something goes wrong, over SSH or in a Konsole in Desktop Mode run:

```
bash ~/steam-machine-hdmi21/setup.sh uninstall
```

For a quicker way back to a working display that keeps the module installed but
returns to TMDS (4K120 4:2:0, VRR still works on the stock path):

```
sudo sh ~/steam-machine-hdmi21/hdmi-mode.sh tmds && sudo reboot
```

## Tested on

| Hardware | Display | Kernel |
| --- | --- | --- |
| Steam Machine "Fremont" | LG C4 83" | 7.2.4-valve1 |
| Steam Machine "Fremont" | LG C4 83" | 7.2.7-valve1 |
| Steam Machine "Fremont" | LG C4 83" | 7.2.7-valve2 |
| Steam Machine "Fremont" | LG C4 83" | 7.2.7-valve2-2 (SteamOS 3.9.5) |

At 3840x2160 144 Hz, 10-bit 4:4:4, HDR, VRR 40-144 Hz. Reports for other TVs and
monitors are welcome as GitHub issues.

## Credits

All credit for the HDMI FRL and VRR work goes to Tomasz Pakula (Lawstorant); the
fix-up this repository packages is his commit `21d564d5a1`. The hotplug fix is
based on AMD commit `c953b39f9487` by Ivan Lipski. This repository only packages
their work for SteamOS.

## The problem

`amdgpu_dm_update_freesync_caps()` in
`drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c` decides whether a connector
is FreeSync capable. Its HDMI branch tests the sink signal for exact equality
with `SIGNAL_TYPE_HDMI_TYPE_A`. When the link trains as FRL the sink signal is
one of the other HDMI signal types that DC knows about, so the branch is
skipped, the VRR range from the EDID is never parsed, and the connector's
`vrr_capable` property stays false. Nothing downstream can enable VRR:
`vrr_range` in debugfs is empty, gamescope and Steam see a fixed-refresh
display, and the TV reports VRR off.

The fix is to use DC's own helper, which matches every HDMI signal type instead
of just one:

```diff
--- a/drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c
+++ b/drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c
@@ -14324,7 +14324,7 @@ void amdgpu_dm_update_freesync_caps(struct drm_connector *connector,
 		}
 
 	/* HDMI */
-	} else if (sink->sink_signal == SIGNAL_TYPE_HDMI_TYPE_A) {
+	} else if (dc_is_hdmi_signal(sink->sink_signal)) {
 		/* Prefer HDMI VRR */
 		if (hdmi_vrr.supported) {
 			amdgpu_dm_connector->as_type = ADAPTIVE_SYNC_TYPE_HDMI;
```

Valve's 7.2 tree already carries Tomasz Pakula's HDMI VRR series as `[FROM-ML]`
commits, but not this fix-up, which is why FRL plus VRR does not work on stock
SteamOS. The change is equivalent to commit `21d564d5a1`, "Switch to signal type
helper functions from DC", on the `hdmi-7.2` branch of
<https://github.com/Lawstorant/linux>. All credit for the HDMI FRL and VRR work,
and for this fix, goes to Tomasz Pakula (Lawstorant); this repository only
packages it for SteamOS.

## The second problem: FRL is lost on every hotplug

With the mask set, the link trains as FRL on the first detect after boot, but
every later detect comes back TMDS-only and stays there until the machine is
rebooted. A TV re-handshake after wake, a TV input switch and a `0` then `1`
write to `trigger_hotplug` all do it.

A detect recreates the sink as `SIGNAL_TYPE_HDMI_TYPE_A`, so only a destructive
verify can promote it back to FRL;
`verify_link_capability_non_destructive()` cannot. Which one runs is decided by
`should_verify_link_capability_destructively()` in
`drivers/gpu/drm/amd/display/dc/link/link_detection.c`. Its HDMI FRL branch sets
`destrictive = true` and then gives it away again:

```c
	} else if (link->dc->config.skip_frl_pretraining) {
		for (i = 0; i < MAX_PIPES; i++) {
			if (pipes[i].stream != NULL &&
				pipes[i].stream->link == link) {
				/*If link is already active, skip PHY programming*/
				if (link->link_status.link_active) {
					destrictive = false;
				}
			}
		}
	}
```

`dc->config.skip_frl_pretraining` is set unconditionally in every DCN 3.x
resource file, `dcn32_resource.c` and `dcn321_resource.c` among them, so it is
always true on this Navi 33; and gamescope keeps the CRTC lit across a hotplug,
so `link_status.link_active` is always true as well. Every detect after the
first one is therefore non-destructive, and FRL can never come back.

Mainline no longer has that global gate. The same branch there reads
`link->local_sink->edid_caps.panel_patch.skip_frl_pre_training`, a per-panel
EDID quirk that is off unless a specific panel asks for it, so a current kernel
retrains FRL destructively on every hotplug (commit `c953b39f9487`,
"drm/amd/display: Reintroduce \"Force validation link training on all ASICs\"").
7.2.4-valve1 has no such field, so `patches/0002-dc-link-frl-verify-on-hotplug.patch`
drops the `else if` and its pipe loop outright, leaving `is_hdmi_frl_in_use()`
as the only reason to go non-destructive.

The trade-off is that a hotplug now tears the link down and retrains it, so the
output blanks for a moment where it used to stay lit at the wrong rate. That is
mainline behaviour, and it is what buys 4K144 back instead of 4K120 4:2:0.

## How the build works

`setup.sh` is a wrapper around the scripts below. You only need them if you
want to install by hand instead of with `setup.sh`; the one-line install has
already run all of them. To run them by hand, use a clone (a downloaded zip
loses the executable bits):

```
git clone https://github.com/beaglemoo/steam-machine-hdmi21 ~/steam-machine-hdmi21
cd ~/steam-machine-hdmi21
./build.sh                    # ~2 min build, plus the source download the first time
sudo ./install.sh
sudo ./setup-selfheal.sh
sudo ./hdmi-mode.sh frl
sudo reboot
```

`setup.sh install` uses an existing git checkout in `~/steam-machine-hdmi21` in
place and never overwrites it; update it with `git pull`.

`build.sh` is unattended and idempotent. It detects the running kernel, checks
that it is 7.2 or later (`--check-kernel` does only this), works out which
`linux-neptune-NN` package it came from, installs `linux-neptune-NN-headers` and
`base-devel` (the stock image has no `gcc` or `make`) if they are missing,
downloads the newest matching source tarball from the SteamOS mirror into
`/home/deck/.cache/steam-machine-hdmi21/`, extracts only the bare git repository
from it, checks out the tag whose commit hash matches the `-g` suffix of
`uname -r`, applies every patch in `patches/` in name order with `git am`, and
builds just the amdgpu module out of tree. Each patch has a sanity check on the
resulting tree; an existing `work/src` that is missing one (a checkout made
before the patch was added) is discarded and rebuilt from the tag. The result
lands in `out/amdgpu-$(uname -r).ko.zst` with a `.vermagic` sidecar. Useful
flags: `--src-tarball PATH` to use a tarball you already have, `--jobs N`,
`--cache-dir DIR`, `--out-dir DIR`.

The headers and `base-devel` live on the root filesystem, which a SteamOS update
replaces, so the build installs them again on the first boot after every update.
Builds take a lock on the cache directory, so two cannot run at once, and when
`build.sh` runs as root (the self-heal rebuild) it hands its output back to the
owner of the checkout.

The build is deliberately out of tree. SteamOS has no glibc headers, so the
kernel host tools (`fixdep`, `modpost`, `kconfig`) cannot be compiled and an
in-tree build is impossible; the headers package ships those tools prebuilt.
The one extra make variable, `CFLAGS_amdgpu_trace_points.o=-I<src>/include/trace`,
is needed because `amdgpu_trace.h` sets `TRACE_INCLUDE_PATH` relative to
`include/trace/define_trace.h`, which resolves inside the headers tree where the
driver sources do not exist.

`install.sh` copies the module to `/lib/modules/$(uname -r)/updates/amdgpu.ko.zst`
with the read-only root temporarily disabled, runs `depmod -a`, checks that
`modprobe` now resolves amdgpu to `updates/`, and regenerates the initramfs. It
refuses to install a module whose vermagic does not match the running kernel.
`--dry-run` prints everything it would do without touching the system. The stock
module under `kernel/drivers/gpu/drm/amd/amdgpu/` is never modified, so the
change is fully reversible. `uninstall.sh` deletes only that one file and re-runs
`depmod` and `mkinitcpio`, so the stock module takes over again.

`hdmi-mode.sh` switches the link mode:

- `sudo ./hdmi-mode.sh frl` writes `/etc/default/grub.d/hdmi-frl.cfg` with
  `amdgpu.dcfeaturemask=0x402` (DC_FRL_MASK `0x400` plus the default `0x2`),
  creates the marker file `~/.hdmi-frl-enabled`, and runs `update-grub`.
- `sudo ./hdmi-mode.sh tmds` removes both and regenerates grub.
- `./hdmi-mode.sh status` reports the running mode, the configured mode, whether
  the patched module is installed and loaded, and the current mode line.

Both need a reboot. `STATE_DIR` overrides where the marker file lives; by
default it is the home directory of the user who ran sudo.

## Surviving SteamOS updates

A SteamOS atomic update replaces `/etc` and the whole `/usr` and `/lib` tree. Of
this setup:

- `/home` survives, so the checkout, the built module and the marker file are
  kept.
- `/etc/systemd/system/*.service` and `/etc/atomic-update.conf.d/*.conf` are on
  the default keep list, so the self-heal unit survives.
- `/etc/default/grub.d/hdmi-frl.cfg` (and `hdmi21-allm.cfg`, if you chose an ALLM
  setting) is not, which is what `selfheal/atomic-update-keep.conf` is for; `setup-selfheal.sh` installs it as
  `/etc/atomic-update.conf.d/hdmi-frl.conf`.
- `/lib/modules/.../updates/amdgpu.ko.zst` does not survive, and if the update
  ships a new kernel the old module would not load anyway.

`setup-selfheal.sh` installs `hdmi-frl-grub.service`, a oneshot unit ordered
after `local-fs.target`, `home.mount` and `network-online.target`. On every boot
it:

1. Does nothing at all if the marker file is absent, beyond removing a stale
   grub drop-in. That is the TMDS case.
2. Recreates the grub drop-in and re-runs `update-grub` if the FRL mask is
   missing.
   The ALLM drop-in is recreated from its own marker the same way, whether or
   not the FRL marker exists.
3. Reinstalls the patched module if `out/` already holds one whose vermagic
   matches the running kernel.
4. Otherwise starts `build.sh` followed by `install.sh` in a detached transient
   unit called `hdmi-frl-rebuild`, so that a kernel change does not block the
   boot for the length of a download and a compile. Follow it with
   `journalctl -fu hdmi-frl-rebuild`. VRR is missing until that finishes and you
   reboot once more; FRL itself, being a kernel parameter, works immediately.

Check on it with `systemctl status hdmi-frl-grub.service` and
`./hdmi-mode.sh status`.

## After resume

An s2idle suspend/resume can come back with the FRL link gone. On a TV that
tops out at 144 Hz the connector's mode list shows it: everything above the TMDS
pixel clock ceiling disappears (3840x2160 at 143.99 Hz is 1332750 kHz), even
though the EDID read back from the TV is byte-identical. What was lost is the FRL
link capability, not the EDID.

Neither the mode list nor the driver's link state is a reliable witness on its
own. A 120 Hz TV such as the LG C9 lists 4K120 at 1188000 kHz over FRL and over
TMDS 4:2:0 alike, so its mode list cannot tell the two links apart. And an
FRL-capable TV that runs a mode which fits TMDS on purpose (4K60, 1080p) has no
FRL encoder either, so "no FRL encoder" does not mean the link was lost. The
resume script therefore classifies the link from three inputs, and the first
match wins:

1. **hpo-row**: `/sys/kernel/debug/dri/0/amdgpu_dm_dtn_log` is amdgpu's hardware
   state dump, and its `HPO:` table lists the active HDMI FRL stream encoders.
   The driver only prints that table while one is enabled, so a row in it means
   the link is FRL right now. The `Link` column of the row is ignored: a healthy
   FRL link has been seen reading `Training`. Result: `frl`.
2. **mode-list**: the connector (`modetest -M amdgpu -c`) lists a mode above
   1,200,000 kHz. TMDS tops out at 600 MHz and 4:2:0 halves that, so only an FRL
   capable link can offer one (4K144 is 1332750 kHz); the capability is intact.
   Result: `frl`. This is the rule 1.0.0 used on its own.
3. **active mode**: the dump is complete, shows an OTG row and no HPO row, and the
   CRTC driving the connector (found through its encoder in `modetest -e -c -p`)
   runs a mode above 600,000 kHz. Above 600 MHz TMDS can only carry a mode as
   4:2:0 and FRL always uses the HPO encoder, so a 4K120 stream with no HPO
   encoder is the lost-FRL fallback. Result: `tmds`, meaning FRL was lost and
   recovery is warranted.

Everything else is `unknown` and is never acted on: a 120 Hz TV running 4K60 or
lower, a dump that is cut short, a file that cannot be read, a connector that is
not enabled, a missing `modetest`. That is deliberate. A lost link on a 120 Hz TV
can only be detected while it is driving a mode above 600 MHz, and a missed
recovery costs less than blanking the screen on a guess.

`selfheal/hdmi-frl-resume.sh` was written to force a re-detect through the
debugfs file `/sys/kernel/debug/dri/0/HDMI-A-1/trigger_hotplug`: writing `1`
alone returns early while the connector already reads connected, so it writes a
`0` first to tear the link down, which makes the following `1` a real
disconnected-to-connected detect. On this kernel that cannot restore FRL. The
re-detect does run, but the `skip_frl_pretraining` gate described above turns it
into a non-destructive verify, which can only bring the link back as TMDS. The
lost FRL modes after a resume are that same bug, not a separate one.

Patch 0002 is the fix, and the installer always includes it: with it the
driver verifies the link capability
destructively on every hotplug, including the one after a resume, and the FRL
link comes back on its own.

The resume unit stays installed as a belt-and-braces check, and with patch 0002
loaded it should normally log `FRL link is up, nothing to do` and exit. It waits
up to 60 s for the connector to read connected (the TV may still be waking), then
polls the link state for up to 20 s more, because patch 0002 retrains FRL on the
resume hotplug by itself. If the link comes up in that time it only logs and
exits, and never touches `trigger_hotplug`. Only a link that is still `tmds` (rule 3) after
the wait is re-detected, and only if the sink EDID advertises `Max Fixed Rate
Link`: up to five `0`, `1` cycles. After each cycle it emits a synthetic `change`
uevent with `udevadm trigger` first, because neither debugfs write emits one and
the compositor needs it to re-read the connector and switch to an FRL stream, and
only then reads the link state again with the same rules; `frl` by rule 1 or 2
counts as success. An unknown state does nothing and exits 0, so the screen is
never blanked on a guess. The unit does nothing at all unless bit `0x400` of
`amdgpu.dcfeaturemask` is on the running cmdline.

Version 1.0.0 judged the link from the mode list alone, treating a highest mode
clock above 1,200,000 kHz as proof of FRL and anything else as lost. On a 120 Hz
TV that never held, so every resume forced five `0`, `1` cycles, each blanking
the screen, and then failed the unit while FRL was running fine. That is fixed in
1.0.1.

`setup-selfheal.sh` installs it as `hdmi-frl-resume.service`, a oneshot ordered
`After=` and `WantedBy=` the four sleep targets.

To see what it makes of the current link without writing anything (it prints
the link state, the rule that decided it, its inputs and the `HPO` row or `HPO
row: none`; reading the dump needs root):

```
sudo selfheal/hdmi-frl-resume.sh --check
journalctl -u hdmi-frl-resume.service -b
```

`--force` runs one cycle even when the FRL link is up or the state is unknown,
which is how the cycle itself was verified.

An LG C9 report had the screen blanking several times after every resume. The
cause was the 1.0.0 mode clock check described above, not the TV waking: it
could not see FRL on a 120 Hz TV and forced the blanking cycles. Upgrade to 1.0.1
(see "Upgrading"). If the screen still blanks after a resume, please add the
output of `journalctl -b -u hdmi-frl-resume.service` and `sudo
selfheal/hdmi-frl-resume.sh --check` to the issue tracker. To rule the unit out
while testing, turn it off and try a few sleep/wake cycles:

```
sudo systemctl disable hdmi-frl-resume.service    # turn it back on with enable
```

## Known limitations

- The module is built out of tree and is unsigned. It taints the kernel with
  `O` and `E`. Secure Boot is off on SteamOS and `CONFIG_MODULE_SIG_FORCE` is
  not set, so it loads normally.
- Sleep/wake: 1.0.0 blanked the screen five times on every resume on 120 Hz
  TVs (seen on an LG C9) because it read the mode list instead of the link
  state; fixed in 1.0.1. See "After resume". The link state comes from a debugfs
  file, so the resume check needs root and cannot tell which of several outputs
  carries the FRL link; the Steam Machine has one HDMI port. On a 120 Hz TV a
  lost FRL link is only detected while it drives a mode above 600 MHz (4K120);
  at 4K60 or lower the check reports unknown and does nothing.
- A SteamOS update that changes the kernel means a rebuild. That is automatic
  with the self-heal installed, but it needs a working network connection and a
  second reboot.
- `mkinitcpio -P` exits 1 on SteamOS with `ERROR: module not found:
  blake2b_generic`. This is pre-existing and unrelated; the stock image has the
  same problem. `install.sh` treats it as non-fatal only when the initramfs
  image was actually rewritten. `amdgpu` is not part of the initramfs on this
  machine anyway, so the step only matters for completeness.
- ALLM: the kernel exposes the ALLM property on the connector, but gamescope
  3.16.26 never sets it, so the TV is not switched into game mode automatically.
  Pick the game picture mode on the TV.
- QMS and DSC are not used. The link runs uncompressed; 4K144 10-bit 4:4:4 fits
  in FRL 4-lane bandwidth without DSC.
- The TMDS fallback is a real fallback, not a downgrade path to avoid: without
  the patched module it is the only mode with working VRR, at 4K120 4:2:0 8-bit.
- Only the amdgpu module is replaced. Nothing else in the kernel is patched, and
  the stock module stays on disk untouched.

## Layout

```
setup.sh                    one-step installer: install | uninstall | status | allm
get.sh                      bootstrap: downloads a release and runs setup.sh
hdmi21-install.desktop      Desktop Mode launcher for setup.sh install
hdmi21-uninstall.desktop    Desktop Mode launcher for setup.sh uninstall
build.sh                    build a patched amdgpu.ko.zst for the running kernel
install.sh                  install it into /lib/modules/<kernel>/updates/
uninstall.sh                remove it again
hdmi-mode.sh                frl | tmds | status
hdmi-allm.sh                disabled | dynamic | always-on | default | restore | status
setup-selfheal.sh           install and enable the boot-time self-heal
patches/                    the kernel patches, git format-patch style
selfheal/                   the self-heal scripts, their units, and the atomic keep list
VERSION                     release version
CHANGELOG.md                what changed in each release
out/                        build output (not tracked)
work/                       patched kernel checkout (not tracked)
```

## Licence

GPL-2.0. The patch is a derivative of Linux kernel source; the scripts are
released under the same licence for consistency. See `LICENSE`.
