@echo off
:: Firestick Cleanup - Windows entry point.
:: All logic lives in Firestick-Cleaner-And-Launcher-Replacer.ps1 next to this file;
:: this wrapper only starts it so the tool can be double-clicked. Any arguments
:: are passed through, e.g.:  Firestick-Cleaner-And-Launcher-Replacer.bat --revert
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Firestick-Cleaner-And-Launcher-Replacer.ps1" %*
if errorlevel 2 pause
