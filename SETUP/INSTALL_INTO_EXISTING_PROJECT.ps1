param(
    [string]$Target = 'C:\Users\redhe\source\repos\RabuShinAIGM_Discord\RabuShinDiscord'
)

$ErrorActionPreference = 'Stop'
$PackageRoot = Split-Path -Parent $PSScriptRoot

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' RabuShin Discord Completion Package Installer' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "Package: $PackageRoot"
Write-Host "Target : $Target"
Write-Host

if (-not (Test-Path $Target)) {
    throw "Target folder does not exist: $Target"
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $Target "_backup_before_completion_$stamp"
New-Item -ItemType Directory -Path $backup -Force | Out-Null

$folders = @('client','server','RabuShinAIGM.Core','RabuShinAIGM.Server')
foreach ($folder in $folders) {
    $existing = Join-Path $Target $folder
    if (Test-Path $existing) {
        Write-Host "Backing up $folder..." -ForegroundColor Yellow
        Copy-Item $existing (Join-Path $backup $folder) -Recurse -Force
    }
}

foreach ($folder in $folders) {
    $source = Join-Path $PackageRoot $folder
    $dest = Join-Path $Target $folder
    Write-Host "Installing $folder..." -ForegroundColor Green
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item (Join-Path $source '*') $dest -Recurse -Force
}

foreach ($folder in @('SUPABASE_SQL','SETUP')) {
    $source = Join-Path $PackageRoot $folder
    $dest = Join-Path $Target $folder
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item (Join-Path $source '*') $dest -Recurse -Force
}

foreach ($file in @('BUILD_ALL.cmd','START_RABUSHIN.cmd','SETUP_SERVER_SECRETS.cmd','.gitignore.additions','README_FIRST.md','CHECK_PREREQUISITES.cmd','PACKAGE_MANIFEST.txt')) {
    $source = Join-Path $PackageRoot $file
    if (Test-Path $source) { Copy-Item $source (Join-Path $Target $file) -Force }
}

$targetEnv = Join-Path $Target '.env'
if (-not (Test-Path $targetEnv)) {
    Copy-Item (Join-Path $PackageRoot '.env.example') $targetEnv -Force
    Write-Host 'Created .env from .env.example. You must insert your Discord Client Secret.' -ForegroundColor Yellow
} else {
    Write-Host 'Existing .env preserved.' -ForegroundColor Green
}

Write-Host
Write-Host 'Installation files copied successfully.' -ForegroundColor Green
Write-Host "Backup created at: $backup" -ForegroundColor Yellow
Write-Host
Write-Host 'NEXT STEPS:' -ForegroundColor Cyan
Write-Host '1. Run SUPABASE_SQL\01_DISCORD_FULL_SETUP.sql in Supabase SQL Editor.'
Write-Host '2. Run SETUP_SERVER_SECRETS.cmd.'
Write-Host '3. Run BUILD_ALL.cmd.'
Write-Host '4. Run START_RABUSHIN.cmd.'
