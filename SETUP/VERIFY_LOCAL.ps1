$checks = @(
    @{ Name='Discord OAuth'; Url='http://localhost:3001/api/health' },
    @{ Name='RabuShin ASP.NET'; Url='http://localhost:3002/game-api/health' },
    @{ Name='Vite'; Url='http://localhost:5173' }
)
foreach($check in $checks){
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 4 $check.Url
        Write-Host ("[OK] {0} - HTTP {1}" -f $check.Name,$r.StatusCode) -ForegroundColor Green
    } catch {
        Write-Host ("[FAIL] {0} - {1}" -f $check.Name,$_.Exception.Message) -ForegroundColor Red
    }
}
