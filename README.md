# BareMetalCloudRebuild

Build a bootable USB stick that installs Windows 11 directly from Windows
Update onto an empty disk. No Windows installation image is stored on the
stick: it boots a customised copy of your PC's Windows Recovery Environment
(WinRE), then downloads Windows when you start the rebuild.

> **Starting a rebuild erases the selected target disk.** The menu requires
> you to type `ERASE`. With `AUTO=1`, it starts without confirmation when
> exactly one target disk is found. Back up your data first.

## Requirements

- A Windows 11 PC with an enabled recovery environment containing Cloud rebuild
  (`Rebuild.exe`), from the October 2026 preview update (KB5127936) or later.
- Windows PowerShell 5.1 or later, running as administrator.
- A USB stick of at least 2 GB.
- [Rufus](https://rufus.ie), or another tool for formatting GPT + FAT32.
- On the target computer: x64 UEFI firmware and a wired internet connection.
- A licence for the edition of Windows you install.

No Microsoft binaries are included. The builder works on a copy of your PC's
recovery image and does not change the original or format your USB stick.

## Build the USB files

Open PowerShell **as administrator**, change to this repository's folder,
then run:

```powershell
.\Build-RebuildUsb.ps1
```

If PowerShell says running scripts is disabled, allow them for this window
only, then retry:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Build-RebuildUsb.ps1
```

The files are written to `out\usb-files`. That output folder is replaced when
you rebuild. If the recovery image lacks Cloud rebuild, update Windows or
provide a suitable recovery image explicitly:

```powershell
.\Build-RebuildUsb.ps1 -WinREPath D:\images\winre.wim
```

Use `-OutputPath D:\usb-files` to choose another output folder. Do not point
the output or work folder at a location containing files you want to keep.

## Copy to the USB stick

1. If the stick is not already prepared, format it in Rufus with:
   - Boot selection: **Non bootable**
   - Partition scheme: **GPT**
   - File system: **FAT32**
   - Volume label: **CRMEDIA**

   **Formatting erases the USB stick.** Double-check which device you select.
   Keep the `CRMEDIA` label: the menu uses it to identify and exclude the USB
   disk from installation targets.

2. Copy the **contents** of `out\usb-files` to the root of the stick, not the
   enclosing folder. Its root should contain:

   ```text
   CloudRebuild\
   EFI\
   Recovery\
   ```

The copied files make the stick UEFI-bootable; Rufus only prepares its format.
The default boot manager uses the Windows UEFI CA 2023 certificate when
available in the recovery image. The target firmware must trust it.

## Install Windows

Connect wired networking and boot the target computer from the USB stick
using its UEFI boot menu.

- **1 Edition**, **2 Language**, **3 Version**: choose what to install.
- **4 Choose target disk**, **5 Show disk details**: verify the disk before
  starting. Disconnect other disks you do not want to risk erasing.
- **6 LCU version**, **7 Branch**: advanced settings; normally leave these
  at `1.0` and `ge_release`.
- **P Preview**: opens the rebuild confirmation flow. Choose "Remove files",
  inspect the summary, then **Cancel** to return without erasing. Continuing
  through "Erase and install" is destructive.
- **S Start**: type `ERASE` to download and install Windows. On success the
  computer restarts into Windows setup. Remove the stick when prompted.
- **C Command prompt**, **R Recovery menu**, **X Shut down**: other actions.

If the rebuild fails or is cancelled, the menu returns with an exit code.
Logs are copied to `CloudRebuild\Logs` on the stick when it is writable.

## Presets and unattended installation

On the USB stick, rename `CloudRebuild\answers.cmd.sample` to `answers.cmd`.
Uncomment the settings you want to preset, for example:

```batch
set EDITION=Professional
set LANG=en-US
set VERSION=10.0.26300.9974
```

With presets alone, the menu still appears. Adding `set AUTO=1` starts the
rebuild at boot without asking, but only when exactly one target disk is found.
**That disk will be erased.** Leave this disabled for interactive use.

## Version, edition and hardware limits

- The default version is fixed at `10.0.26300.9974`. Windows Update must offer
  the exact requested version and branch; there is no automatic selection of
  the latest build. Change menu option 3 or the preset when needed.
- The menu offers `Professional` (Pro), `Core` (Home), `ProfessionalN` and
  `CoreN`. Other edition IDs can be set in the answers file, but may deliver
  one of those base editions instead. Enterprise, Education, Pro for
  Workstations and Pro Education map to Pro; Home Single Language maps to
  Home; their N variants map to Pro N. Edition changes and activation require
  an appropriate licence.
- The language menu offers `en-US` and `sv-SE`. Other languages can be set in
  the answers file, but availability depends on the requested build.
- Hardware compatibility depends on drivers in WinRE. Wi-Fi, additional
  storage/network drivers and multiple internal disks are not guaranteed.
- The builder's `-OlderBootManager` switch uses the recovery image's alternate
  boot-manager set for firmware without Windows UEFI CA 2023 trust;
  compatibility is not guaranteed.
- The solution invokes the undocumented `Rebuild.exe` command-line interface.
  Windows updates may change its behaviour.

## Troubleshooting

| Problem | Action |
|---|---|
| Recovery image not found | Run `reagentc /info` as administrator; enable WinRE or supply `-WinREPath`. |
| Recovery image has no `Rebuild.exe` | Update Windows or supply a newer recovery image. |
| Cloud rebuild appears stuck behind the console | Click the background or press Alt+Tab to see its pages. |
| `0xC1900500` in the logs | Windows Update does not offer the requested version/branch; check both. |
| `0x8000ffff` in the logs | The requested edition may not exist in that build; choose a supported edition and inspect the logs. |
| No network or target disk | WinRE may lack the required driver; do not proceed until the intended disk and network are available. |

## Repository contents

- [Build-RebuildUsb.ps1](./Build-RebuildUsb.ps1): builds the USB files.
- [winre/crmenu.cmd](./winre/crmenu.cmd): recovery-environment menu.
- [winre/answers.cmd.sample](./winre/answers.cmd.sample): optional presets.
- `.gitattributes`: preserves the CRLF line endings required by the batch files.
- `.gitignore`: excludes generated output and Windows image files.

Development scripts, test infrastructure, results and generated recovery images
are intentionally not included.
