<#
.SYNOPSIS
    Run a Vivado or XSCT workflow step with compact console output.

.DESCRIPTION
    Vendor output is written in full to logs/.  The console receives only a
    bounded, machine-readable summary so AI agents can decide whether further
    log inspection is needed without consuming the complete tool transcript.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Vivado', 'Vitis')]
    [string]$Tool,

    [Parameter(Mandatory, Position = 1)]
    [string]$Step,

    [string]$Xsa,
    [string]$TbTop,
    [string]$SimTime,
    [string]$VivadoPath,
    [string]$XsctPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RunTimer = [Diagnostics.Stopwatch]::StartNew()

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $RepoRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Resolve-NativeCommand {
    param([Parameter(Mandatory)][string]$Command)

    if ([IO.Path]::IsPathRooted($Command) -or
        $Command.Contains([IO.Path]::DirectorySeparatorChar) -or
        $Command.Contains([IO.Path]::AltDirectorySeparatorChar)) {
        return (Resolve-Path -LiteralPath $Command -ErrorAction Stop).Path
    }

    $resolved = @(Get-Command -Name $Command -CommandType Application -ErrorAction Stop)[0]
    if (-not [string]::IsNullOrWhiteSpace($resolved.Source)) {
        return $resolved.Source
    }
    return $resolved.Path
}

function Resolve-XilinxCommand {
    param(
        [string]$ExplicitPath,
        [string]$EnvironmentRoot,
        [Parameter(Mandatory)][string]$Command
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return Resolve-NativeCommand $ExplicitPath
    }
    if (-not [string]::IsNullOrWhiteSpace($EnvironmentRoot)) {
        return Resolve-NativeCommand (Join-Path $EnvironmentRoot "bin\$Command.bat")
    }
    return Resolve-NativeCommand $Command
}

function Resolve-XsctCommand {
    param(
        [string]$ExplicitPath,
        [string]$VitisRoot,
        [string]$VivadoCommand,
        [string]$VivadoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath) -or
        -not [string]::IsNullOrWhiteSpace($VitisRoot)) {
        return Resolve-XilinxCommand $ExplicitPath $VitisRoot 'xsct'
    }
    try {
        return Resolve-NativeCommand 'xsct'
    }
    catch {
        $vivado = Resolve-XilinxCommand $VivadoCommand $VivadoRoot 'vivado'
        $vivadoVersionRoot = Split-Path -Parent (Split-Path -Parent $vivado)
        $version = Split-Path -Leaf $vivadoVersionRoot
        $xilinxRoot = Split-Path -Parent (Split-Path -Parent $vivadoVersionRoot)
        return Resolve-NativeCommand (Join-Path $xilinxRoot "Vitis\$version\bin\xsct.bat")
    }
}

function New-XilinxWorkspaceDrive {
    param([Parameter(Mandatory)][string]$Path)

    # Vivado and XSCT 2022.2 can lose a "Desktop" path component on Windows.
    # Use a short-lived drive root so all tool-visible project paths are stable.
    $lastSubstError = $null
    foreach ($letter in @('T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
        if ($null -ne (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue)) {
            continue
        }

        # Another launcher can claim the same letter after Get-PSDrive. Capture
        # subst output so a losing race cannot contaminate this function's
        # single PSCustomObject return value.
        $substOutput = @(& "$env:SystemRoot\System32\subst.exe" "${letter}:" $Path 2>&1)
        $substExitCode = $LASTEXITCODE
        if ($substExitCode -eq 0) {
            return [pscustomobject]@{
                Drive = "${letter}:"
                Root = "${letter}:\"
            }
        }
        if ($substOutput.Count -gt 0) {
            $lastSubstError = ($substOutput | Out-String).Trim()
        }
    }

    $detail = if ([string]::IsNullOrWhiteSpace($lastSubstError)) { '' } else { " Last subst error: $lastSubstError" }
    throw "Unable to allocate a temporary drive letter for the Xilinx toolchain.$detail"
}

function ConvertTo-XsctWorkspacePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )

    $candidate = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
    }
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if ($candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return (Join-Path $WorkspaceRoot $candidate.Substring($prefix.Length))
    }
    return $candidate
}

