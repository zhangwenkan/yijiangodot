@echo off
setlocal
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\launch_godot_world.ps1" -Inspect %*
set "WORLD_EXIT=%ERRORLEVEL%"
for %%A in (%*) do if /I "%%~A"=="-NoPause" goto finish
pause
:finish
exit /b %WORLD_EXIT%
