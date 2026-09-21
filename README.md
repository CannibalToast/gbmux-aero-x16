# gbmux — Gigabyte AERO X16 mux / dGPU control for Linux

A Linux port of the GiMATE "GPU Mux Switch" and GpuPowerGear dGPU power
features, reverse-engineered from `Gbt.GpuPowerGear.Hardware.dll` and the
`GB_WMIACPI_*` WMI classes on Windows, then confirmed against the machine's
own DSDT. See [REVERSE-ENGINEERING.md](REVERSE-ENGINEERING.md) for the full
call chain.

**Hardware:** GIGABYTE AERO X16 (1WH), BIOS FB07 — AMD Krackan iGPU
(Radeon 840M/860M, `66:00.0`) + NVIDIA RTX 5070 Laptop / GB206M (`64:00.0`).
Other Gigabyte models sharing the `\_SB.PCI0.AMW0` WMI interface *may* work —
check for `ABBC0F75-*` under `/sys/bus/wmi/devices/` first.

## Commands

```
gbmux status            mux mode + dGPU presence/driver state
gbmux mode              raw mux mode (0=Dynamic 1=Discrete 2=MsHybrid)
gbmux dynamic           iGPU owns panel, dGPU free for PRIME offload   [reboot]
gbmux discrete          dGPU owns panel                              [reboot]
gbmux hybrid            MS-hybrid                                    [reboot]
gbmux gpu on            power dGPU onto the PCI bus (runtime)
gbmux gpu off           eject dGPU (runtime; refuses if nvidia bound)
gbmux call '<expr>'     acpi_call allowlisted to AMW0 WMBC/WMBD 0xE6|0x51
gbmux-setup             download + install the pinned NVIDIA driver
```

Mux changes apply at **next POST** — a reboot is always required, exactly
like GiMATE on Windows. In Discrete mode, Type-C display output dies (it's
wired to the iGPU) — same limitation as Windows.

## How it works

The `GB_WMIACPI_Set` WMI class (GUID `ABBC0F75-…`) maps to ACPI methods on
`\_SB.PCI0.AMW0`:

| Action | ACPI call | EC effect |
|---|---|---|
| get mux mode | `WMBC(0, 0xE6, buf)` → `RXCM(0xD0)&0x7F` | read EC mailbox 0xD0 |
| set mux mode | `WMBD(0, 0xE6, {mode})` → `WXCM(0xD0, mode)` | applied at POST |
| dGPU on | `WMBD(0, 0x51, {4})` | `WXCM(0xC7,0)` + `PEGP._ON` + rescan |
| dGPU off | `WMBD(0, 0x51, {3})` | `WXCM(0xC7,1)` + `Notify(PEGP, eject)` |

No custom kernel module — just `acpi_call` and sysfs.

## AC/battery automation

`gbmux-acpower.service` runs at boot and when the internal AC adapter
changes (`99-gbmux-acpower.rules`), mirroring GpuPowerGear. Only supplies
named `ACAD` or `ADP*` are trusted. A USB device that registers as type
Mains under another name does not flip dGPU policy. The NVIDIA functions
are chosen by PCI vendor `10de` and class (display vs HD-audio), not a
hardcoded bus address.

- **on battery**: unloads the nvidia stack if idle, then ejects the dGPU
  (deeper than RTD3). If busy, eject is refused and RTD3 keeps it suspended.
- **on AC**: powers the dGPU back on and reloads the nvidia stack.
- **Discrete mode: never touched** — the dGPU owns the panel there.

Logs: `journalctl -t gbmux-acpower`. Disable:
`sudo systemctl disable --now gbmux-acpower.service`.

### Apps holding the GPU

GPU contexts can't migrate — a process holding `/dev/nvidia*` (CUDA, NVENC)
blocks eject, and there is no transparent fallback to another vendor's GPU.
The approximation: kill the app so it restarts without the dGPU and falls
back itself (e.g. rustdesk NVENC → x264). Opt-in via
`/etc/gbmux-acpower.conf`:

```
KILL_ON_BATTERY="rustdesk"
```

Empty (default) = never kill; eject is skipped while the GPU is in use.

## No runtime (no-reboot) mux switching

Verified exhaustively — this board's mux is POST-only hardware:

- ATPX GPIO lines (PX03/PX04) are POST-setup signals, not live select.
- vgaswitcheroo: amdgpu detects ATPX, but nvidia-drm never registers.
- NVIDIA NVKMS internal-mux API: `NVKMS_IOCTL_QUERY_DISP` reports
  `muxDisplays` empty — GSP has no mux topology for the internal eDP
  (see `tools/muxq.c`, a read-only probe you can re-run on future drivers;
  `--grant-permissions` is required before it will take DRM master).

Use Dynamic + `prime-run <app>` for per-app dGPU rendering instead.

## Install

```
sudo apt install acpi-call-dkms pciutils curl psmisc procps
sudo dpkg -i gbmux_1.0-1_all.deb     # or: sudo make install
```

Build the .deb yourself: `make deb` (needs `dpkg-deb`).

Then `sudo gbmux-setup` for the pinned NVIDIA driver (615.71.09).
The installer is SHA256-verified on every run, including cache hits.
**nouveau must be blacklisted** — it wedges the display on GB206; the
package ships `gbmux-nouveau.conf`. If nouveau was already loading, run
`sudo update-initramfs -u` and reboot before installing the NVIDIA driver.
Unsigned NVIDIA modules need a Machine Owner Key while Secure Boot stays
on. Enroll one and reboot:

```
sudo mokutil --import /path/to/MOK.der
```

`gbmux-setup` reads the EFI Secure Boot variable and stops if that byte
cannot be read on an EFI system, or if Secure Boot is on. Turning Secure
Boot off also lets the modules load; that is not the default recommendation.

The package does not enable `gbmux-acpower.service` unless the Gigabyte WMI
GUID `ABBC0F75-*` is present. Optional confinement samples (not loaded or
installed into `/etc` by the package):

- AppArmor: `/usr/share/doc/gbmux/apparmor/usr.sbin.gbmux`
- sudoers: `/usr/share/doc/gbmux/examples/gbmux.sudoers` (commented; no
  `call`, no `gbmux-setup`)

## Recovery

Black panel after switching to Discrete: `Ctrl+Alt+F2` → log in →
`sudo gbmux dynamic` → `sudo reboot`.

## Tested on

Parrot Security 7.3, kernel 7.0.13, BIOS FB07, NVIDIA 615.71.09 (open
kernel modules via .run installer + DKMS). Dynamic, Discrete, PRIME
offload, RTD3 suspend, and AC-triggered eject all verified.

## Related

- [tangalbert919/gigabyte-laptop-wmi](https://github.com/tangalbert919/gigabyte-laptop-wmi) —
  a proper kernel WMI driver for newer Gigabyte laptops. `gbmux` talks to
  the same `AMW0` methods via `acpi_call` instead; pick whichever fits.
