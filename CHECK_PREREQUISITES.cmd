@echo off
setlocal
echo ============================================================
echo RabuShin Discord - Prerequisite Check
echo ============================================================
set "FAILED=0"

where node >nul 2>nul
if errorlevel 1 (
  echo [MISSING] Node.js / node
  set "FAILED=1"
) else (
  for /f "delims=" %%v in ('node --version') do echo [OK] Node.js %%v
)

where npm >nul 2>nul
if errorlevel 1 (
  echo [MISSING] npm
  set "FAILED=1"
) else (
  for /f "delims=" %%v in ('npm --version') do echo [OK] npm %%v
)

where dotnet >nul 2>nul
if errorlevel 1 (
  echo [MISSING] .NET 8 SDK / dotnet
  set "FAILED=1"
) else (
  for /f "delims=" %%v in ('dotnet --version') do echo [OK] dotnet SDK %%v
)

where cloudflared >nul 2>nul
if errorlevel 1 (
  echo [MISSING] cloudflared
  set "FAILED=1"
) else (
  echo [OK] cloudflared
)

echo.
if "%FAILED%"=="1" (
  echo One or more prerequisites are missing.
  echo See README_FIRST.md before continuing.
  exit /b 1
)

echo All required command-line prerequisites were found.
exit /b 0
