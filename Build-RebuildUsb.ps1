#requires -Version 5.1
#requires -RunAsAdministrator
<#
Builds the files for a Cloud rebuild USB stick.

It takes the Windows recovery image (WinRE) of THIS PC, adds a text menu that
starts by itself, and writes a folder you copy to a USB stick. Booting that
stick on a computer with an empty disk installs a clean Windows 11 from
Windows Update.

  .\Build-RebuildUsb.ps1
  .\Build-RebuildUsb.ps1 -OutputPath D:\usb-files
  .\Build-RebuildUsb.ps1 -WinREPath D:\images\winre.wim     use this image instead

Then:
  1. Rufus: Boot selection "Non bootable", Partition scheme GPT, File system
     FAT32, Volume label CRMEDIA.
  2. Copy the CONTENTS of the output folder to the stick.

This script only builds files. It does not start a rebuild, does not change
this PC's recovery image (it works on a copy) and does not touch any disk.
The menu inside the image refuses to run anywhere but the recovery environment.

Needs a WinRE that contains Cloud rebuild (Rebuild.exe): a Windows 11 PC with
the October 2026 preview update (KB5127936) or later. The script checks and
stops if the image is too old.
#>
[CmdletBinding()]
param(
    # Where the USB files are written. The folder is replaced.
    [string]$OutputPath = "$PSScriptRoot\out\usb-files",
    # A winre.wim to use instead of this PC's own.
    [string]$WinREPath,
    # Scratch space for the image copy and its mount point.
    [string]$WorkPath = "$PSScriptRoot\out\work",
    # By default the boot manager and boot fonts signed with the "Windows UEFI
    # CA 2023" certificate are used when the image has them (Windows\Boot\EFI_EX
    # and Fonts_EX). That is what bcdboot picks and what the lab booted. This
    # switch keeps the image's other set instead, for firmware that does not
    # trust the 2023 certificate. Not tested.
    [switch]$OlderBootManager
)
$ErrorActionPreference = 'Stop'

$menuSource   = Join-Path $PSScriptRoot 'winre\crmenu.cmd'
$sampleSource = Join-Path $PSScriptRoot 'winre\answers.cmd.sample'
foreach ($f in $menuSource, $sampleSource) { if (-not (Test-Path $f)) { throw "Missing file: $f" } }

function Get-LocalWinREPath {
    # reagentc prints the location as \\?\GLOBALROOT\device\harddiskN\partitionM\Recovery\WindowsRE.
    # Only the path is parsed, so this works whatever the display language is.
    $info = (& reagentc.exe /info 2>&1) -join "`n"
    if ($info -notmatch '\\\\\?\\GLOBALROOT\\device\\harddisk\d+\\partition\d+\\[^\r\n]*') {
        throw "This PC's recovery environment was not found (it may be disabled; see 'reagentc /info'). Enable it, or pass -WinREPath with a winre.wim."
    }
    $Matches[0].TrimEnd(' ', '\') + '\Winre.wim'
}

function Copy-ImageFile {
    param([string]$Source, [string]$Destination)
    try { [IO.File]::Copy($Source, $Destination, $true) }
    catch {
        # Some .NET versions refuse \\?\GLOBALROOT paths; cmd's copy does not.
        & cmd.exe /c copy /y /b "$Source" "$Destination" | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Destination)) { throw "Could not copy $Source. Pass -WinREPath with a winre.wim instead. ($_)" }
    }
    # The recovery image is hidden, system and read-only; the copy must not be.
    [IO.File]::SetAttributes($Destination, [IO.FileAttributes]::Normal)
}

function Invoke-Bcd {
    $out = & bcdedit.exe @args
    if ($LASTEXITCODE -ne 0) { throw "bcdedit $($args -join ' ') failed: $out" }
    $out
}

