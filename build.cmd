@echo off
rem build.cmd - build xcom_core.dll (v1.3) with MSVC + Ninja on Windows.
rem
rem Usage (from repo root):  build.cmd  [release|debug]
rem
rem Calls vcvars64.bat to set the MSVC/Windows SDK environment, then uses the
rem CMake preset (CMakePresets.json) to configure + build.  The output DLL lands
rem at build/native-release/bin/xcom_core.dll (Release) or
rem build/native-debug/bin/xcom_core.dll (Debug).

setlocal
set CONFIG=%1
if "%CONFIG%"=="" set CONFIG=release

rem Locate the Visual Studio Build Tools environment (adjust if installed
rem elsewhere; this matches D:\BuildTools).
set VC_BAT=D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat
if not exist "%VC_BAT%" (
    echo [build] vcvars64.bat not found at %VC_BAT%
    exit /b 1
)

rem MSVC + Windows SDK env (INCLUDE/LIB/PATH).  Redirect so the banner is quiet.
call "%VC_BAT%" >nul 2>&1
if errorlevel 1 (
    echo [build] vcvars64.bat failed
    exit /b 1
)

rem Use the Windows-native cmake + ninja installed via pip (D:\Python314\Scripts),
rem NOT the MSYS2 /usr/bin/cmake which emits POSIX paths and breaks the MSVC
rem compiler ABI probe.  Prepend so they shadow any MSYS2 cmake on PATH.
set "PY_SCRIPTS=D:\Python314\Scripts"
set "NINJA_DIR=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
set "PATH=%PY_SCRIPTS%;%NINJA_DIR%;%PATH%"

if /i "%CONFIG%"=="release" (
    set PRESET=native-release
) else (
    set PRESET=native-debug
)

echo [build] configuring preset %PRESET% ...
cmake --preset %PRESET%
if errorlevel 1 (
    echo [build] cmake configure failed
    exit /b 1
)

echo [build] building ...
cmake --build --preset build-%PRESET%
if errorlevel 1 (
    echo [build] build failed
    exit /b 1
)

echo [build] done.
exit /b 0
