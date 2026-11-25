@echo off
setlocal
chcp 65001 >nul
start "" "%~dp0tools\godot\Godot_v4.7.2-stable_win64.exe" --editor --path "%~dp0project"