function New-RamdiskBcd {
    # A boot store that starts \Recovery\WindowsRE\winre.wim from whatever
    # partition the boot manager itself was started from ('boot'). Nothing in
    # it names a disk, so the same files boot from any stick.
    param([string]$Store)
    Invoke-Bcd /createstore $Store | Out-Null
    Invoke-Bcd /store $Store /create '{ramdiskoptions}' /d 'Ramdisk options' | Out-Null
    Invoke-Bcd /store $Store /set '{ramdiskoptions}' ramdisksdidevice boot | Out-Null
    Invoke-Bcd /store $Store /set '{ramdiskoptions}' ramdisksdipath '\Recovery\WindowsRE\boot.sdi' | Out-Null
    $created = Invoke-Bcd /store $Store /create /d 'Cloud rebuild' /application osloader
    if ("$created" -notmatch '\{[0-9a-fA-F-]{36}\}') { throw "Could not read the new loader GUID from: $created" }
    $guid = $Matches[0]
    $ramdisk = 'ramdisk=[boot]\Recovery\WindowsRE\winre.wim,{ramdiskoptions}'
    Invoke-Bcd /store $Store /set $guid device $ramdisk | Out-Null
    Invoke-Bcd /store $Store /set $guid osdevice $ramdisk | Out-Null
    Invoke-Bcd /store $Store /set $guid path '\windows\system32\winload.efi' | Out-Null
    Invoke-Bcd /store $Store /set $guid systemroot '\windows' | Out-Null
    Invoke-Bcd /store $Store /set $guid winpe yes | Out-Null
    Invoke-Bcd /store $Store /set $guid detecthal yes | Out-Null
    Invoke-Bcd /store $Store /set $guid locale en-US | Out-Null
    Invoke-Bcd /store $Store /create '{bootmgr}' /d 'Windows Boot Manager' | Out-Null
    Invoke-Bcd /store $Store /set '{bootmgr}' device boot | Out-Null
    Invoke-Bcd /store $Store /set '{bootmgr}' path '\EFI\Microsoft\Boot\bootmgfw.efi' | Out-Null
    Invoke-Bcd /store $Store /set '{bootmgr}' locale en-US | Out-Null
    Invoke-Bcd /store $Store /set '{bootmgr}' default $guid | Out-Null
    Invoke-Bcd /store $Store /set '{bootmgr}' displayorder $guid | Out-Null
    Invoke-Bcd /store $Store /set '{bootmgr}' timeout 0 | Out-Null
}

# --- Get a private copy of the recovery image --------------------------------
if ($WinREPath) {
    if (-not (Test-Path $WinREPath)) { throw "WinRE image not found: $WinREPath" }
    $source = (Resolve-Path $WinREPath).Path
}
else { $source = Get-LocalWinREPath }
Write-Host "Recovery image: $source"

$mount = Join-Path $WorkPath 'mount'
$wim   = Join-Path $WorkPath 'winre.wim'
New-Item -ItemType Directory -Path $WorkPath -Force | Out-Null
if (Test-Path $mount) {
    # Left over from a run that was interrupted.
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null } catch { }
    Remove-Item $mount -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $mount -Force | Out-Null
if (Test-Path $wim) { Remove-Item $wim -Force }
Copy-ImageFile -Source $source -Destination $wim

# --- Build into a staging folder, publish only when everything worked --------
$stage = Join-Path $WorkPath 'usb-files'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$efiMs = Join-Path $stage 'EFI\Microsoft\Boot'
$re    = Join-Path $stage 'Recovery\WindowsRE'
New-Item -ItemType Directory -Path $efiMs, (Join-Path $stage 'EFI\Boot'), $re, (Join-Path $stage 'CloudRebuild') -Force | Out-Null

