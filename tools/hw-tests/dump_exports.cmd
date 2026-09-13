@echo off
call "D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
dumpbin /exports %1
