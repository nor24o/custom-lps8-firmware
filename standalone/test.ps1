param(
    [string]$Port = "8080"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " LoRa Payload Decoder Studio - Universal PowerShell Launcher" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

# 1. Try py
$pyCheck = Get-Command "py" -ErrorAction SilentlyContinue
if ($pyCheck) {
    try {
        $null = & py -c "import sys; sys.exit(0)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[FOUND] Python via Windows Launcher 'py'" -ForegroundColor Green
            Write-Host "[INFO]  Starting Web Server on port $Port..." -ForegroundColor Cyan
            Start-Process "http://localhost:$Port"
            & py web_server.py --port $Port
            exit 0
        }
    } catch {}
}

# 2. Try python
$pythonCheck = Get-Command "python" -ErrorAction SilentlyContinue
if ($pythonCheck) {
    try {
        $null = & python -c "import sys; sys.exit(0)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[FOUND] Python executable 'python'" -ForegroundColor Green
            Write-Host "[INFO]  Starting Web Server on port $Port..." -ForegroundColor Cyan
            Start-Process "http://localhost:$Port"
            & python web_server.py --port $Port
            exit 0
        }
    } catch {}
}

# 3. Try python3
$python3Check = Get-Command "python3" -ErrorAction SilentlyContinue
if ($python3Check) {
    try {
        $null = & python3 -c "import sys; sys.exit(0)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[FOUND] Python 3 executable 'python3'" -ForegroundColor Green
            Write-Host "[INFO]  Starting Web Server on port $Port..." -ForegroundColor Cyan
            Start-Process "http://localhost:$Port"
            & python3 web_server.py --port $Port
            exit 0
        }
    } catch {}
}

# 4. Try node
$nodeCheck = Get-Command "node" -ErrorAction SilentlyContinue
if ($nodeCheck) {
    Write-Host "[FOUND] Node.js" -ForegroundColor Green
    Write-Host "[INFO]  Starting Web Server on port $Port..." -ForegroundColor Cyan
    Start-Process "http://localhost:$Port"
    & node web_server.js $Port
    exit 0
}

# 5. Fallback: Open index.html directly in default browser
Write-Host "[NOTE]  No working Python, Node.js, or Lua found on this system." -ForegroundColor Yellow
Write-Host "[INFO]  Launching Decoder Studio directly in your web browser (Zero-Install Mode)..." -ForegroundColor Yellow
$htmlPath = Join-Path $scriptDir "index.html"
Start-Process $htmlPath
Write-Host "Opened $htmlPath in your default web browser!" -ForegroundColor Green
Write-Host "You can use the full Decoder Studio, test payloads, and edit schemes." -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
