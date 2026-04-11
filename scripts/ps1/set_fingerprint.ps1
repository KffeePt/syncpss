[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "maintainer_id.ps1")

$repoRoot = Resolve-SyncpssRepoRoot -RepoRoot ""
try {
    Show-MaintainerIdManager -RepoRoot $repoRoot
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