function ConvertTo-CompactText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$Limit = 360
    )

    $compact = ($Text.Trim() -replace '\s+', ' ')
    if ($compact.Length -gt $Limit) {
        return $compact.Substring(0, $Limit - 3) + '...'
    }
    return $compact
}

function Write-Summary {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message
}

function Remove-SafePublishedItem {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)

    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Item.FullName)
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing publication rollback outside the repository: $full"
    }
    Remove-Item -LiteralPath $full -Recurse -Force
    return 1
}

function Invoke-PublicationRollback {
    param([Parameter(Mandatory)][string]$Scope)

    $removed = 0
    $prjDir = Join-Path $RepoRoot 'prj'
    $vitisDir = Join-Path $RepoRoot 'vitis'
    $sdDir = Join-Path $RepoRoot 'sd_boot'

    if ($Scope -eq 'hardware') {
        foreach ($pattern in @('*.bit', '*.xsa', '*.ltx', '*.hardware.manifest')) {
            foreach ($item in @(Get-ChildItem -LiteralPath $prjDir -File -Filter $pattern -ErrorAction SilentlyContinue)) {
                $removed += Remove-SafePublishedItem $item
            }
        }
    }

    if ($Scope -in @('hardware', 'vitis_all')) {
        foreach ($pattern in @('*.elf', '*.bin', '*.manifest', '*.xsa')) {
            foreach ($item in @(Get-ChildItem -LiteralPath $vitisDir -File -Filter $pattern -ErrorAction SilentlyContinue)) {
                $removed += Remove-SafePublishedItem $item
            }
        }
    }
    elseif ($Scope -eq 'vitis_application') {
        foreach ($item in @(Get-ChildItem -LiteralPath $vitisDir -File -Filter '*.elf' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'fsbl.elf' })) {
            $removed += Remove-SafePublishedItem $item
        }
        foreach ($pattern in @('*.bin', '*.manifest')) {
            foreach ($item in @(Get-ChildItem -LiteralPath $vitisDir -File -Filter $pattern -ErrorAction SilentlyContinue)) {
                $removed += Remove-SafePublishedItem $item
            }
        }
    }
    elseif ($Scope -eq 'vitis_boot') {
        foreach ($name in @('BOOT.bin', 'BOOT.manifest')) {
            $path = Join-Path $vitisDir $name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $removed += Remove-SafePublishedItem (Get-Item -LiteralPath $path)
            }
        }
    }

    if ($Scope -in @('hardware', 'vitis_all', 'vitis_application', 'vitis_boot')) {
        foreach ($directory in @((Join-Path $vitisDir 'boot'), $sdDir)) {
            if (Test-Path -LiteralPath $directory) {
                $removed += Remove-SafePublishedItem (Get-Item -LiteralPath $directory)
            }
        }
    }
    Write-Summary "ROLLBACK: scope=$Scope paths=$removed"
}

$toolKey = $Tool.ToLowerInvariant()
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$safeStep = $Step -replace '[^A-Za-z0-9_.-]', '_'
$LogFile = Join-Path $LogDir ("{0}-{1}-{2}-p{3}.log" -f $toolKey, $safeStep, $timestamp, $PID)

Write-Summary "RUN: tool=$Tool step=$Step"
Write-Summary "LOG: $LogFile"