$mounted = $false
try {
    Write-Host 'Opening the image'
    Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mount | Out-Null
    $mounted = $true
    $sys32 = Join-Path $mount 'Windows\System32'

    if (-not (Test-Path (Join-Path $sys32 'Rebuild.exe'))) {
        throw 'This recovery image has no Cloud rebuild (Rebuild.exe). Install the latest Windows 11 updates on this PC (October 2026 preview, KB5127936, or later) and run the script again, or pass -WinREPath with a newer winre.wim.'
    }
    $reVersion = (Get-Item (Join-Path $sys32 'ntoskrnl.exe')).VersionInfo.ProductVersion
    Write-Host "WinRE version : $reVersion (Cloud rebuild present)"

    Write-Host 'Adding the menu'
    Copy-Item $menuSource (Join-Path $sys32 'crmenu.cmd') -Force
    $ini = Join-Path $sys32 'winpeshl.ini'
    if (Test-Path $ini) { Copy-Item $ini "$ini.orig" -Force }
    # The menu first; when it exits (option R), the normal recovery menu starts.
    @(
        '[LaunchApps]'
        'X:\Windows\System32\cmd.exe, /c X:\Windows\System32\crmenu.cmd'
        'X:\sources\recovery\recenv.exe'
    ) | Set-Content -Path $ini -Encoding Ascii

    Write-Host 'Collecting the boot files'
    $bootDir = Join-Path $mount 'Windows\Boot\EFI'
    if (-not (Test-Path (Join-Path $bootDir 'bootmgfw.efi'))) { throw "Boot manager not found in the image: $bootDir\bootmgfw.efi" }
    # Language resources and fonts for the boot manager's own screens.
    & robocopy.exe $bootDir $efiMs /E /R:0 /W:0 /NP /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying the boot files failed (robocopy $LASTEXITCODE)" }
    foreach ($extra in 'Fonts', 'Resources') {
        $src = Join-Path $mount "Windows\Boot\$extra"
        if (Test-Path $src) {
            & robocopy.exe $src (Join-Path $efiMs $extra) /E /R:0 /W:0 /NP /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Copying the boot $extra failed (robocopy $LASTEXITCODE)" }
        }
    }
    $global:LASTEXITCODE = 0
    # The 2023-signed set sits beside the other one with _EX in each file name
    # (bootmgfw_EX.efi, segoe_slboot_EX.ttf). Lay it over the top, renamed.
    $signedWith = 'the image default'
    if (-not $OlderBootManager) {
        $overlaid = 0
        foreach ($pair in @(@('EFI_EX', $efiMs), @('Fonts_EX', (Join-Path $efiMs 'Fonts')))) {
            $exDir = Join-Path $mount "Windows\Boot\$($pair[0])"
            if (-not (Test-Path $exDir)) { continue }
            foreach ($f in Get-ChildItem $exDir -File) {
                Copy-Item $f.FullName (Join-Path $pair[1] ($f.Name -replace '_EX(?=\.[^.]+$)', '')) -Force
                $overlaid++
            }
        }
        if ($overlaid) { $signedWith = "Windows UEFI CA 2023 ($overlaid files)" }
    }
    Write-Host "Boot manager  : $signedWith"
    # UEFI firmware starts removable media from this fixed path.
    Copy-Item (Join-Path $efiMs 'bootmgfw.efi') (Join-Path $stage 'EFI\Boot\bootx64.efi') -Force
    $sdi = Join-Path $mount 'Windows\Boot\DVD\EFI\boot.sdi'
    if (-not (Test-Path $sdi)) { throw "boot.sdi not found in the image: $sdi" }
    Copy-Item $sdi (Join-Path $re 'boot.sdi') -Force

    Write-Host 'Saving the image'
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    $mounted = $false
}
finally {
    if ($mounted) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null }
}

Move-Item $wim (Join-Path $re 'winre.wim') -Force
Get-ChildItem $efiMs -Filter 'BCD*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force
New-RamdiskBcd -Store (Join-Path $efiMs 'BCD')
# bcdedit leaves the store hidden and system, with log files beside it. Plain
# files copy to a stick without surprises.
Get-ChildItem $efiMs -Filter 'BCD*' -Force | ForEach-Object {
    if ($_.Name -eq 'BCD') { $_.Attributes = 'Normal' } else { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}
Copy-Item $sampleSource (Join-Path $stage 'CloudRebuild\answers.cmd.sample') -Force

$big = Get-ChildItem $stage -Recurse -File | Where-Object Length -ge 4GB
if ($big) { throw "A file is too large for FAT32 (4 GB limit): $($big.FullName -join ', ')" }

if (Test-Path $OutputPath) { Remove-Item $OutputPath -Recurse -Force }
New-Item -ItemType Directory -Path (Split-Path $OutputPath -Parent) -Force | Out-Null
Move-Item $stage $OutputPath
Remove-Item $mount -Recurse -Force -ErrorAction SilentlyContinue

$size = (Get-ChildItem $OutputPath -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host ("USB files: {0}  ({1:N0} MB, WinRE {2})" -f $OutputPath, ($size / 1MB), $reVersion)
Write-Host 'Next:'
Write-Host '  1. Rufus: Boot selection "Non bootable", Partition scheme GPT, File system FAT32, Volume label CRMEDIA.'
Write-Host '  2. Copy the CONTENTS of that folder to the stick.'
Write-Host 'Booting the stick shows a menu. Starting a rebuild from it ERASES the chosen disk.'
