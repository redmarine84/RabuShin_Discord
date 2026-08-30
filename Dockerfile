# ============================================================
# RabuShinAIGM Discord Activity - Production Container
# Builds the Vite client and ASP.NET/VB.NET server into ONE app.
# ============================================================

FROM node:22-alpine AS client-build
WORKDIR /src/client

COPY client/package*.json ./
RUN npm ci
COPY client/ ./

# These values are PUBLIC and are intentionally compiled into the browser app.
# Never add Discord Client Secret, Supabase Secret Key, or encryption keys here.
ARG VITE_DISCORD_CLIENT_ID
ARG VITE_PUBLIC_SITE_BASE_URL
ENV VITE_DISCORD_CLIENT_ID=${VITE_DISCORD_CLIENT_ID}
ENV VITE_PUBLIC_SITE_BASE_URL=${VITE_PUBLIC_SITE_BASE_URL}

RUN npm run build


FROM mcr.microsoft.com/dotnet/sdk:8.0 AS server-build
WORKDIR /src

COPY RabuShinAIGM.Core/ ./RabuShinAIGM.Core/
COPY RabuShinAIGM.Server/ ./RabuShinAIGM.Server/

RUN dotnet restore RabuShinAIGM.Server/RabuShinAIGM.Server.csproj
RUN dotnet publish RabuShinAIGM.Server/RabuShinAIGM.Server.csproj \
    -c Release \
    -o /app/publish \
    --no-restore

COPY --from=client-build /src/client/dist/ /app/publish/wwwroot/


FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=server-build /app/publish/ ./

ENV ASPNETCORE_ENVIRONMENT=Production
ENV DOTNET_ENVIRONMENT=Production
ENV ASPNETCORE_URLS=http://0.0.0.0:10000

EXPOSE 10000
ENTRYPOINT ["dotnet", "RabuShinAIGM.Server.dll"]
