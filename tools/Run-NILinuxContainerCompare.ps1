#Requires -Version 7.0
<#
.SYNOPSIS
  Runs a LabVIEW CLI compare inside a local NI Linux container image.

.DESCRIPTION
  Preflights Docker mode/image availability and then executes
  CreateComparisonReport inside `nationalinstruments/labview:latest-linux`
  (or a caller-supplied image). The helper writes deterministic capture
  artifacts adjacent to the report output.

  Command shape follows NI LabVIEW CLI documentation:
  - https://www.ni.com/docs/en-US/bundle/labview/page/command-line-operations.html
  - https://www.ni.com/docs/en-US/bundle/labview/page/command-line-operation-to-compare-two-vis-and-generate-a-report.html

.PARAMETER BaseVi
  Path to the base VI. Required unless -Probe is set.

.PARAMETER HeadVi
  Path to the head VI. Required unless -Probe is set.

.PARAMETER Image
  Docker image tag to execute. Defaults to
  nationalinstruments/labview:latest-linux.

.PARAMETER ReportPath
  Optional report path on host. Defaults to
  tests/results/ni-linux-container/compare-report.<ext>.

.PARAMETER ReportType
  Host-facing report type selector: html, xml, or text.

.PARAMETER TimeoutSeconds
  Timeout for docker run execution. Defaults to 600.

.PARAMETER Flags
  Additional CLI flags appended to CreateComparisonReport.

.PARAMETER LabVIEWPath
  Optional explicit in-container LabVIEW path forwarded as -LabVIEWPath.

.PARAMETER CliPath
  Optional explicit in-container LabVIEW CLI path (for example
  /usr/local/natinst/LabVIEW-2026Q1-64/labviewcli).

.PARAMETER Probe
  Preflight only (Docker availability, Linux container mode, and image
  presence). Does not require BaseVi/HeadVi.

.PARAMETER PassThru
  Emit the capture object to stdout in addition to writing capture JSON.
#>
[CmdletBinding()]
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$Image = 'nationalinstruments/labview:latest-linux',
  [string]$ReportPath,
  [ValidateSet('html','xml','text')]
  [string]$ReportType = 'html',
  [int]$TimeoutSeconds = 600,
  [string[]]$Flags,
  [string]$LabVIEWPath,
  [string]$CliPath,
  [switch]$Probe,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PreflightExitCode = 2
$script:TimeoutExitCode = 124

function Assert-Tool {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw ("Required tool not found on PATH: {0}" -f $Name)
  }
}

function Resolve-ExistingFilePath {
  param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ParameterName
  )
  if ([string]::IsNullOrWhiteSpace($InputPath)) {
    throw ("Parameter -{0} is required." -f $ParameterName)
  }
  try {
    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
      throw ("Path is not a file: {0}" -f $InputPath)
    }
    return $resolved.Path
  } catch {
    throw ("Unable to resolve -{0} file path '{1}'." -f $ParameterName, $InputPath)
  }
}

function Resolve-ReportTypeInfo {
  param([Parameter(Mandatory)][string]$Type)
  switch ($Type.ToLowerInvariant()) {
    'html' {
      return [pscustomobject]@{
        InputType     = 'html'
        CliReportType = 'HTMLSingleFile'
        Extension     = 'html'
      }
    }
    'xml' {
      return [pscustomobject]@{
        InputType     = 'xml'
        CliReportType = 'XML'
        Extension     = 'xml'
      }
    }
    'text' {
      return [pscustomobject]@{
        InputType     = 'text'
        CliReportType = 'Text'
        Extension     = 'txt'
      }
    }
    default {
      throw ("Unsupported ReportType '{0}'." -f $Type)
    }
  }
}

function Resolve-OutputReportPath {
  param(
    [string]$PathValue,
    [Parameter(Mandatory)][string]$Extension
  )
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    $defaultRoot = Join-Path (Resolve-Path '.').Path 'tests/results/ni-linux-container'
    return (Join-Path $defaultRoot ("compare-report.{0}" -f $Extension))
  }
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-Path '.').Path $PathValue))
}

function Get-DockerServerOsType {
  $output = & docker info --format '{{.OSType}}' 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
    throw 'Unable to query Docker daemon mode. Ensure Docker Desktop is running.'
  }
  return $output.Trim().ToLowerInvariant()
}

function Test-DockerImageExists {
  param([Parameter(Mandatory)][string]$Tag)
  & docker image inspect $Tag *> $null
  return ($LASTEXITCODE -eq 0)
}

