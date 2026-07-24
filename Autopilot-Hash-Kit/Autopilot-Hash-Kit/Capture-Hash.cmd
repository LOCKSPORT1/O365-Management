@echo off
REM ============================================================================
REM  Capture-Hash.cmd  —  run at Windows OOBE via Shift+F10
REM
REM  Captures this device's Autopilot hardware hash and appends it to
REM  AutopilotHWID.csv on this USB stick (offline mode — default).
REM
REM  Usage at the OOBE region/keyboard screen:
REM     1. Shift+F10 to open a command prompt
REM     2. Type the stick's drive letter, e.g.:   D:
REM     3. Run:   Capture-Hash.cmd
REM
REM  For direct-to-Intune upload instead of CSV (needs network + an Intune
REM  admin sign-in), run:   Capture-Hash.cmd online
REM ============================================================================

echo.
echo  === Autopilot Hash Capture ===
echo  Kit location: %~dp0
echo.

if /I "%~1"=="online" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Capture-Hash.ps1" -Online
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Capture-Hash.ps1"
)

echo.
pause