$exitCode = -1
$invocationError = $null
$SuccessMarker = "SUCCESS: $Tool step '$Step' completed."
$previousErrorActionPreference = $ErrorActionPreference
$WorkspaceDrive = $null
$locationPushed = $false
$PreviousXilinxLocalUserData = $env:XILINX_LOCAL_USER_DATA
$env:XILINX_LOCAL_USER_DATA = 'no'
$ErrorActionPreference = 'Continue'
try {
    if ($Tool -eq 'Vivado' -and -not [string]::IsNullOrWhiteSpace($Xsa)) {
        throw '-Xsa is valid only with -Tool Vitis.'
    }
    if ($Tool -eq 'Vitis' -and
        (-not [string]::IsNullOrWhiteSpace($TbTop) -or -not [string]::IsNullOrWhiteSpace($SimTime))) {
        throw '-TbTop and -SimTime are valid only with Vivado sim.'
    }
    if ($Tool -eq 'Vivado' -and $Step -ne 'sim' -and
        (-not [string]::IsNullOrWhiteSpace($TbTop) -or -not [string]::IsNullOrWhiteSpace($SimTime))) {
        throw '-TbTop and -SimTime require -Step sim.'
    }

    switch ($Tool) {
        'Vivado' {
            $Executable = Resolve-XilinxCommand $VivadoPath $env:XILINX_VIVADO 'vivado'
            $WorkspaceDrive = New-XilinxWorkspaceDrive $RepoRoot
            $Arguments = @(
                '-mode', 'batch', '-nolog', '-nojournal', '-notrace',
                '-tempDir', (Join-Path $WorkspaceDrive.Root 'prj\.Xil'),
                '-source', (Join-Path $WorkspaceDrive.Root 'prj\run.tcl'),
                '-tclargs', $Step
            )
            if ($Step -eq 'sim') {
                if (-not [string]::IsNullOrWhiteSpace($TbTop)) {
                    $Arguments += $TbTop
                }
                if (-not [string]::IsNullOrWhiteSpace($SimTime)) {
                    if ([string]::IsNullOrWhiteSpace($TbTop)) {
                        throw '-SimTime requires -TbTop because Tcl arguments are positional.'
                    }
                    $Arguments += $SimTime
                }
            }
        }
        'Vitis' {
            $Executable = Resolve-XsctCommand $XsctPath $env:XILINX_VITIS $VivadoPath $env:XILINX_VIVADO
            $WorkspaceDrive = New-XilinxWorkspaceDrive $RepoRoot
            $Arguments = @((Join-Path $WorkspaceDrive.Root 'vitis\run.tcl'), $Step)
            if (-not [string]::IsNullOrWhiteSpace($Xsa)) {
                $Arguments += (ConvertTo-XsctWorkspacePath $Xsa $RepoRoot $WorkspaceDrive.Root)
            }
        }
    }

    # The pipeline streams directly to disk; it does not accumulate vendor
    # output in PowerShell memory or forward it to the console.
    if ($null -ne $WorkspaceDrive) {
        Push-Location -LiteralPath $WorkspaceDrive.Root
        $locationPushed = $true
    }
    & $Executable @Arguments 2>&1 | Out-File -LiteralPath $LogFile -Append -Encoding utf8
    if ($null -ne $LASTEXITCODE) {
        $exitCode = [int]$LASTEXITCODE
    }
}
catch {
    $invocationError = $_
    $_ | Out-String | Out-File -LiteralPath $LogFile -Append -Encoding utf8
}
finally {
    if ($locationPushed) {
        Pop-Location
    }
    if ($null -ne $WorkspaceDrive) {
        & "$env:SystemRoot\System32\subst.exe" $WorkspaceDrive.Drive /D 2>&1 |
            Out-File -LiteralPath $LogFile -Append -Encoding utf8
    }
    if ($null -eq $PreviousXilinxLocalUserData) {
        Remove-Item Env:XILINX_LOCAL_USER_DATA -ErrorAction SilentlyContinue
    }
    else {
        $env:XILINX_LOCAL_USER_DATA = $PreviousXilinxLocalUserData
    }
    $ErrorActionPreference = $previousErrorActionPreference
}

