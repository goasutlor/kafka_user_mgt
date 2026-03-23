# Wait for the latest Docker GHCR workflow run on a branch to finish (GitHub CLI).
# Requires: gh — https://cli.github.com/ — and `gh auth login`
#
# Usage:
#   .\scripts\wait-ghcr-build.ps1
#   .\scripts\wait-ghcr-build.ps1 -Branch master
#   $env:GITHUB_REPO = "owner/name"; .\scripts\wait-ghcr-build.ps1

param(
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"
$Repo = if ($env:GITHUB_REPO) { $env:GITHUB_REPO } else { "goasutlor/kafka_user_mgt" }
$Workflow = "docker-ghcr.yml"
$Image = "ghcr.io/goasutlor/kafka_user_mgt:latest"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "Install GitHub CLI: https://cli.github.com/  then: gh auth login"
}

Write-Host "Watching latest run: repo=$Repo workflow=$Workflow branch=$Branch"
$runId = $null
try {
    $runId = (gh run list --repo $Repo --workflow=$Workflow --branch=$Branch --limit=1 --json databaseId -q ".[0].databaseId" 2>$null)
} catch { }
if (-not $runId) {
    Write-Host "No run found yet; waiting up to 120s for workflow to appear..."
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Seconds 5
        try {
            $runId = (gh run list --repo $Repo --workflow=$Workflow --branch=$Branch --limit=1 --json databaseId -q ".[0].databaseId" 2>$null)
        } catch { }
        if ($runId) { break }
    }
}
if (-not $runId) {
    Write-Error "Could not find a workflow run. Push first, or open: https://github.com/$Repo/actions/workflows/$Workflow"
}

Write-Host "Run ID: $runId — streaming status..."
gh run watch $runId --repo $Repo --exit-status
if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "GHCR build finished successfully."
    Write-Host "Pull: docker pull $Image"
} else {
    Write-Host ""
    Write-Error "GHCR build failed. Logs: gh run view $runId --repo $Repo --log-failed"
}
