@echo off
rem Cloud rebuild boot menu. Runs inside WinRE, started by winpeshl.ini when
rem the rebuild media boots. Plain batch on purpose: WinRE has no PowerShell
rem and lacks tools such as findstr, so only cmd built-ins, diskpart, wpeinit
rem and wpeutil are used.
rem
rem It asks for edition, language, version and target disk, writes the intent
rem JSON and runs Rebuild.exe. STARTING A REBUILD ERASES THE TARGET DISK.
rem
rem Optional presets: \CloudRebuild\answers.cmd on the media (label CRMEDIA)
rem may set EDITION, LANG, VERSION, BRANCH, LCU, and AUTO=1 to start without
rem the menu when exactly one target disk is found.
rem SAFETY: never run outside the recovery environment. WinRE always runs from
rem the RAM disk X: and is the only place Rebuild.exe exists. On an installed
rem Windows this script stops here, before it touches anything.
if /i not "%SystemDrive%"=="X:" (
    echo This script only runs inside the Windows Recovery Environment. Nothing was done.
    exit /b 1
)
if not exist X:\Windows\System32\Rebuild.exe (
    echo Rebuild.exe was not found in X:\Windows\System32. Nothing was done.
    exit /b 1
)
setlocal enabledelayedexpansion
title Cloud rebuild

set MEDIALABEL=CRMEDIA
set EDITION=Professional
set LANG=en-US
set VERSION=10.0.26300.9974
set BRANCH=ge_release
set LCU=1.0
set AUTO=0
set TARGETDISK=
set LASTRESULT=
set SKIPARGS=-Skip confirm

echo Starting up...
wpeinit

call :findmedia
if defined MEDIALETTER if exist %MEDIALETTER%:\CloudRebuild\answers.cmd (
    echo Loading presets from the media...
    call %MEDIALETTER%:\CloudRebuild\answers.cmd
)
call :finddisks
if "%DISKCOUNT%"=="1" set TARGETDISK=%ONLYDISK%
if "%AUTO%"=="1" if defined TARGETDISK goto run

:menu
call :finddisks
cls
echo.
echo   ============  Cloud rebuild  ============
echo.
echo   Installs a clean Windows 11 from Windows Update.
echo   Needs a wired network or Wi-Fi with internet access.
echo.
if defined TARGETDISK (
    echo     Target disk : Disk %TARGETDISK%   !DISKSIZE_%TARGETDISK%!
) else (
    echo     Target disk : not chosen - %DISKCOUNT% candidate disk^(s^) found
)
echo.
echo     1. Edition   : %EDITION%
echo     2. Language  : %LANG%
echo     3. Version   : %VERSION%
echo     4. Choose target disk
echo     5. Show disk details
echo     6. LCU version : %LCU%
echo     7. Branch      : %BRANCH%
echo.
echo     P. Preview - shows what Windows Update would install; asks before erasing
echo     S. Start - ERASES the target disk
echo     C. Command prompt      R. Recovery menu      X. Shut down
echo.
if defined LASTRESULT echo   %LASTRESULT%
echo.
set CHOICE=
set /p CHOICE=  Choose:
if "%CHOICE%"=="1" goto edition
if "%CHOICE%"=="2" goto language
if "%CHOICE%"=="3" goto version
if "%CHOICE%"=="4" goto pickdisk
if "%CHOICE%"=="5" goto diskdetails
if "%CHOICE%"=="6" goto lcu
if "%CHOICE%"=="7" goto branch
if /i "%CHOICE%"=="P" goto preview
if /i "%CHOICE%"=="S" goto confirm
if /i "%CHOICE%"=="C" goto shell
if /i "%CHOICE%"=="R" goto recovery
if /i "%CHOICE%"=="X" goto shutdown
goto menu

:edition
echo.
rem The four editions Cloud rebuild delivers as separate images (tested
rem 2026-11-13). Other edition IDs (Enterprise, Education, ...) are accepted
rem but install one of these four, so they are not offered here; they can
rem still be set in answers.cmd. An unknown edition is rejected during the
rem scan (0x8000ffff), before the disk is touched. The order here must match
rem EDLIST below.
echo     1. Professional     Pro
echo     2. Core             Home
echo     3. ProfessionalN    Pro N
echo     4. CoreN            Home N
echo     Enterprise and Education install as Pro; change edition afterwards.
echo     Enter keeps %EDITION%.
set EDLIST=Professional Core ProfessionalN CoreN
set IN=
set /p IN=  Edition (1-4): 
if not defined IN goto menu
set LASTRESULT=Edition not changed: choose a number from 1 to 4.
set N=0
for %%e in (%EDLIST%) do (
    set /a N+=1
    if "!N!"=="!IN!" (
        set EDITION=%%e
        set LASTRESULT=
    )
)
goto menu

:language
echo.
rem Same rule as for editions: tested languages only.
echo     1. en-US           (English, United States)
echo     2. sv-SE           (Swedish)
echo     Enter keeps %LANG%.
set IN=
set /p IN=  Language (1-2):
if not defined IN goto menu
set LASTRESULT=Language not changed: choose 1 or 2.
if "%IN%"=="1" set LANG=en-US
if "%IN%"=="2" set LANG=sv-SE
if "%IN%"=="1" set LASTRESULT=
if "%IN%"=="2" set LASTRESULT=
goto menu

