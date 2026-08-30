@echo off
setlocal
set "ROOT=%~dp0"

echo Starting RabuShin Discord Activity services...
start "RabuShin - Discord OAuth" cmd /k "pushd ""%ROOT%server"" && npm start"
start "RabuShin - ASP.NET Game Server" cmd /k "pushd ""%ROOT%"" && dotnet run --project RabuShinAIGM.Server\RabuShinAIGM.Server.csproj"
start "RabuShin - Vite Client" cmd /k "pushd ""%ROOT%client"" && npm run dev"
timeout /t 3 /nobreak >nul
start "RabuShin - Cloudflare Tunnel" cmd /k "cloudflared tunnel --url http://localhost:5173"

echo.
echo Four windows were opened.
echo In the Cloudflare window, copy the NEW trycloudflare.com hostname.
echo If the hostname changed, update Discord Developer Portal ^> Activities ^> URL Mappings.
echo.
pause
