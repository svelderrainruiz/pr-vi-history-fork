#Requires -Version 7.0
<#
.SYNOPSIS
  Validates Node/npm runtime contract using toolchain-lock metadata.

.DESCRIPTION
  Reads a toolchain lock JSON payload and validates that `node --version` and
  `npm --version` are available. Writes a machine-readable contract summary JSON
  and optionally emits its path to GitHub step outputs.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$LockPath,
  [string]$OutputPath,
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [switch]$FailOnMismatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExistingPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $hint = $null
    if ($Description -eq 'Toolchain lock file' -and $Path -match '\.pr-vi-history-tools[\\/]+toolchain-lock\.json$') {
      $hint = 'The reusable workflow tools_ref may target an older commit without toolchain-lock.json. Re-pin tools_ref/uses to a newer workflow SHA.'
    }
    if ([string]::IsNullOrWhiteSpace($hint)) {
      throw ("{0} not found: {1}" -f $Description, $Path)
    }
    throw ("{0} not found: {1}`n{2}" -f $Description, $Path, $hint)
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-FullPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Get-CommandVersion {
  param([Parameter(Mandatory = $true)][string]$CommandName)
  $output = & $CommandName --version 2>$null
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  if ($output -is [System.Array]) {
    return [string]($output | Select-Object -First 1)
  }
  return [string]$output
}

$resolvedLockPath = Resolve-ExistingPath -Path $LockPath -Description 'Toolchain lock file'
$lock = Get-Content -LiteralPath $resolvedLockPath -Raw | ConvertFrom-Json -Depth 12
if ($lock.schema -ne 'pr-vi-history-toolchain-lock@v1') {
  throw ("Unexpected toolchain lock schema '{0}'." -f $lock.schema)
}

$expectedNodeVersion = [string]$lock.node.version
$expectedNodeMajor = [int]$lock.node.major

$nodeCommand = Get-Command -Name 'node' -ErrorAction SilentlyContinue
$npmCommand = Get-Command -Name 'npm' -ErrorAction SilentlyContinue
$nodeVersionRaw = if ($nodeCommand) { Get-CommandVersion -CommandName 'node' } else { $null }
$npmVersionRaw = if ($npmCommand) { Get-CommandVersion -CommandName 'npm' } else { $null }
$nodeVersion = if ($nodeVersionRaw) { $nodeVersionRaw.Trim().TrimStart('v') } else { $null }
$npmVersion = if ($npmVersionRaw) { $npmVersionRaw.Trim().TrimStart('v') } else { $null }

$nodeMajor = $null
if (-not [string]::IsNullOrWhiteSpace($nodeVersion)) {
  $parts = $nodeVersion.Split('.')
  if ($parts.Length -gt 0) {
    $parsed = 0
    if ([int]::TryParse($parts[0], [ref]$parsed)) {
      $nodeMajor = $parsed
    }
  }
}

$checks = [System.Collections.Generic.List[object]]::new()
$status = 'ok'

if (-not $nodeCommand) {
  $status = 'fail'
  [void]$checks.Add([ordered]@{
    name = 'node-present'
    passed = $false
    detail = 'node executable not found on PATH.'
  })
} else {
  [void]$checks.Add([ordered]@{
    name = 'node-present'
    passed = $true
    detail = $nodeCommand.Source
  })
}

if (-not $npmCommand) {
  $status = 'fail'
  [void]$checks.Add([ordered]@{
    name = 'npm-present'
    passed = $false
    detail = 'npm executable not found on PATH.'
  })
} else {
  [void]$checks.Add([ordered]@{
    name = 'npm-present'
    passed = $true
    detail = $npmCommand.Source
  })
}

$majorMatch = $false
if ($nodeMajor -ne $null -and $nodeMajor -eq $expectedNodeMajor) {
  $majorMatch = $true
}
if (-not $majorMatch) {
  $status = 'fail'
}
$nodeMajorDisplay = if ($nodeMajor -ne $null) { [string]$nodeMajor } else { 'unknown' }
[void]$checks.Add([ordered]@{
  name = 'node-major-match'
  passed = $majorMatch
  detail = ("expected major {0}, actual {1}" -f $expectedNodeMajor, $nodeMajorDisplay)
})

$exactMatch = $false
if (-not [string]::IsNullOrWhiteSpace($nodeVersion) -and $nodeVersion -eq $expectedNodeVersion) {
  $exactMatch = $true
}
if (-not $exactMatch) {
  $status = 'fail'
}
$nodeVersionDisplay = if ($nodeVersion) { $nodeVersion } else { 'unknown' }
[void]$checks.Add([ordered]@{
  name = 'node-exact-match'
  passed = $exactMatch
  detail = ("expected {0}, actual {1}" -f $expectedNodeVersion, $nodeVersionDisplay)
})

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path (Split-Path -Parent $resolvedLockPath) 'tests/results/pr-vi-history/toolchain-contract.json'
}
$resolvedOutputPath = Resolve-FullPath -Path $OutputPath
[void](Ensure-Directory -Path (Split-Path -Parent $resolvedOutputPath))

$contract = [ordered]@{
  schema = 'pr-vi-history-toolchain-contract@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  status = $status
  lockPath = $resolvedLockPath
  expected = [ordered]@{
    nodeVersion = $expectedNodeVersion
    nodeMajor = $expectedNodeMajor
  }
  actual = [ordered]@{
    nodePath = if ($nodeCommand) { $nodeCommand.Source } else { $null }
    npmPath = if ($npmCommand) { $npmCommand.Source } else { $null }
    nodeVersion = $nodeVersion
    npmVersion = $npmVersion
    nodeMajor = $nodeMajor
  }
  checks = @($checks)
}
$contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
  Add-Content -LiteralPath $GitHubOutputPath -Value ("toolchain-contract-path={0}" -f $resolvedOutputPath) -Encoding utf8
  Add-Content -LiteralPath $GitHubOutputPath -Value ("toolchain-contract-status={0}" -f $status) -Encoding utf8
}

if ($FailOnMismatch -and $status -ne 'ok') {
  throw ("Toolchain contract validation failed. See {0}" -f $resolvedOutputPath)
}

Write-Host ("Toolchain contract status: {0}" -f $status)
Write-Host ("Toolchain contract path: {0}" -f $resolvedOutputPath)
