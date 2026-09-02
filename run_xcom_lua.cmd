@echo off
rem run_xcom_lua.cmd - run the LuaJIT serial client against the compiled DLL.
rem
rem The launcher (xcom.exe) spawns luajit.exe from runtime/.  Pure LuaJIT is
rem enough now that luv (libuv) was removed from the project.

setlocal
set ROOT=D:\workspace\SSCOM_lua
set APP=%ROOT%\xcom_lua
set RUNTIME=%APP%\runtime
set LUAJIT=%RUNTIME%\luajit.exe
set DLL=%ROOT%\build\native-release\bin\xcom_core.dll

if not exist "%DLL%" set DLL=%RUNTIME%\xcom_core.dll

if not exist "%LUAJIT%" (
    echo [run] luajit.exe not found at %LUAJIT%
    exit /b 1
)
if not exist "%DLL%" (
    echo [run] xcom_core.dll not found at %DLL%
    exit /b 1
)

rem Run from the app dir so main.lua's package.path (relative) and config.ini resolve.
cd /d "%APP%"
set XCOM_CORE_DLL=%DLL%

echo [run] launching %LUAJIT% main.lua ...
"%LUAJIT%" main.lua
set RC=%ERRORLEVEL%
echo [run] luajit exited with code %RC%
exit /b %RC%
