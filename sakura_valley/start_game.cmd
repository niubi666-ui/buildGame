@echo off
setlocal
rem Set GODOT_EXE to a full path to use a different Godot installation.
set "engine=Godot_v4.7.2-stable_win64"
for %%G in ("E:\GoDot\%engine%.exe" "E:\GoDot\%engine%\%engine%.exe") do (
	if not defined GODOT_EXE if exist "%%~G" set "GODOT_EXE=%%~G"
)
for %%G in (%engine%.exe godot.exe) do (
	if not defined GODOT_EXE set "GODOT_EXE=%%~$PATH:G"
)

if not exist "%GODOT_EXE%" (
	echo Godot 4.7.2 could not be found. Set GODOT_EXE to its full executable path.
	pause
	exit /b 1
)

start "" "%GODOT_EXE%" --path "%~dp0." %*
