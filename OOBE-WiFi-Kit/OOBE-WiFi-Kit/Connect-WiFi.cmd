@echo off
REM ============================================================================
REM  Connect-WiFi.cmd -   run at Windows OOBE via Shift+F10
REM
REM  Usage at the OOBE region/keyboard screen:
REM     1. Press Shift+F10 to open a command prompt
REM     2. Type the USB drive letter, e.g.:   D:
REM        (if unsure, run:  wmic logicaldisk get name,volumename )
REM     3. Run:   Connect-WiFi.cmd
REM
REM  %~dp0 resolves to THIS script's own folder, so the drive letter is
REM  auto-detected once you launch it -  no editing required.
REM ============================================================================

echo.
echo  === OOBE Wi-Fi Connector ===
echo  Kit location: %~dp0
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Connect-WiFi.ps1"

echo.
echo  If State shows 'connected', close this window and continue OOBE.
echo  The network page (if shown) should now say you're connected.
echo.
pause
