@echo off
rem Builds bin\pathcore.dll with Visual Studio's C++ compiler. Close the game first, as it locks the DLL.
setlocal
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS (
	echo Visual Studio with C++ tools was not found.
	exit /b 1
)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1 || exit /b 1
cd /d "%~dp0"
if not exist build mkdir build
if not exist ..\bin mkdir ..\bin
cl /nologo /std:c++17 /O2 /EHsc /MT /W3 /LD /utf-8 path_core.cpp binding.cpp /Fo:build\ /Fe:..\bin\pathcore.dll /link /IMPLIB:build\pathcore.lib
exit /b %errorlevel%
