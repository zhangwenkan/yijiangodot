@echo off
setlocal
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
chcp 65001 >nul
title Godot - Youxian Village
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\launch_godot_world.ps1" -Map youxian %*
set "WORLD_EXIT=%ERRORLEVEL%"
echo.
echo Launcher exit code: %WORLD_EXIT%
echo Launch logs: artifacts\wandering-original-worlds-review\launch-logs
echo The game runs in a separate window. This window retains the launch status.
for %%A in (%*) do if /I "%%~A"=="-NoPause" goto finish
pause
:finish
exit /b %WORLD_EXIT%