function Get-OrAddMountPath {
  param(
    [Parameter(Mandatory)][hashtable]$Map,
    [Parameter(Mandatory)][ref]$Index,
    [Parameter(Mandatory)][string]$HostDirectory
  )
  if (-not $Map.ContainsKey($HostDirectory)) {
    $Map[$HostDirectory] = ('/compare/m{0}' -f $Index.Value)
    $Index.Value++
  }
  return $Map[$HostDirectory]
}

function Convert-HostFileToContainerPath {
  param(
    [Parameter(Mandatory)][string]$HostFilePath,
    [Parameter(Mandatory)][hashtable]$MountMap,
    [Parameter(Mandatory)][ref]$MountIndex
  )
  $hostDir = Split-Path -Parent $HostFilePath
  $containerDir = Get-OrAddMountPath -Map $MountMap -Index $MountIndex -HostDirectory $hostDir
  return (Join-Path $containerDir (Split-Path -Leaf $HostFilePath)).Replace('\', '/')
}

function New-ContainerScript {
  return @'
#!/usr/bin/env bash
set -euo pipefail

resolve_cli_path() {
  if [[ -n "${COMPARE_CLI_PATH:-}" ]] && [[ -x "${COMPARE_CLI_PATH}" ]]; then
    printf '%s' "${COMPARE_CLI_PATH}"
    return 0
  fi

  local candidates=(
    "/usr/local/natinst/LabVIEW-2026Q1-64/labviewcli"
    "/usr/local/natinst/LabVIEW-2026Q1-64/LabVIEWCLI"
    "/usr/local/natinst/LabVIEW-2025-64/labviewcli"
    "/usr/local/natinst/LabVIEW-2025-64/LabVIEWCLI"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  local discovered
  discovered="$(find /usr/local/natinst -maxdepth 4 -type f \( -iname 'labviewcli' -o -iname 'LabVIEWCLI' \) 2>/dev/null | head -n 1 || true)"
  if [[ -n "${discovered}" ]]; then
    printf '%s' "${discovered}"
    return 0
  fi

  return 1
}

cli_path="$(resolve_cli_path || true)"
if [[ -z "${cli_path}" ]]; then
  echo "LabVIEW CLI executable not found in container." >&2
  exit 2
fi

resolve_labview_path() {
  if [[ -n "${COMPARE_LABVIEW_PATH_ARG:-}" ]] && [[ -x "${COMPARE_LABVIEW_PATH_ARG}" ]]; then
    printf '%s' "${COMPARE_LABVIEW_PATH_ARG}"
    return 0
  fi

  local cli_dir
  cli_dir="$(dirname "${cli_path}")"
  local candidates=(
    "${cli_dir}/labview"
    "${cli_dir}/LabVIEW"
    "/usr/local/natinst/LabVIEW-2026-64/labview"
    "/usr/local/natinst/LabVIEW-2026-64/labviewprofull"
    "/usr/local/natinst/LabVIEW-2025-64/labview"
    "/usr/local/natinst/LabVIEW-2025-64/labviewprofull"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  local discovered
  discovered="$(find /usr/local/natinst -maxdepth 4 \( -iname 'labview' -o -iname 'LabVIEW' -o -iname 'labviewprofull' -o -iname 'LabVIEWProFull' \) 2>/dev/null | head -n 1 || true)"
  if [[ -n "${discovered}" ]] && [[ -x "${discovered}" ]]; then
    printf '%s' "${discovered}"
    return 0
  fi

  return 1
}

labview_path="$(resolve_labview_path || true)"

declare -a args=(
  "-OperationName" "CreateComparisonReport"
  "-VI1" "${COMPARE_BASE_VI}"
  "-VI2" "${COMPARE_HEAD_VI}"
  "-ReportPath" "${COMPARE_REPORT_PATH}"
  "-ReportType" "${COMPARE_REPORT_TYPE}"
)

if [[ -n "${labview_path}" ]]; then
  args+=("-LabVIEWPath" "${labview_path}")
fi

if [[ -n "${COMPARE_FLAGS_B64:-}" ]]; then
  decoded_flags="$(printf '%s' "${COMPARE_FLAGS_B64}" | base64 --decode 2>/dev/null || true)"
  if [[ -n "${decoded_flags}" ]]; then
    while IFS= read -r flag; do
      if [[ -n "${flag}" ]]; then
        args+=("${flag}")
      fi
    done <<< "${decoded_flags}"
  fi
fi

if command -v xvfb-run >/dev/null 2>&1; then
  xvfb-run -a --server-args="-screen 0 1920x1080x24" "${cli_path}" "${args[@]}"
  exit $?
fi

xvfb_pid=""
if command -v Xvfb >/dev/null 2>&1; then
  export DISPLAY="${DISPLAY:-:99}"
  Xvfb "${DISPLAY}" -screen 0 1920x1080x24 >/tmp/xvfb.log 2>&1 &
  xvfb_pid="$!"
  trap 'if [[ -n "${xvfb_pid}" ]]; then kill "${xvfb_pid}" >/dev/null 2>&1 || true; fi' EXIT
fi

if [[ -z "${DISPLAY:-}" ]]; then
  echo "Unable to open X display. Install xvfb in the image or set DISPLAY." >&2
  exit 3
fi

"${cli_path}" "${args[@]}"
exit $?
'@
}

function Convert-ToEncodedCommand {
  param(
    [Parameter(Mandatory)][string]$CommandText
  )
  return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($CommandText))
}

function Invoke-DockerRunWithTimeout {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs,
    [Parameter(Mandatory)][int]$Seconds,
    [Parameter(Mandatory)][string]$ContainerName
  )

  $stdoutFile = Join-Path $env:TEMP ("ni-linux-container-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrFile = Join-Path $env:TEMP ("ni-linux-container-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $dockerArgsFile = Join-Path $env:TEMP ("ni-linux-container-docker-args-{0}.json" -f ([guid]::NewGuid().ToString('N')))
  $process = $null
  try {
    $pwshPath = (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
      throw 'pwsh was not found; unable to launch docker command.'
    }

    $DockerArgs | ConvertTo-Json -Compress | Set-Content -LiteralPath $dockerArgsFile -Encoding utf8
    $dockerArgsFileEscaped = $dockerArgsFile.Replace("'", "''")
    $invokeDockerScript = @"
`$raw = Get-Content -LiteralPath '$dockerArgsFileEscaped' -Raw
if ([string]::IsNullOrWhiteSpace(`$raw)) {
  `$args = @()
} else {
  `$parsed = `$raw | ConvertFrom-Json
  if (`$parsed -is [System.Collections.IEnumerable] -and -not (`$parsed -is [string])) {
    `$args = @(`$parsed | ForEach-Object { [string]`$_ })
  } elseif (`$null -eq `$parsed) {
    `$args = @()
  } else {
    `$args = @([string]`$parsed)
  }
}
& docker @args
exit `$LASTEXITCODE
"@
    $encodedInvokeDockerScript = Convert-ToEncodedCommand -CommandText $invokeDockerScript

    $process = Start-Process -FilePath $pwshPath `
      -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encodedInvokeDockerScript) `
      -RedirectStandardOutput $stdoutFile `
      -RedirectStandardError $stderrFile `
      -PassThru

    $waitMs = [Math]::Max(1, $Seconds) * 1000
    if (-not $process.WaitForExit($waitMs)) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      try { & docker rm -f $ContainerName *> $null } catch {}
      $stdout = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
      $stderr = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
      return [pscustomobject]@{
        TimedOut = $true
        ExitCode = $script:TimeoutExitCode
        StdOut   = $stdout
        StdErr   = $stderr
      }
    }

    $stdout = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
    return [pscustomobject]@{
      TimedOut = $false
      ExitCode = [int]$process.ExitCode
      StdOut   = $stdout
      StdErr   = $stderr
    }
  } finally {
    if ($process) {
      try { $process.Dispose() } catch {}
    }
    Remove-Item -LiteralPath $dockerArgsFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stdoutFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
  }
}

function Write-TextArtifact {
  param(
    [Parameter(Mandatory)][string]$Path,
    [AllowNull()][string]$Content
  )
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  if ($null -eq $Content) { $Content = '' }
  Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
}

function Test-LabVIEWCliFailure {
  param(
    [AllowNull()][string]$StdErr,
    [AllowNull()][string]$StdOut
  )

  $combined = @($StdErr, $StdOut) -join "`n"
  if ([string]::IsNullOrWhiteSpace($combined)) {
    return $false
  }
  return (
    $combined -match 'Error code\s*:' -or
    $combined -match 'An error occurred while running the LabVIEW CLI' -or
    $combined -match 'LabVIEW CLI executable not found'
  )
}

function Resolve-RunFailureMessage {
  param(
    [AllowNull()][string]$StdErr,
    [AllowNull()][string]$StdOut,
    [Parameter(Mandatory)][int]$ExitCode
  )

  foreach ($candidate in @($StdErr, $StdOut)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    $match = [regex]::Match($candidate, 'Error message\s*:\s*(.+)')
    if ($match.Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
      return $match.Groups[1].Value.Trim()
    }

    $lines = @($candidate -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt 0) {
      return $lines[-1].Trim()
    }
  }

  return ("Container compare failed with exit code {0}." -f $ExitCode)
}

if ($TimeoutSeconds -le 0) {
  throw '-TimeoutSeconds must be greater than zero.'
}

$capture = [ordered]@{
  schema         = 'ni-linux-container-compare/v1'
  generatedAt    = (Get-Date).ToUniversalTime().ToString('o')
  image          = $Image
  reportType     = $ReportType
  timeoutSeconds = $TimeoutSeconds
  probe          = [bool]$Probe
  status         = 'init'
  exitCode       = $null
  timedOut       = $false
  dockerServerOs = $null
  baseVi         = $null
  headVi         = $null
  reportPath     = $null
  command        = $null
  stdoutPath     = $null
  stderrPath     = $null
  message        = $null
}

$finalExitCode = 0
$stdoutContent = ''
$stderrContent = ''
$capturePath = $null
$stdoutPath = $null
$stderrPath = $null
$scriptTempDir = $null

try {
  Assert-Tool -Name 'docker'

  $dockerOsType = Get-DockerServerOsType
  $capture.dockerServerOs = $dockerOsType
  if ($dockerOsType -ne 'linux') {
    throw ("Docker daemon is running in '{0}' mode. Switch Docker Desktop to Linux containers and retry." -f $dockerOsType)
  }
  if (-not (Test-DockerImageExists -Tag $Image)) {
    throw ("Docker image '{0}' not found locally. Pull it first: docker pull {0}" -f $Image)
  }

  if ($Probe) {
    $capture.status = 'probe-ok'
    $capture.exitCode = 0
    $capture.message = ("Docker is in linux mode and image '{0}' is available." -f $Image)
    Write-Host ("[ni-linux-container-probe] {0}" -f $capture.message) -ForegroundColor Green
  } else {
    $baseViPath = Resolve-ExistingFilePath -InputPath $BaseVi -ParameterName 'BaseVi'
    $headViPath = Resolve-ExistingFilePath -InputPath $HeadVi -ParameterName 'HeadVi'
    $reportInfo = Resolve-ReportTypeInfo -Type $ReportType
    $resolvedReportPath = Resolve-OutputReportPath -PathValue $ReportPath -Extension $reportInfo.Extension
    $reportDirectory = Split-Path -Parent $resolvedReportPath
    if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }

    $capturePath = Join-Path $reportDirectory 'ni-linux-container-capture.json'
    $stdoutPath = Join-Path $reportDirectory 'ni-linux-container-stdout.txt'
    $stderrPath = Join-Path $reportDirectory 'ni-linux-container-stderr.txt'

    $capture.baseVi = $baseViPath
    $capture.headVi = $headViPath
    $capture.reportPath = $resolvedReportPath
    $capture.stdoutPath = $stdoutPath
    $capture.stderrPath = $stderrPath

    $flagsPayload = if ($Flags) { ($Flags -join "`n") } else { '' }
    $flagsB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($flagsPayload))

    $mounts = @{}
    $mountIndex = 0
    $mountRef = [ref]$mountIndex
    $containerBaseVi = Convert-HostFileToContainerPath -HostFilePath $baseViPath -MountMap $mounts -MountIndex $mountRef
    $containerHeadVi = Convert-HostFileToContainerPath -HostFilePath $headViPath -MountMap $mounts -MountIndex $mountRef
    $containerReportPath = Convert-HostFileToContainerPath -HostFilePath $resolvedReportPath -MountMap $mounts -MountIndex $mountRef

    $scriptTempDir = Join-Path $env:TEMP ("ni-linux-container-script-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $scriptTempDir -Force | Out-Null
    $hostContainerScriptPath = Join-Path $scriptTempDir 'run-compare.sh'
    $containerScript = New-ContainerScript
    $containerScript = $containerScript -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText(
      $hostContainerScriptPath,
      $containerScript,
      [System.Text.UTF8Encoding]::new($false)
    )
    $mounts[$scriptTempDir] = '/compare/script'

    $containerName = 'ni-linux-compare-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 12))
    $dockerArgs = @(
      'run',
      '--rm',
      '--name', $containerName,
      '--workdir', '/compare'
    )

    foreach ($entry in ($mounts.GetEnumerator() | Sort-Object Name)) {
      $volumeSpec = '{0}:{1}' -f $entry.Name, $entry.Value
      $dockerArgs += @('-v', $volumeSpec)
    }

    $dockerArgs += @('--env', ("COMPARE_BASE_VI={0}" -f $containerBaseVi))
    $dockerArgs += @('--env', ("COMPARE_HEAD_VI={0}" -f $containerHeadVi))
    $dockerArgs += @('--env', ("COMPARE_REPORT_PATH={0}" -f $containerReportPath))
    $dockerArgs += @('--env', ("COMPARE_REPORT_TYPE={0}" -f $reportInfo.CliReportType))
    $dockerArgs += @('--env', ("COMPARE_FLAGS_B64={0}" -f $flagsB64))
    if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
      $dockerArgs += @('--env', ("COMPARE_LABVIEW_PATH_ARG={0}" -f $LabVIEWPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($CliPath)) {
      $dockerArgs += @('--env', ("COMPARE_CLI_PATH={0}" -f $CliPath))
    }
    $dockerArgs += @(
      $Image,
      '/bin/bash',
      '/compare/script/run-compare.sh'
    )

    $capture.command = ('docker run --rm --name {0} ... {1} /bin/bash /compare/script/run-compare.sh' -f $containerName, $Image)
    Write-Host ("[ni-linux-container-compare] image={0} report={1}" -f $Image, $resolvedReportPath) -ForegroundColor Cyan

    $runResult = Invoke-DockerRunWithTimeout -DockerArgs $dockerArgs -Seconds $TimeoutSeconds -ContainerName $containerName
    $stdoutContent = $runResult.StdOut
    $stderrContent = $runResult.StdErr

    if ($runResult.TimedOut) {
      $capture.status = 'timeout'
      $capture.timedOut = $true
      $capture.exitCode = $script:TimeoutExitCode
      $capture.message = ("Container compare timed out after {0} second(s)." -f $TimeoutSeconds)
      $finalExitCode = $script:TimeoutExitCode
    } else {
      $exitCode = [int]$runResult.ExitCode
      $capture.exitCode = $exitCode
      switch ($exitCode) {
        0 { $capture.status = 'ok' }
        1 {
          if (Test-LabVIEWCliFailure -StdErr $stderrContent -StdOut $stdoutContent) {
            $capture.status = 'error'
            $capture.message = Resolve-RunFailureMessage -StdErr $stderrContent -StdOut $stdoutContent -ExitCode $exitCode
          } else {
            $capture.status = 'diff'
          }
        }
        default {
          $capture.status = 'error'
          $capture.message = Resolve-RunFailureMessage -StdErr $stderrContent -StdOut $stdoutContent -ExitCode $exitCode
        }
      }
      $finalExitCode = $exitCode
    }

    if ($capture.status -eq 'ok' -and -not (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf)) {
      $capture.status = 'error'
      $capture.message = ("Expected report was not created: {0}" -f $resolvedReportPath)
      $finalExitCode = 3
      $capture.exitCode = $finalExitCode
    }
  }
} catch {
  $capture.status = 'preflight-error'
  $capture.exitCode = $script:PreflightExitCode
  $capture.message = $_.Exception.Message
  $finalExitCode = $script:PreflightExitCode
} finally {
  if (-not $Probe) {
    if ($stdoutPath) { Write-TextArtifact -Path $stdoutPath -Content $stdoutContent }
    if ($stderrPath) { Write-TextArtifact -Path $stderrPath -Content $stderrContent }
    if ($capturePath) {
      $capture.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      $capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capturePath -Encoding utf8
      Write-Host ("[ni-linux-container-compare] capture={0} status={1} exit={2}" -f $capturePath, $capture.status, $capture.exitCode) -ForegroundColor DarkGray
    }
  }
  if ($scriptTempDir) {
    Remove-Item -LiteralPath $scriptTempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($PassThru) {
  [pscustomobject]$capture
}

if ($finalExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($capture.message)) {
  Write-Host ("[ni-linux-container-compare] {0}" -f $capture.message) -ForegroundColor Red
}

exit $finalExitCode
