@echo off
setlocal

echo ============================================================
echo  RabuShin Discord - Server Secrets Setup
echo ============================================================
echo.

set "SCRIPT=%~dp0SETUP\SET_SERVER_SECRETS.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SCRIPT%" (
    echo ERROR: Could not find:
    echo %SCRIPT%
    echo.
    echo Make sure the SETUP folder is beside this CMD file.
    echo.
    pause
    exit /b 1
)

if not exist "%POWERSHELL%" (
    echo ERROR: Windows PowerShell could not be found at:
    echo %POWERSHELL%
    echo.
    pause
    exit /b 1
)

"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
    echo ============================================================
    echo  SERVER SECRETS SETUP COMPLETED SUCCESSFULLY
    echo ============================================================
) else (
    echo ============================================================
    echo  SERVER SECRETS SETUP FAILED - Error Code %EXITCODE%
    echo ============================================================
    echo.
    echo The actual PowerShell error should be shown above.
)

echo.
pause
exit /b %EXITCODE%