:version
echo.
echo     Full OS version, for example 10.0.26300.9974.
echo     Windows Update must offer it for this edition and language.
echo     Enter keeps %VERSION%.
set IN=
set /p IN=  Version:
if not defined IN goto menu
rem Expect 10.0.<5-digit build>.<revision>, digits only. A typo here makes
rem Windows Update refuse the request (0xC1900500) after a long wait.
set VOK=1
set V1=
set V2=
set V3=
set V4=
set V5=
for /f "tokens=1-5 delims=." %%a in ("%IN%") do (
    set "V1=%%a"
    set "V2=%%b"
    set "V3=%%c"
    set "V4=%%d"
    set "V5=%%e"
)
if not "%V1%"=="10" set VOK=
if not "%V2%"=="0" set VOK=
if not defined V3 set VOK=
if not defined V4 set VOK=
if defined V5 set VOK=
if defined V3 if "!V3:~4,1!"=="" set VOK=
if defined V3 if not "!V3:~5,1!"=="" set VOK=
for /f "delims=0123456789" %%x in ("%V3%%V4%") do set VOK=
if defined VOK (
    set VERSION=%IN%
    set LASTRESULT=
) else (
    set LASTRESULT=Version not changed: "%IN%" is not in the form 10.0.26300.9974
)
goto menu

:lcu
echo.
echo     LCU version. Microsoft's example is 1.0; its exact meaning is not known.
echo     Enter keeps %LCU%.
set IN=
set /p IN=  LCU version:
if defined IN set LCU=%IN%
goto menu

:branch
echo.
echo     Build branch, for example ge_release. Enter keeps %BRANCH%.
set IN=
set /p IN=  Branch:
if defined IN set BRANCH=%IN%
goto menu

:preview
rem Runs the rebuild WITHOUT "-Skip confirm". Rebuild.exe then asks how to
rem remove files, shows the build, edition and language Windows Update offers,
rem and asks for confirmation before it erases anything. Cancel on any of
rem those pages returns here with the disk untouched.
if not defined TARGETDISK (
    set LASTRESULT=Choose a target disk first.
    goto menu
)
echo.
echo   Preview: Cloud rebuild will show what it would install.
echo   Choose "Remove files", read the summary page, then press Cancel.
echo   Pressing Continue and then "Erase and install" WILL erase Disk %TARGETDISK%.
echo.
pause
set SKIPARGS=
goto run

:pickdisk
echo.
echo     Candidate disks (the rebuild media itself is not listed):
for %%d in (%DISKLIST%) do echo       Disk %%d   !DISKSIZE_%%d!
set IN=
set /p IN=  Disk number:
for %%d in (%DISKLIST%) do if "%%d"=="%IN%" set TARGETDISK=%%d
goto menu

:diskdetails
echo.
for %%d in (%DISKLIST%) do (
    > X:\cr-dd.txt echo select disk %%d
    >> X:\cr-dd.txt echo detail disk
    diskpart /s X:\cr-dd.txt
)
pause
goto menu

:confirm
if not defined TARGETDISK (
    set LASTRESULT=Choose a target disk first.
    goto menu
)
echo.
echo   About to install:
echo     Windows 11 %EDITION%, %LANG%, version %VERSION%
echo   on Disk %TARGETDISK%   !DISKSIZE_%TARGETDISK%!
echo.
echo   EVERYTHING on Disk %TARGETDISK% will be erased. This cannot be undone.
echo.
set CONFIRM=
set /p CONFIRM=  Type ERASE to continue, anything else to go back:
if not "%CONFIRM%"=="ERASE" (
    set LASTRESULT=Cancelled. Nothing was changed.
    goto menu
)
set SKIPARGS=-Skip confirm

:run
call :writeintent
rem This console stays on top of the recovery screen. Some Cloud rebuild pages
rem (its error page in particular) open BEHIND it, which looks like a hang. So
rem shrink the console to a few lines while Rebuild.exe runs.
mode con: cols=70 lines=6
echo  Cloud rebuild is running. Its pages appear behind this window.
echo  If you see nothing, click the blue background or press Alt+Tab.
rem Rebuild.exe is a GUI program: "start /wait" is what makes cmd wait for it
rem and see its exit code. It does not restart the PC itself when it is done.
rem SKIPARGS is "-Skip confirm" for Start and AUTO, empty for Preview.
start "" /wait X:\Windows\System32\Rebuild.exe -UseJson -filepath X:\RebuildIntent.json %SKIPARGS%
set RC=%ERRORLEVEL%
mode con: cols=100 lines=40
call :savelogs
if "%RC%"=="0" (
    echo   Done. Restarting into the new Windows. Remove the rebuild media.
    wpeutil reboot
    goto :eof
)
set AUTO=0
set LASTRESULT=Rebuild ended without installing, exit code %RC%. Log: X:\Windows\Logs\Rebuild\setupact.log
goto menu

