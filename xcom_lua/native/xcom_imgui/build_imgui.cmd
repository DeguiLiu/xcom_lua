@echo off
call "D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "PATH=D:\Python314\Scripts;D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
cd /d D:\workspace\SSCOM_lua\xcom_lua\native\xcom_imgui
cmake -S . -B build -G "Ninja" -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 (echo CONFIGURE_FAILED & exit /b 1)
cmake --build build --target xcom_imgui 2>&1
if errorlevel 1 (echo BUILD_FAILED & exit /b 1)
echo BUILD_OK