$errorMatches = @(
    Select-String -LiteralPath $LogFile -Pattern '(ERROR:|FATAL:|\[ERROR\])' -ErrorAction SilentlyContinue |
        Where-Object { $_.Line -notmatch '^\s*\+\s+(CategoryInfo|FullyQualifiedErrorId)' }
)
$allCriticalWarnings = @(
    Select-String -LiteralPath $LogFile -Pattern 'CRITICAL WARNING:' -ErrorAction SilentlyContinue
)
$ignoredSyncWarnings = @($allCriticalWarnings | Where-Object {
    $Tool -eq 'Vivado' -and $Step -eq 'sync' -and
    $_.Line -match '\[Project 1-19\].*[\\/](rtl|sim)[\\/].+\.(v|sv|vh|svh|mem|hex|coe|xdc)'
})
$criticalWarnings = @($allCriticalWarnings | Where-Object { $_ -notin $ignoredSyncWarnings })
$warningCount = @(
    Select-String -LiteralPath $LogFile -Pattern 'WARNING:' -ErrorAction SilentlyContinue
).Count
$hasSuccessMarker = [bool](
    Select-String -LiteralPath $LogFile -Pattern $SuccessMarker -SimpleMatch -Quiet -ErrorAction SilentlyContinue
)
$requiresSimulationPass = $Tool -eq 'Vivado' -and $Step -eq 'sim'
$hasSimulationPass = [bool](
    Select-String -LiteralPath $LogFile -Pattern '^\s*(?:#\s*)?TEST_PASS\s*$' -Quiet -ErrorAction SilentlyContinue
)

$milestones = @(
    Select-String -LiteralPath $LogFile -Pattern '^(Project created|Block Design configured|Synthesis complete|Build complete|Hardware platform exported|Implementation checks passed|Simulation completed by Vivado|QSPI boot configuration check passed|SD boot configuration check passed|Configuration check passed|Vitis projects created|Hardware platform updated|Application sources synchronized|Application build complete|JTAG manifest published|Boot image generated|SD boot package published|SD boot manifest published|Application build output cleaned)(?:[:.;。；]|$)' -ErrorAction SilentlyContinue | Select-Object -Last 6
)
$flowMilestones = @(
    Select-String -LiteralPath $LogFile -Pattern '^(CHECK:|SYNC:|CACHE:|ILA:|Hardware manifest published|ILA debug probes published|Build already current)' -ErrorAction SilentlyContinue
)
$milestones = @($milestones + $flowMilestones | Sort-Object LineNumber | Select-Object -Last 8)
$nextHintLines = @(
    Select-String -LiteralPath $LogFile -Pattern '^NEXT:' -ErrorAction SilentlyContinue |
        Select-Object -Last 2 -ExpandProperty Line
)
$phaseMetricLines = @(
    Select-String -LiteralPath $LogFile -Pattern '^METRIC:' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Line
)
$publicationScope = $null
$publicationStart = @(
    Select-String -LiteralPath $LogFile -Pattern '^PUBLISH_TRANSACTION: scope=([A-Za-z0-9_]+) state=started$' -ErrorAction SilentlyContinue |
        Select-Object -Last 1
)
if ($publicationStart.Count -gt 0 -and
    $publicationStart[0].Line -match '^PUBLISH_TRANSACTION: scope=([A-Za-z0-9_]+) state=started$') {
    $publicationScope = $Matches[1]
}
if ($nextHintLines.Count -eq 0 -and $errorMatches.Count -gt 0) {
    $errorText = ($errorMatches.Line -join "`n")
    $derivedNext = switch -Regex ($errorText) {
        'Run Vivado sync' { 'NEXT: Vivado sync'; break }
        'Run Vivado all' { 'NEXT: Vivado all'; break }
        'Run Vivado build' { 'NEXT: Vivado build'; break }
        'Run the create step first' { 'NEXT: Vivado all'; break }
        'Run Vitis update' { 'NEXT: Vitis update'; break }
        '(?:Run|Re-run) Vitis build' { 'NEXT: Vitis build'; break }
        '(?:Run|Re-run) Vitis boot' { 'NEXT: Vitis boot'; break }
        'Pure-PL mode does not use Vitis' { 'NEXT: Vivado check'; break }
        'Set (?:top_name|default_tb)' { 'NEXT: Edit config.tcl, then run Vivado check'; break }
    }
    if ($null -ne $derivedNext) { $nextHintLines = @($derivedNext) }
}

