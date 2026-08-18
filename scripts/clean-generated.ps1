<#
.SYNOPSIS
    Remove generated AX7020 template workspaces without touching persistent sources.

.DESCRIPTION
    The default removes reproducible Vivado/Vitis workspaces, logs, and captures,
    while preserving published bit/XSA/LTX/ELF/BIN/manifest artifacts. Use
    -IncludePublished only when the complete published download set must also be
    invalidated. Use -PreserveProjects to remove only logs, caches, and staging
    files while keeping the Vivado and Vitis projects. Every resolved target is
    checked against the repository root.
#>
[CmdletBinding()]
param(
    [switch]$IncludePublished,
    [switch]$PreserveProjects,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\', '/')
$RepoPrefix = $RepoRoot + [IO.Path]::DirectorySeparatorChar
$PrjRoot = Join-Path $RepoRoot 'prj'
$VitisRoot = Join-Path $RepoRoot 'vitis'
$script:RemovedPaths = 0
$script:RemovedBytes = [UInt64]0

function Assert-SafeGeneratedTarget {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)

    $full = [IO.Path]::GetFullPath($Item.FullName)
    if ($full.Equals($RepoRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $full.StartsWith($RepoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing cleanup target outside the repository: $full"
    }
    return $full
}

function Get-GeneratedSize {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)

    if (-not $Item.PSIsContainer) { return [UInt64]$Item.Length }
    $sum = [UInt64]0
    foreach ($file in Get-ChildItem -LiteralPath $Item.FullName -File -Force -Recurse -ErrorAction Stop) {
        $sum += [UInt64]$file.Length
    }
    return $sum
}

function Remove-GeneratedItem {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)

    $full = Assert-SafeGeneratedTarget $Item
    $bytes = Get-GeneratedSize $Item
    Write-Host "CLEAN: path=$full bytes=$bytes dry_run=$([int][bool]$DryRun)"
    $script:RemovedPaths++
    $script:RemovedBytes += $bytes
    if ($DryRun) { return }

    Remove-Item -LiteralPath $full -Recurse -Force
    if (Test-Path -LiteralPath $full) {
        throw "Generated path still exists after cleanup: $full"
    }
}

try {
    foreach ($relative in @(
            '.Xil', 'logs', 'captures',
            '.gen', '.srcs', 'xsim.dir')) {
        $path = Join-Path $RepoRoot $relative
        if (Test-Path -LiteralPath $path) {
            Remove-GeneratedItem (Get-Item -LiteralPath $path -Force)
        }
    }

    foreach ($item in Get-ChildItem -LiteralPath $RepoRoot -File -Force) {
        if ($item.Name -match '^.*\.(?:jou|log|pb)$') {
            Remove-GeneratedItem $item
        }
    }

    $workspacePattern = '^(?:\.Xil|aie_primitive\.json|ps7_init.*|\..*\.(?:bit|tmp)|.*\.(?:xpr|structure\.manifest|mark_debug\.xdc|ila_debug\.xdc|ila_post\.tcl|cache|gen|hw|incremental|ioplanning|ip_user_files|runs|sim|srcs))$'
    $publishedPattern = '^.*\.(?:bit|xsa|ltx|hardware\.manifest)$'
    foreach ($item in Get-ChildItem -LiteralPath $PrjRoot -Force) {
        if ($PreserveProjects -and $item.Name -ne '.Xil') { continue }
        if ($item.Name -match $workspacePattern -or
            ($IncludePublished -and $item.Name -match $publishedPattern)) {
            Remove-GeneratedItem $item
        }
    }

    $persistentVitisNames = @('run.tcl', 'program-qspi.ps1', 'boot.bif', 'src')
    $publishedVitisPattern = '^.*\.(?:elf|bin|manifest)$'
    $vitisProcessNames = @('.Xil', 'boot', 'logs', '.analytics', 'IDE.log')
    foreach ($item in Get-ChildItem -LiteralPath $VitisRoot -Force) {
        if ($PreserveProjects -and $vitisProcessNames -notcontains $item.Name) { continue }
        if ($persistentVitisNames -contains $item.Name) { continue }
        if (-not $IncludePublished -and $item.Name -match $publishedVitisPattern) { continue }
        Remove-GeneratedItem $item
    }

    if ($IncludePublished) {
        $sdBoot = Join-Path $RepoRoot 'sd_boot'
        if (Test-Path -LiteralPath $sdBoot) {
            Remove-GeneratedItem (Get-Item -LiteralPath $sdBoot -Force)
        }
    }

    Write-Host "SUCCESS: Generated workspace cleanup completed."
    Write-Host "RESULT: status=PASS action=clean-generated paths=$script:RemovedPaths bytes=$script:RemovedBytes dry_run=$([int][bool]$DryRun) include_published=$([int][bool]$IncludePublished) preserve_projects=$([int][bool]$PreserveProjects)"
    Write-Host "NEXT: Vivado check"
}
catch {
    Write-Host "RESULT: status=FAIL action=clean-generated paths=$script:RemovedPaths bytes=$script:RemovedBytes"
    Write-Host "DIAGNOSTIC: $($_.Exception.Message)"
    exit 1
}
