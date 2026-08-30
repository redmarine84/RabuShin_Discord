param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' RabuShin Discord - Server Secrets Setup' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host

$serverPath = Join-Path $Root 'RabuShinAIGM.Server'
$projectFile = Join-Path $serverPath 'RabuShinAIGM.Server.csproj'

if (-not (Test-Path $serverPath)) {
    throw "Server folder not found: $serverPath"
}

if (-not (Test-Path $projectFile)) {
    throw "Server project not found: $projectFile"
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnet) {
    throw '.NET SDK was not found. Install the .NET 8 SDK, then run this setup again.'
}

Write-Host "Server project: $projectFile" -ForegroundColor DarkGray
Write-Host "dotnet: $($dotnet.Source)" -ForegroundColor DarkGray
Write-Host

try {
    $version = (& dotnet --version).Trim()
    Write-Host ".NET SDK version: $version" -ForegroundColor Green
}
catch {
    throw "dotnet is installed but could not be executed: $($_.Exception.Message)"
}

# The project package contains a fixed UserSecretsId.
# Using --project means this works regardless of the current directory.
$supabaseUrl = 'https://yrysfedvqtwvqxmlxymg.supabase.co'

Write-Host
Write-Host 'Saving Supabase URL...' -ForegroundColor Cyan
& dotnet user-secrets set 'Supabase:Url' $supabaseUrl --project $projectFile
if ($LASTEXITCODE -ne 0) {
    throw "dotnet user-secrets failed while saving Supabase:Url. Exit code: $LASTEXITCODE"
}
Write-Host "Supabase URL set to $supabaseUrl" -ForegroundColor Green

Write-Host
$secure = Read-Host 'Paste your Supabase sb_secret_... key' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $supabaseSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}

if ([string]::IsNullOrWhiteSpace($supabaseSecret)) {
    throw 'Supabase Secret Key cannot be blank.'
}

if (-not $supabaseSecret.StartsWith('sb_secret_')) {
    Write-Host 'WARNING: The key does not begin with sb_secret_.' -ForegroundColor Yellow
    Write-Host 'Make sure you are using the Supabase server Secret Key, not the publishable key.' -ForegroundColor Yellow
}

& dotnet user-secrets set 'Supabase:SecretKey' $supabaseSecret --project $projectFile
$supabaseSecret = $null

if ($LASTEXITCODE -ne 0) {
    throw "dotnet user-secrets failed while saving Supabase:SecretKey. Exit code: $LASTEXITCODE"
}

Write-Host 'Supabase Secret Key saved to .NET User Secrets.' -ForegroundColor Green

Write-Host
$choice = Read-Host 'Do you want ONE permanent server-side OpenAI API key for RabuShin? (Y/N)'

if ($choice -match '^[Yy]') {
    Write-Host
    $secureOpenAi = Read-Host 'Paste your OpenAI API key' -AsSecureString
    $ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureOpenAi)

    try {
        $openAiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2)
    }

    if ([string]::IsNullOrWhiteSpace($openAiKey)) {
        Write-Host 'No OpenAI key entered. Skipping permanent OpenAI setup.' -ForegroundColor Yellow
    }
    else {
        & dotnet user-secrets set 'OpenAI:ApiKey' $openAiKey --project $projectFile
        $openAiKey = $null

        if ($LASTEXITCODE -ne 0) {
            throw "dotnet user-secrets failed while saving OpenAI:ApiKey. Exit code: $LASTEXITCODE"
        }

        Write-Host 'OpenAI API key saved server-side.' -ForegroundColor Green
    }
}
else {
    Write-Host 'No permanent OpenAI key saved.' -ForegroundColor Yellow
    Write-Host 'You can configure the API key later.' -ForegroundColor Yellow
}

Write-Host
Write-Host 'Verifying that User Secrets can be read by the server project...' -ForegroundColor Cyan
& dotnet user-secrets list --project $projectFile

if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify .NET User Secrets. Exit code: $LASTEXITCODE"
}

Write-Host
Write-Host 'Server secrets setup complete.' -ForegroundColor Green
