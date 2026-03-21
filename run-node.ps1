# รัน Web ด้วย Node ตรงๆ (ติดแค่ Node 18+ + express)
# เบื้องต้น: วาง run-node.ps1 ไว้โฟลเดอร์เดียวกับ gen.sh แล้วรันจากโฟลเดอร์นั้น: .\run-node.ps1

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location (Join-Path $ScriptDir "webapp")
if (-not (Test-Path "package.json")) {
  Write-Error "webapp/package.json not found"
  exit 1
}

# ติดตั้ง dependency เฉพาะ production (มีแค่ express)
if (-not (Test-Path "node_modules/express")) {
  Write-Host "Installing dependencies (express only)..."
  npm install --omit=dev
}

$ConfigPath = if ($env:CONFIG_PATH) { $env:CONFIG_PATH } else { Join-Path $ScriptDir "webapp\config\web.config.json" }
$StaticDir = if ($env:STATIC_DIR) { $env:STATIC_DIR } else { Join-Path $ScriptDir "web-ui-mockup" }
$env:CONFIG_PATH = $ConfigPath
$env:STATIC_DIR = $StaticDir
if (-not (Test-Path $ConfigPath)) {
  Write-Host "WARN: Config not found at $ConfigPath — edit webapp/config/web.config.json"
}

Write-Host "Starting server (CONFIG_PATH=$ConfigPath, STATIC_DIR=$StaticDir)..."
Write-Host "Open http://<this-host>:3000 (or port in config)"
node server/index.js
