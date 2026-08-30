@echo off
setlocal
set "ROOT=%~dp0"
echo ============================================================
echo RabuShin Discord - Install Dependencies and Build
echo ============================================================

call "%ROOT%CHECK_PREREQUISITES.cmd"
if errorlevel 1 goto :fail

echo.
echo [1/5] Installing Discord OAuth server packages...
pushd "%ROOT%server"
call npm install
if errorlevel 1 goto :fail
popd

echo.
echo [2/5] Installing and validating Discord Activity client...
pushd "%ROOT%client"
call npm install
if errorlevel 1 goto :fail
call npm run build
if errorlevel 1 goto :fail
popd

echo.
echo [3/5] Checking Node OAuth server syntax...
pushd "%ROOT%server"
node --check server.js
if errorlevel 1 goto :fail
popd

echo.
echo [4/5] Building VB.NET RabuShin Core...
pushd "%ROOT%"
dotnet build RabuShinAIGM.Core\RabuShinAIGM.Core.vbproj
if errorlevel 1 goto :fail
popd

echo.
echo [5/5] Building ASP.NET RabuShin Server...
pushd "%ROOT%"
dotnet build RabuShinAIGM.Server\RabuShinAIGM.Server.csproj
if errorlevel 1 goto :fail
popd

echo.
echo ============================================================
echo BUILD SUCCEEDED
echo Next: run SETUP_SERVER_SECRETS.cmd, then START_RABUSHIN.cmd
echo ============================================================
pause
exit /b 0

:fail
echo.
echo ============================================================
echo BUILD FAILED - read the FIRST error shown above.
echo ============================================================
popd 2>nul
pause
exit /b 1
