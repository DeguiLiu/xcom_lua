@echo off
rem run_xcom_lua.cmd - run the LuaJIT serial client against the compiled DLL.
rem
rem Keep luvjit.exe beside luv.dll.  This launcher embeds the matching LuaJIT
rem runtime used when luv.dll was built; the standalone luajit.exe is not ABI
rem compatible with that static luv build.

setlocal
set ROOT=D:\workspace\SSCOM_lua
set APP=%ROOT%\xcom_lua
rem luv.dll is built against the bundled luvjit.exe; the older luajit.exe
rem has a different LuaJIT ABI and crashes while loading it.
set RUNTIME=%APP%\runtime
set LUAJIT=%RUNTIME%\luvjit.exe
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
