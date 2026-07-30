@echo off
setlocal enabledelayedexpansion

set CONFIG_FILE=%USERPROFILE%\.ssh\quick_ssh.conf

if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
if not exist "%CONFIG_FILE%" type nul > "%CONFIG_FILE%"

:MENU
cls
set HAS_CONNECTIONS=0
for /f "tokens=*" %%a in (%CONFIG_FILE%) do set HAS_CONNECTIONS=1

echo Saved connections:
echo.
if %HAS_CONNECTIONS%==1 (
    for /f "tokens=1,2 delims==" %%a in (%CONFIG_FILE%) do (
        echo   [%%a] %%b
    )
) else (
    echo   (none)
)
echo.
echo   [a] Add connection
echo   [d] Delete connection
echo   [q] Quit
echo.
set /p CHOICE="Enter choice: "

if /i "%CHOICE%"=="a" goto ADD_NEW
if /i "%CHOICE%"=="d" goto DELETE
if /i "%CHOICE%"=="q" goto END

REM Try to connect
set FOUND=0
for /f "tokens=1,2 delims==" %%a in (%CONFIG_FILE%) do (
    if "%%a"=="%CHOICE%" (
        set FOUND=1
        echo Connecting to %%b...
        ssh %%b
        goto END
    )
)

if %FOUND%==0 (
    echo Invalid choice: %CHOICE%
    pause
    goto MENU
)

:ADD_NEW
echo.
echo === Add New Connection ===
echo.
set FULL_IP=
set REMOTE_USER=
set /p FULL_IP="Enter full IP (e.g., 192.168.0.22): "
set /p REMOTE_USER="Enter username: "

if "%FULL_IP%"=="" (
    echo No IP entered.
    pause
    goto MENU
)
if "%REMOTE_USER%"=="" (
    echo No username entered.
    pause
    goto MENU
)

REM Try to extract 4th octet for IPv4 addresses, otherwise use hostname as shortcut
set LAST_NUM=
for /f "tokens=4 delims=." %%a in ("%FULL_IP%") do set LAST_NUM=%%a
if "%LAST_NUM%"=="" (
    REM Not an IPv4 address - use the hostname itself as shortcut
    set LAST_NUM=%FULL_IP%
)

echo.
echo Will save as [%LAST_NUM%] for %REMOTE_USER%@%FULL_IP%
echo.

if not exist "%USERPROFILE%\.ssh\id_ed25519" (
    echo Generating SSH key...
    ssh-keygen -t ed25519 -f "%USERPROFILE%\.ssh\id_ed25519" -N ""
    echo.
)

set PUBKEY=
for /f "usebackq delims=" %%k in ("%USERPROFILE%\.ssh\id_ed25519.pub") do set PUBKEY=%%k

echo Setting up passwordless SSH... (enter password one last time)
echo.
ssh %REMOTE_USER%@%FULL_IP% "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%%s\n' '%PUBKEY%' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

if %errorlevel% neq 0 (
    echo.
    echo Failed to install key. Check your credentials.
    pause
    goto MENU
)

echo.
echo Verifying passwordless login...
ssh -o BatchMode=yes -o ConnectTimeout=10 %REMOTE_USER%@%FULL_IP% "true"

if %errorlevel% equ 0 (
    echo %LAST_NUM%=%REMOTE_USER%@%FULL_IP%>>"%CONFIG_FILE%"
    echo.
    echo Saved^^! Use [%LAST_NUM%] to connect next time.
    echo.
    set /p CONNECT_NOW="Connect now? (y/n): "
    if /i "!CONNECT_NOW!"=="y" ssh %REMOTE_USER%@%FULL_IP%
) else (
    echo.
    echo Key was installed but passwordless login still failed.
    echo Check permissions on the remote ~/.ssh, or the server's sshd config.
    pause
    goto MENU
)
goto END

:DELETE
echo.
echo === Delete Connection ===
echo.
if %HAS_CONNECTIONS%==0 (
    echo No connections to delete.
    pause
    goto MENU
)
for /f "tokens=1,2 delims==" %%a in (%CONFIG_FILE%) do (
    echo   [%%a] %%b
)
echo.
set /p DEL_CHOICE="Enter number to delete (or Enter to cancel): "

if "!DEL_CHOICE!"=="" goto MENU

set DELETED=0
set TEMP_FILE=%TEMP%\quick_ssh_tmp.conf
if exist "%TEMP_FILE%" del "%TEMP_FILE%"

for /f "tokens=1,2 delims==" %%a in (%CONFIG_FILE%) do (
    if "%%a"=="!DEL_CHOICE!" (
        set DELETED=1
        echo Deleted [%%a] %%b
    ) else (
        echo %%a=%%b>>"%TEMP_FILE%"
    )
)

if !DELETED!==1 (
    if exist "%TEMP_FILE%" (
        copy /y "%TEMP_FILE%" "%CONFIG_FILE%" >nul
    ) else (
        type nul > "%CONFIG_FILE%"
    )
    echo Done.
) else (
    echo [!DEL_CHOICE!] not found.
)
pause
goto MENU

:END
endlocal
