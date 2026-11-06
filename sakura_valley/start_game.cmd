@echo off
rem Double-click to start the Sakura Valley test scene.
set "GODOT=E:\GoDot\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64.exe"

if not exist "%GODOT%" (
	echo Godot was not found at:
	echo %GODOT%
	echo Edit the GODOT line in this file to point to your Godot exe.
	pause
	exit /b 1
)

start "" "%GODOT%" --path "%~dp0."
