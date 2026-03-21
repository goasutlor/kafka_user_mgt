# Build Docker image แล้ว export เป็นไฟล์ .tar (ใช้กับ Docker Desktop บน Windows)
# วิธีใช้: เปิด PowerShell แล้วรัน
#   cd D:\Project1\gen-kafka-user
#   .\build-export-image.ps1
# จะได้ไฟล์ confluent-kafka-user-management-<version>.tar (เช่น 1.0.1) ในโฟลเดอร์เดียวกัน

$ErrorActionPreference = "Stop"
$ImageName = "confluent-kafka-user-management"
$ImageTag = "latest"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# Version from webapp/package.json — ทุกครั้งที่ build ให้ bump patch (ตัวเลขท้าย) เพื่อ confirm ว่า load image ใหม่จริง
$PkgPath = Join-Path $ScriptDir "webapp\package.json"
$Version = "0.0.0"
if (Test-Path $PkgPath) {
  $pkg = Get-Content $PkgPath -Raw | ConvertFrom-Json
  if ($pkg.version) {
    $Version = $pkg.version
    $parts = $Version -split '\.'
    if ($parts.Count -ge 3) {
      $patch = [int]$parts[2] + 1
      $Version = "$($parts[0]).$($parts[1]).$patch"
      $pkg.version = $Version
      $pkg | ConvertTo-Json -Depth 10 -Compress | Set-Content $PkgPath -Encoding UTF8 -NoNewline
      Write-Host "Bumped version to $Version"
    }
  }
}
$OutputTar = "${ImageName}-${Version}.tar"

Write-Host "Building image ${ImageName}:${ImageTag} (version $Version) ..."
docker build --build-arg "VERSION=$Version" -t "${ImageName}:${ImageTag}" -t "${ImageName}:${Version}" .

Write-Host "Exporting image to $OutputTar ..."
docker save -o $OutputTar "${ImageName}:${ImageTag}"

Write-Host "Done. File: $(Get-Location)\$OutputTar"
Write-Host "On target machine: podman load -i $OutputTar"
Write-Host "Then run container (see INSTALL.md)."
