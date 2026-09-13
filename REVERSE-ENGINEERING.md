# Gigabyte MUX / Advanced Optimus — Research Notes

Machine: Gigabyte notebook, AMD iGPU + NVIDIA RTX 5070, EC-driven display mux.
Goal: Advanced Optimus (runtime mux flip) on Linux.

## Windows control path (fully mapped)

```
GPilot UI → ucNotebook.dll → named pipe → Gbt.GpuPowerGear.Service
  → BiosHelper.WriteDisplayMode
  → GB_WMIACPI_Set::SetPEG2orSG2 (WmiMethodId 0xE6, Data: UInt8)
  → wmiacpi.sys / acpimof.dll → ACPI\PNP0C14 → EC
```

WMI namespace ROOT\WMI:

| Class | GUID | Use |
|---|---|---|
| GB_WMIACPI_Set | ABBC0F75-8EA1-11D1-00A0-C90629100000 | writes |
| GB_WMIACPI_Get | ABBC0F6F-8EA1-11D1-00A0-C90629100000 | reads |
| GB_WMIACPI_Event | ABBC0F72-8EA1-11D1-00A0-C90629100000 | EC events |
| GB_WMIACPI_Data | ABBC0F6C-8EA1-11D1-00A0-C90629100000 | test/query |
| RW_GMWMI | 644C5791-B7B0-4123-A90B-E93876E0DAAD | IO read |

Method IDs: SetPEG2orSG2/GetPEG2orSG2 = 0xE6; SetNvPowerConfig/GetNvPowerConfig = 0x51
(dGPU power: Data=4 on, 3 off); GetPfmBridge/SetPfmBridge = 0x4D (BIOS-busy poll);
SetNvD1–D5 = 0x52–0x56; SetDynamicBoostStatus = 0xE7; getAiPowerCtlCapability = 0xEB.

BiosDisplayMode enum (passed as Data byte to 0xE6):
  0 = Dynamic, 1 = Discrete, 2 = MsHybrid

ucNotebook.Helper.CWMI: SetMuxStatus(bool) → Data 0|1; GetMuxStatus → true iff Data==1.

NVIDIA DDS state (registry, read-only):
  HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NvHybrid\Persistence\ACE
  InternalMuxState: 1=iGPU, 2=dGPU; InternalMuxIsAutomaticMode: 1=Auto, 2=Manual.
  IsNvDdsEnabled (mux=dGPU && Manual) blocks dGPU power-off.

## ACPI table findings (HKLM:\HARDWARE\ACPI dumps)

- DSDT (GBTUACPI): EC fields incl. DSMD (display mode byte), DDSS (DDS support flag),
  QBMD, GC6F — in \_SB.PCI0.SBRG.EC0 region space.
- SSD8 "Opt2Tabl" on \_SB.PCI0.GPP9.PEGP (dGPU): NVOP, NBCI, NVJT, GC6I/GC6O (RTD3),
  GPS_ DSM (Dynamic Boost telemetry), DGCX. NO MXMX/MXDM/MXDS/MUDM/MDPS.
- SSDA "CDFAAIG2" on \_SB.PCI0.GPPA.VGA_ (AMD iGPU): ATPX (PowerXpress mux iface,
  PX00–PX12 handlers incl. PX03/PX04 display-switch candidates) + ATIF (AFN0–8, AFNC).
- SSDW "GpMsSsdt": EC field refs + _PRW/_S0W wake for GPP6/GPP9 only.
- Windows DDS path: WDDM → AMD iGPU driver → ATPX → EC DSMD. Mux hardware CAN
  flip live (DDS works on Windows).

## NVIDIA open-gpu-kernel-modules DDS interface (what driver expects)

- Entry: nvRmMuxSwitch (src/nvidia-modeset/include/nvkms-rm.h), plus nvRmMuxPre/Post/State.
- Low level: osCallACPI_MXDM / osCallACPI_MXDS (src/nvidia/arch/nvalloc/unix/src/os.c)
  → nv_acpi_mux_method on the dGPU's own ACPI handle.
- MXDS arg = NvU32: bits[3:0] op (0=get,1=set disp,2=set backlight,3=set both),
  bit[4] target (0=iGPU,1=dGPU). Return: 0=not muxed to this GPU, 1=muxed.
- MXDM mode values (mxds-gmux driver): 1=dGPU only, 2=iGPU only, 3=MsHybrid dynamic.
- Hybrid caps probed via dGPU _DSM ACPI_DSM_FUNCTION_NVHG (likely already present).

## Linux plan

