@echo off
setlocal
cd /d "%~dp0\.."
if not exist output mkdir output
set "PATH=C:\msys64\mingw64\bin;%PATH%"
gcc -O2 -s -o output\eadk-rk-flash.exe eadk\launcher.c
if errorlevel 1 exit /b 1
echo [OK] output\eadk-rk-flash.exe
exit /b 0