:shell
echo.
echo   Type EXIT to return to the menu.
cmd /k
goto menu

:recovery
rem Leaving this script lets winpeshl start the normal recovery environment.
endlocal
exit

:shutdown
wpeutil shutdown
goto :eof

rem ---------------------------------------------------------------------------
:writeintent
rem One line, no BOM. The unattend uses single-quoted XML attributes so the
rem JSON string needs no escaped quotes; every ^< and ^> sits inside a quoted
rem JSON string, where cmd treats it literally.
>X:\RebuildIntent.json echo {"SchemaVersion":"1.0","Composition":{"BuildBranch":"%BRANCH%","Version":"%VERSION%","EditionID":"%EDITION%","InstallationType":"Client","SystemLanguage":"%LANG%","LCUVersion":"%LCU%"},"Unattend":"<?xml version='1.0' encoding='utf-8'?><unattend xmlns='urn:schemas-microsoft-com:unattend'><settings pass='windowsPE'><component name='Microsoft-Windows-Setup' processorArchitecture='AMD64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS' xmlns:wcm='http://schemas.microsoft.com/WMIConfig/2002/State' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'><StorageConfiguration><DiskID>%TARGETDISK%</DiskID></StorageConfiguration><ImageInstall><OSImage><InstallTo><DiskID>%TARGETDISK%</DiskID><PartitionSpec>Available</PartitionSpec></InstallTo></OSImage></ImageInstall></component></settings></unattend>"}
goto :eof

rem ---------------------------------------------------------------------------
:findmedia
rem Finds the volume labelled %MEDIALABEL% (the rebuild media), gives it a
rem letter if it has none, and works out which disk it is on so that disk is
rem never offered as a target.
set MEDIAVOL=
set MEDIALETTER=
set MEDIADISK=
> X:\cr-lv.txt echo list volume
rem A volume line is "Volume N [Ltr] Label ...": the label is the 3rd word, or
rem the 4th when the volume has a letter.
for /f "tokens=1-4" %%a in ('diskpart /s X:\cr-lv.txt') do (
    if /i "%%a"=="Volume" if /i "%%c"=="%MEDIALABEL%" set "MEDIAVOL=%%b"
    if /i "%%a"=="Volume" if /i "%%d"=="%MEDIALABEL%" (
        set "MEDIAVOL=%%b"
        set "MEDIALETTER=%%c"
    )
)
if not defined MEDIAVOL goto :eof
> X:\cr-dv.txt echo select volume %MEDIAVOL%
if not defined MEDIALETTER >> X:\cr-dv.txt echo assign letter=M
>> X:\cr-dv.txt echo detail volume
rem "detail volume" lists the disk(s) holding the volume as "* Disk N" or "Disk N".
for /f "tokens=1-3" %%a in ('diskpart /s X:\cr-dv.txt') do (
    if "%%a"=="*" if /i "%%b"=="Disk" set "MEDIADISK=%%c"
    if /i "%%a"=="Disk" if not "%%b"=="###" set "MEDIADISK=%%b"
)
if not defined MEDIALETTER set MEDIALETTER=M
if not exist %MEDIALETTER%:\ set MEDIALETTER=
goto :eof

rem ---------------------------------------------------------------------------
:finddisks
rem Candidate target disks: every disk with media in it except the rebuild
rem media. A "list disk" line is "Disk N Status Size Unit ...".
set DISKCOUNT=0
set DISKLIST=
set ONLYDISK=
> X:\cr-ld.txt echo list disk
for /f "tokens=1-5" %%a in ('diskpart /s X:\cr-ld.txt') do (
    if /i "%%a"=="Disk" if not "%%b"=="###" if not "%%b"=="%MEDIADISK%" if /i not "%%c"=="No" (
        set /a DISKCOUNT+=1
        set "DISKLIST=!DISKLIST! %%b"
        set "ONLYDISK=%%b"
        set "DISKSIZE_%%b=%%d %%e"
    )
)
rem Drop a remembered target that is no longer present.
set FOUND=
for %%d in (%DISKLIST%) do if "%%d"=="%TARGETDISK%" set FOUND=1
if not defined FOUND set TARGETDISK=
goto :eof

rem ---------------------------------------------------------------------------
:savelogs
rem X: is a RAM disk. Keep the rebuild logs on the media when it is writable.
if not defined MEDIALETTER goto :eof
set LOGDIR=%MEDIALETTER%:\CloudRebuild\Logs
if not exist %LOGDIR% mkdir %LOGDIR% 2>nul
if not exist %LOGDIR% goto :eof
for %%s in ("Windows\Logs\Rebuild" "Windows\Logs\MoSetup" "$Windows.~BT\Sources\Panther") do (
    if exist "X:\%%~s" (
        mkdir "%LOGDIR%\%%~nxs" 2>nul
        copy /y "X:\%%~s\*.*" "%LOGDIR%\%%~nxs\" >nul 2>nul
    )
)
> %LOGDIR%\last-exitcode.txt echo %RC%
goto :eof
