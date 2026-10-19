@echo off
setlocal EnableExtensions
if "%~1"=="" (
  echo usage: enter-maskrom.bat ^<board^>
  echo example: enter-maskrom.bat noesis-rk3588
  exit /b 1
)
set "BOARD=%~1"
if "%EADK_GATEWAY%"=="" set "EADK_GATEWAY=http://127.0.0.1:18081"
set "RELAY=%EADK_GATEWAY%/relay"
set "SSH=%EADK_GATEWAY%/sshbridge"
set "KEYS=%TEMP%\rk-maskrom-keys.json"
set "CMD=%TEMP%\rk-maskrom-cmd.json"

powershell -NoProfile -Command "$b='%BOARD%'; @{board=$b;char=([char]60+'ctrl+c'+[char]62);duration=7;interval=0.1} | ConvertTo-Json -Compress | Set-Content -LiteralPath '%KEYS%' -Encoding ascii"
>"%CMD%" echo {"board":"%BOARD%","command":"mmc dev 0;mmc erase 0 2048"}

echo [1/4] reset %BOARD% via %RELAY%
curl.exe -sS -f "%RELAY%/api/boards/%BOARD%/action?action=reset"
if errorlevel 1 exit /b 1
echo.

echo [2/4] send Ctrl+C via %SSH%
curl.exe -sS -f -X POST -H "Content-Type: application/json" --data-binary "@%KEYS%" "%SSH%/send_keys"
if errorlevel 1 exit /b 1
echo.

echo [3/4] erase eMMC boot
curl.exe -sS -f -X POST -H "Content-Type: application/json" --data-binary "@%CMD%" "%SSH%/command"
if errorlevel 1 exit /b 1
echo.

timeout /t 1 /nobreak >nul
echo [4/4] reset %BOARD%
curl.exe -sS -f "%RELAY%/api/boards/%BOARD%/action?action=reset"
if errorlevel 1 exit /b 1
echo.
echo done. board should enter Maskrom.
exit /b 0