1. Recon: acpidump+iasl → disassemble SSDA, map ATPX function IDs (find the
   display-switch function — PX03/PX04 candidates); acpi_call ATPX(1) for function
   vector; ls /sys/bus/wmi/devices for ABBC0F6F/ABBC0F75.
2. SSDT overlay (initrd ACPI table override): define MXDM/MXDS under
   Scope(\_SB.PCI0.GPP9.PEGP) forwarding to \_SB.PCI0.GPPA.VGA_.ATPX (live flip)
   — NOT a bare DSMD write (that's probably POST-only flag path).
3. Stock open-gpu-kernel-modules sees a standard DDS platform; no patch needed.
   nvidia-drm.modeset=1.
4. Debug sequencing: PSR during flip (NBCI present), GC6O wake before switch to dGPU.
5. Fallback: patch os.c nv_acpi_mux_method to call wmi_evaluate_method(ABBC0F75,0,0xE6).

## Linux session 2026-09-13 (Parrot 7.3, kernel 7.0.13)

Machine confirmed: **GIGABYTE AERO X16 1WH, BIOS FB07 (2025-11-07)**.
RTX 5070 Max-Q = GB206M `10de:2d18` @ `64:00.0` (+HDMI audio .1). iGPU Krackan
`1002:1114` @ `66:00.0` drives eDP (card0).

### ACPI map verified on this machine (~/mux_acpi/dsl)

- `\_SB.PCI0.AMW0` = PNP0C14 hub. GUID→objid: Get ABBC0F6F→`WMBC`,
  Set ABBC0F75→`WMBD`, Data ABBC0F6C→`WQAC`, Event ABBC0F72.
- `WXCM(cmd,data)` = `XCMI=cmd; XCMD=data` (2×8-bit EC mailbox regs on AMW0).
  `RXCM(cmd)` reads back XCMD.
- **SetPEG2orSG2** = `WMBD(0,0xE6,{mode})` → `WXCM(0xD0,mode)` (EC cmd 0xD0).
- **GetPEG2orSG2** = `WMBC(0,0xE6,{0})` → `RXCM(0xD0)&0x7F`. Verified: `0`=Dynamic.
- **SetNvPowerConfig** = `WMBD(0,0x51,{v})`, gated on `DPMF != 2`:
  - v=4: `WXCM(0xC7,0)`; if `GPP9.D0ST==3` just `WMOF=0`, else `PEGP._ON()`;
    then `Notify(PCI0,0)` bus check → Linux rescans → GPU appears. **Verified
    working — 5070 enumerated at 64:00.0.**
  - v=3: `WXCM(0xC7,1)` + `Notify(PEGP,0x03)` eject.
  - v=0/1: NPCF.ACBT 0/LCBT + `Notify(NPCF,0xC0)` ("Opt-mode 2 disable/enable").
- `GetNvPowerConfig`/`GetPfmBridge` are **not implemented** in WMBC — they fall
  to `Default { Return (Arg2) }` (echo of input buffer). getAiPowerCtlCapability
  0xEB returns 2.
- `DSMD` = EC offset 0x2D bit0, "dGPU powered off" flag: set by `PEGP._OFF`,
  cleared by `PEGP._ON` and EC `_REG`. Sibling bits: QBMD, DDSS.
- `GAPD` (GBT0005) `_STA`: if `RXCM(0xC7)==1` → `PG00._OFF()` + `WMOF=1`
  (keeps dGPU off across POST; WMOF also makes PEGP._ON a no-op).
- ssdt9=Opt2Tabl: PEGP `_ON`/`_OFF`, GC6I/GC6O (RTD3, sets EC GC6F), NVJT
  (MHYB=1, GC6V=2), NVOP, NBCI, GPS _DSM on `\_SB.PCI0.GPP9.PEGP`.
  `_DSM` GUIDs: NBCI d4a50b75-…, NVJT cbeca351-…, NVOP a486d8f8-…, GPS a3132d01-…
- ssdt11=CDFAAIG2: ATPX on `\_SB.PCI0.GPPA.VGA` — PX00 vector, PX02 dGPU power,
  PX03/PX04 toggle GPIOs 0x17/0x18 (mux select lines), PX12 panel reset.
- ssdt33=GpMsSsdt, ssdt7=Hetero. NPCF `\_SB.NPCF` (NVDA0820) = Dynamic Boost.
- Still zero MXMX/MXDM/MXDS/MXID — no NVIDIA ACPI DDS. Runtime flip path on
  eDP = NV0073_CTRL_CMD_INTERNAL_DFP_SWITCH_DISP_MUX via GSP (needs nvidia
  driver + a /dev/nvidia-modeset client; nothing shipped yet).

### Working on Linux now

- `acpi_call` via acpi-call-dkms (dkms built for 7.0.9 + 7.0.13).
  Syntax: `echo '\_SB.PCI0.AMW0.WMBD 0 0xE6 { 1 }' > /proc/acpi/call`.
- `gbmux` CLI → `/usr/local/bin/gbmux` (src in this folder):
  `status`, `dynamic|discrete|hybrid` (0xE6, applies at POST),
  `gpu on|off` (0x51 v=4/3, runtime).
- Dumps: `~/mux_acpi/{tbl,dsl}` (raw .dat + disassembled .dsl).

### Lessons

- **Never let nouveau near this dGPU.** `gpu on` + nouveau probe = display
  wedge. `/etc/modprobe.d/blacklist-nouveau.conf` + initramfs rebuild done;
  nvidia-installer-disable-nouveau.conf also present.
- `/tmp` is tmpfs — large files die on reboot.
- pkexec works for root (GUI prompt). sudo needs password; pkexec has no tty.

### Next

1. ~~Reboot → nouveau stays out, nvidia install~~ DONE — 615.71.09 via .run
   (--dkms --no-x-check). PRIME offload verified (GLX+VK), RTD3 auto-suspend
   works (runtime_status=suspended, control=auto).
2. ~~`gbmux discrete` + reboot~~ DONE — Discrete verified: panel on nvidia
   (card1), KDE Wayland on 5070, amdgpu card0 still present, panel shows
   disconnected on card0-eDP. Recovery if black: tty → `gbmux dynamic` + reboot.
   Caveat: Type-C video dies in Discrete (wired to iGPU) — same as Windows.
3. Runtime flip: check `bInternalMuxSupported` once RM is up (dmesg/NVRM log),
   then decide if a /dev/nvidia-modeset client can issue PRE/SWITCH/POST.

## Tools in this folder

- il_dump.py        — dnfile/pefile .NET IL disassembler (resolves tokens/strings)
- gen_opcodes.ps1   — generates IL opcode map from System.Reflection.Emit
- mux_wmi_query.ps1 — dumps GB_WMIACPI_* class qualifiers + method IDs from live CIM
- dsdt_scan.ps1     — scans HKLM:\HARDWARE\ACPI tables for method-name hits
- cursor_chat_nvidia_mux_source_mapping.json — original Cursor analysis export

### Runtime flip — VERDICT: not possible on this hardware (2026-09-13)

Tested all three avenues:

1. **ATPX GPIO** (`flip_probe.sh`, PX03/PX04 toggled 2x, ~4s holds): no visual
   change. Offsets 0x17/0x18 are POST-setup lines, not live mux select.
2. **vgaswitcheroo**: amdgpu detects ATPX, but nvidia-drm never registers as a
   client → no usable switch file. Dead end for internal panel.
3. **NVKMS internal mux (option C)**: built `~/mux_acpi/muxq.c` against the
   615.71.09 open-source headers (exact version match). Result:
   `QUERY_DISP` → `muxDisplays` EMPTY. `DFP_INIT_MUX_DATA` never succeeded —
   GSP/RM has no mux topology for the internal eDP dpy (0x100).
   No mux dpys ⇒ GET_MUX_STATE/SWITCH_MUX have no target. Path dead.

Conclusion: the mux chip is POST-only, identical to Windows — GiMATE's mux
switch requires reboot there too. `gbmux` is feature-parity with Windows
GiMATE for mux control, plus dGPU power + PRIME offload on top.

Tool left behind: `~/mux_acpi/muxq.c` (build: gcc, -I the open-gpu-kernel-modules
tree; requires /dev/nvidia-modeset = mknod c 195 254). Read-only probe;
useful if a future driver/BIOS rev ever exposes mux dpys.

### AC/battery auto dGPU power (2026-09-13)

Shipped in gbmux 1.0-1, mirrors GiMATE GpuPowerGear:

- `etc/udev/rules.d/99-gbmux-acpower.rules`: ACAD `change` events →
  `SYSTEMD_WANTS=gbmux-acpower.service` (verified via `udevadm test
  --action=change`).
- `lib/systemd/system/gbmux-acpower.service`: oneshot, also runs at boot
  (multi-user.target) so boot-on-battery is covered.
- `usr/lib/gbmux/gbmux-acpower`: reads AC state from sysfs, reads mux mode
  via `gbmux mode` — **skips entirely in Discrete (mode=1)** since the dGPU
  owns the panel. Battery: `modprobe -r` nvidia stack → `gbmux gpu off`
  (eject via EC). If GPU busy, eject refused, RTD3 still suspends.
  AC: `gbmux gpu on` + modprobe nvidia stack.
- Logs: `journalctl -t gbmux-acpower`. Live-tested on AC.
