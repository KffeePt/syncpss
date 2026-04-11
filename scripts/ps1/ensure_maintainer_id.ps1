[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "maintainer_id.ps1")

$resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
[void](Resolve-MaintainerIdSeed -RepoRoot $resolvedRepoRoot -NonInteractive:$NonInteractive)
