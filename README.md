# steam-machine-hdmi21

HDMI 2.1 FRL with working VRR on the Valve Steam Machine, on SteamOS kernel 7.2
(`linux-neptune-72`).

Out of the box the Steam Machine drives an HDMI 2.1 display over TMDS, which
caps it at 4K120 4:2:0 8-bit. Booting with `amdgpu.dcfeaturemask=0x402` turns on
the DC FRL code path and gets the full HDMI 2.1 link: 4K144, 10-bit, 4:4:4, HDR.
What you lose in exchange is VRR, because the display driver stops recognising
the sink as HDMI once it is running FRL, and the FRL link itself, which is
dropped for TMDS on the first hotplug after boot. This repository contains the
two kernel patches that fix both, a build script that produces a patched
`amdgpu` module for the exact kernel you are running, and the glue that keeps it
all working across SteamOS updates.

Verified on a Steam Machine driving an LG C4 at 3840x2160 144 Hz, 10-bit 4:4:4,
HDR, VRR 40-144 Hz, on kernel `7.2.0-valve1-1-neptune-72-gd39b4282853d`.

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

## Requirements

- A Steam Machine (or another SteamOS 3.9 device) on `linux-neptune-72`.
- `linux-neptune-72-headers` matching the running kernel. `build.sh` installs it
  if it is missing.
- About 8 GB free in the cache directory: the Valve kernel source tarball is
  3.4 GB and its extracted git repository is another 3.5 GB.
- Secure Boot off (the default), because the module is unsigned.

## Quick start

```
cd /home/deck
git clone <this repo> steam-machine-hdmi21
cd steam-machine-hdmi21
./build.sh                    # ~2 min build, plus the source download the first time
sudo ./install.sh
sudo ./setup-selfheal.sh
sudo ./hdmi-mode.sh frl
sudo reboot
```

After the reboot, pick 3840x2160 at 144 Hz in Steam's display settings (Steam
defaults to 120 Hz) and turn HDR on.

`build.sh` is unattended and idempotent. It detects the running kernel, works
out which `linux-neptune-NN` package it came from, downloads the newest matching
source tarball from the SteamOS mirror into
`/home/deck/.cache/steam-machine-hdmi21/`, extracts only the bare git repository
from it, checks out the tag whose commit hash matches the `-g` suffix of
`uname -r`, applies every patch in `patches/` in name order with `git am`, and
builds just the amdgpu module out of tree. Each patch has a sanity check on the
resulting tree; an existing `work/src` that is missing one (a checkout made
before the patch was added) is discarded and rebuilt from the tag. The result lands in `out/amdgpu-$(uname -r).ko.zst` with a
`.vermagic` sidecar. Useful flags: `--src-tarball PATH` to use a tarball you
already have, `--jobs N`, `--cache-dir DIR`, `--out-dir DIR`.

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
change is fully reversible.

`hdmi-mode.sh` switches the link mode:

- `sudo ./hdmi-mode.sh frl` writes `/etc/default/grub.d/hdmi-frl.cfg` with
  `amdgpu.dcfeaturemask=0x402` (DC_FRL_MASK `0x400` plus the default `0x2`),
  creates the marker file `~/.hdmi-frl-enabled`, and runs `update-grub`.
- `sudo ./hdmi-mode.sh tmds` removes both and regenerates grub.
- `./hdmi-mode.sh status` reports the running mode, the configured mode, whether
  the patched module is installed, and the current mode line.

Both need a reboot. `STATE_DIR` overrides where the marker file lives; by
default it is the home directory of the user who ran sudo.

## Verifying

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

## Reverting

```
sudo ./hdmi-mode.sh tmds     # back to TMDS: 4K120 4:2:0, VRR works on the stock module
sudo ./uninstall.sh          # remove the patched module override
sudo ./setup-selfheal.sh --remove
sudo reboot
```

`uninstall.sh` deletes only `/lib/modules/$(uname -r)/updates/amdgpu.ko.zst` and
re-runs `depmod` and `mkinitcpio`, so the stock module takes over again.

## Surviving SteamOS updates

A SteamOS atomic update replaces `/etc` and the whole `/usr` and `/lib` tree. Of
this setup:

- `/home` survives, so the checkout, the built module and the marker file are
  kept.
- `/etc/systemd/system/*.service` and `/etc/atomic-update.conf.d/*.conf` are on
  the default keep list, so the self-heal unit survives.
- `/etc/default/grub.d/hdmi-frl.cfg` is not, which is what
  `selfheal/atomic-update-keep.conf` is for; `setup-selfheal.sh` installs it as
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

An s2idle suspend/resume comes back with the FRL modes gone. The connector's
mode list loses everything above the TMDS pixel clock ceiling -- 3840x2160 at
143.99 Hz is 1332750 kHz and disappears, leaving only modes at or below 600000
kHz -- even though the EDID read back from the TV is byte-identical. What was
lost is the FRL link capability, not the EDID.

`selfheal/hdmi-frl-resume.sh` was written to force a re-detect through the
debugfs file `/sys/kernel/debug/dri/0/HDMI-A-1/trigger_hotplug`: writing `1`
alone returns early while the connector already reads connected, so it writes a
`0` first to tear the link down, which makes the following `1` a real
disconnected-to-connected detect. On this kernel that cannot restore FRL. The
re-detect does run, but the `skip_frl_pretraining` gate described above turns it
into a non-destructive verify, which can only bring the link back as TMDS. The
lost FRL modes after a resume are that same bug, not a separate one.

Patch 0002 is the fix: with it the driver verifies the link capability
destructively on every hotplug, including the one after a resume, and the FRL
modes come back on their own.

The resume unit stays installed as a belt-and-braces check. It only acts when
the FRL modes are missing, so with patch 0002 loaded it should normally log
`FRL modes present, nothing to do` and exit. When it does act, it waits up to
60 s for the connector to read connected (the TV may still be waking), skips out
if the sink EDID advertises no `Max Fixed Rate Link`, reads the mode list with
`modetest -M amdgpu -c`, runs up to five `0`, `1` cycles re-checking after each,
and on success emits a synthetic `change` uevent with `udevadm trigger`, because
neither debugfs write emits one and the compositor would not otherwise re-read
the connector. It does nothing at all unless bit `0x400` of
`amdgpu.dcfeaturemask` is on the running cmdline.

`setup-selfheal.sh` installs it as `hdmi-frl-resume.service`, a oneshot ordered
`After=` and `WantedBy=` the four sleep targets.

To see what it makes of the current link without writing anything:

```
sudo selfheal/hdmi-frl-resume.sh --check
journalctl -u hdmi-frl-resume.service -b
```

`--force` runs one cycle even when the FRL modes are present, which is how the
cycle itself was verified.

## Known limitations

- The module is built out of tree and is unsigned. It taints the kernel with
  `O` and `E`. Secure Boot is off on SteamOS and `CONFIG_MODULE_SIG_FORCE` is
  not set, so it loads normally.
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
build.sh                    build a patched amdgpu.ko.zst for the running kernel
install.sh                  install it into /lib/modules/<kernel>/updates/
uninstall.sh                remove it again
hdmi-mode.sh                frl | tmds | status
setup-selfheal.sh           install and enable the boot-time self-heal
patches/                    the two kernel patches, git format-patch style
selfheal/                   the self-heal scripts, their units, and the atomic keep list
out/                        build output (not tracked)
work/                       patched kernel checkout (not tracked)
```

## Licence

GPL-2.0. The patch is a derivative of Linux kernel source; the scripts are
released under the same licence for consistency. See `LICENSE`.