if ($criticalWarnings.Count -gt 0) {
    Write-Summary "WARNING: critical_count=$($criticalWarnings.Count) (see LOG)"
    foreach ($warning in ($criticalWarnings | Select-Object -First 3)) {
        Write-Summary ("WARNING_DETAIL: line={0} {1}" -f $warning.LineNumber, (ConvertTo-CompactText $warning.Line))
    }
}
if ($ignoredSyncWarnings.Count -gt 0) {
    Write-Summary "SYNC: ignored_missing_persistent_file_warnings=$($ignoredSyncWarnings.Count)"
}
if ($warningCount -gt 0) {
    Write-Summary "WARNING: count=$warningCount (see LOG)"
}
foreach ($metric in $phaseMetricLines) {
    Write-Summary $metric
}

$failed = $exitCode -ne 0 -or -not $hasSuccessMarker -or `
    ($requiresSimulationPass -and -not $hasSimulationPass) -or $errorMatches.Count -gt 0 -or `
    $criticalWarnings.Count -gt 0 -or $null -ne $invocationError
if ($failed -and $null -ne $publicationScope) {
    $nextHintLines = if ($publicationScope -eq 'hardware') {
        @('NEXT: Fix the first reported error/Critical Warning, then run Vivado check.')
    }
    else {
        @('NEXT: Fix the first reported error/Critical Warning, then run Vitis check.')
    }
}
elseif ($failed -and $criticalWarnings.Count -gt 0) {
    $nextHintLines = @('NEXT: Fix the first Critical Warning, then rerun the same minimal step.')
}
if ($failed) {
    if ($null -ne $publicationScope) {
        try {
            Invoke-PublicationRollback $publicationScope
        }
        catch {
            Write-Summary ("ROLLBACK_ERROR: {0}" -f (ConvertTo-CompactText $_.Exception.Message))
        }
    }
    Write-Summary ("RESULT: status=FAIL tool={0} step={1} exit_code={2} success_marker={3} error_count={4} critical_count={5}" -f `
        $Tool, $Step, $exitCode, $hasSuccessMarker, $errorMatches.Count, $criticalWarnings.Count)
    if ($null -ne $invocationError) {
        Write-Summary ("DIAGNOSTIC: {0}" -f (ConvertTo-CompactText $invocationError.Exception.Message))
    }
    if (-not $hasSuccessMarker) {
        Write-Summary 'DIAGNOSTIC: Expected success marker was not found.'
    }
    if ($requiresSimulationPass -and -not $hasSimulationPass) {
        Write-Summary 'DIAGNOSTIC: Simulation did not print the required TEST_PASS marker.'
    }
    foreach ($match in ($errorMatches | Select-Object -First 8)) {
        Write-Summary ("DIAGNOSTIC: line={0} {1}" -f $match.LineNumber, (ConvertTo-CompactText $match.Line))
    }
    foreach ($hint in $nextHintLines) {
        Write-Summary (ConvertTo-CompactText $hint)
    }
    $RunTimer.Stop()
    Write-Summary ("METRIC: elapsed_seconds={0:F3}" -f $RunTimer.Elapsed.TotalSeconds)
    exit 1
}

foreach ($milestone in $milestones) {
    Write-Summary ("DETAIL: {0}" -f (ConvertTo-CompactText $milestone.Line))
}
Write-Summary $SuccessMarker
Write-Summary ("RESULT: status=PASS tool={0} step={1} exit_code={2}" -f $Tool, $Step, $exitCode)
foreach ($hint in $nextHintLines) {
    Write-Summary (ConvertTo-CompactText $hint)
}
$RunTimer.Stop()
Write-Summary ("METRIC: elapsed_seconds={0:F3}" -f $RunTimer.Elapsed.TotalSeconds)
