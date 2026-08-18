<#
.SYNOPSIS
    Download the current AX7020 build through JTAG for temporary execution.

.DESCRIPTION
    Reads use_bd from config.tcl. Pure-PL mode configures only the stable
    bitstream and does not require an XSA. PS+PL mode validates XSA, bitstream,
    FSBL, and application ELF against JTAG.manifest before running the ordered
    bitstream -> FSBL -> application download. QSPI Flash is never written.
    The command is non-interactive; hardware readiness is confirmed by the
    caller before invocation and is not requested again by this script.
#>
[CmdletBinding()]
param(
    [string]$Bitstream,
    [string]$Fsbl,
    [string]$ApplicationElf,
    [string]$Manifest,
    [string]$XsctPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $RepoRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("jtag-download-{0}-p{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID)
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Resolve-File {
    param([string]$Description, [string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0) {
        throw "$Description must be a non-empty file: $Path"
    }
    return $item.FullName
}

function Resolve-UniqueFile {
    param([string]$Description, [string]$Directory, [string]$Filter, [string[]]$Exclude = @())
    $candidates = @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -File | Where-Object {
        -not $_.Name.StartsWith('.') -and $_.Name -notin $Exclude -and $_.Length -gt 0
    })
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one $Description in $Directory; found: $($candidates.FullName -join ', '). Pass an explicit path."
    }
    return $candidates[0].FullName
}

function Resolve-Xsct {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return Resolve-File 'XSCT executable' $Path
    }
    if (-not [string]::IsNullOrWhiteSpace($env:XILINX_VITIS)) {
        return Resolve-File 'XSCT executable' (Join-Path $env:XILINX_VITIS 'bin\xsct.bat')
    }
    $candidate = @(Get-Command -Name xsct -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($candidate.Count -gt 0) {
        return $candidate[0].Source
    }
    throw 'XSCT was not found. Set XILINX_VITIS or pass -XsctPath.'
}

function Assert-XsctVersion {
    param([string]$Executable)

    $versionScript = Join-Path ([IO.Path]::GetTempPath()) ("xsct-version-{0}.tcl" -f [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($versionScript, "puts [version]`n", [Text.Encoding]::ASCII)
        $output = @(& $Executable $versionScript 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
        $output | Out-File -LiteralPath $LogFile -Append -Encoding utf8
        if ($exitCode -ne 0 -or ($output | Out-String) -notmatch '(?<!\d)2022\.2(?!\d)') {
            throw 'XSCT 2022.2 is required.'
        }
    }
    finally {
        Remove-Item -LiteralPath $versionScript -Force -ErrorAction SilentlyContinue
    }
}

function Get-UseBlockDesign {
    $configPath = Join-Path $RepoRoot 'config.tcl'
    $matches = @(Select-String -LiteralPath $configPath -Pattern '^\s*set\s+template_config\(use_bd\)\s+([01])\s*(?:#.*)?$')
    if ($matches.Count -ne 1) {
        throw "Expected one literal template_config(use_bd) assignment in $configPath."
    }
    return $matches[0].Matches[0].Groups[1].Value -eq '1'
}

function Read-KeyValueManifest {
    param([string]$Path)

    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines((Resolve-File 'JTAG manifest' $Path), [Text.Encoding]::UTF8)) {
        $text = $line.Trim()
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
        $separator = $text.IndexOf('=')
        if ($separator -le 0) { throw "Invalid JTAG manifest line: $line" }
        $key = $text.Substring(0, $separator).Trim()
        $value = $text.Substring($separator + 1).Trim()
        if ($values.ContainsKey($key)) { throw "Duplicate JTAG manifest key: $key" }
        $values[$key] = $value
    }
    return $values
}

function Get-ManifestValue {
    param([hashtable]$Values, [string]$Key)
    if (-not $Values.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace([string]$Values[$Key])) {
        throw "JTAG manifest is missing required key: $Key"
    }
    return [string]$Values[$Key]
}

function Resolve-RepositoryRelativeFile {
    param([string]$Description, [string]$RelativePath)

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Description path must be repository-relative: $RelativePath"
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $RepoRoot ($RelativePath -replace '/', '\')))
    $rootPath = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description path escapes the repository: $RelativePath"
    }
    return Resolve-File $Description $candidate
}

function Resolve-ManifestArtifact {
    param(
        [hashtable]$Values,
        [string]$Key,
        [string]$Description,
        [string]$OverridePath
    )

    $publishedPath = Resolve-RepositoryRelativeFile $Description (Get-ManifestValue $Values "${Key}_path")
    $path = if ([string]::IsNullOrWhiteSpace($OverridePath)) { $publishedPath } else { Resolve-File $Description $OverridePath }
    [UInt64]$expectedSize = 0
    if (-not [UInt64]::TryParse((Get-ManifestValue $Values "${Key}_size"), [ref]$expectedSize)) {
        throw "Invalid ${Key}_size in JTAG manifest."
    }
    $item = Get-Item -LiteralPath $path
    if ([UInt64]$item.Length -ne $expectedSize) {
        throw "$Description size does not match JTAG.manifest. Re-run Vitis build."
    }
    $expectedHash = Get-ManifestValue $Values "${Key}_sha256"
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description SHA-256 does not match JTAG.manifest. Re-run the correct Vivado/Vitis flow."
    }
    return $path
}

function New-WorkspaceDrive {
    foreach ($letter in @('T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
        if ($null -ne (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue)) { continue }
        & "$env:SystemRoot\System32\subst.exe" "${letter}:" $RepoRoot
        if ($LASTEXITCODE -eq 0) { return "${letter}:" }
    }
    throw 'Unable to allocate a temporary drive letter for XSCT.'
}

function ConvertTo-WorkspacePath {
    param([string]$Path, [string]$WorkspaceRoot)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $rootPath = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the repository: $Path"
    }
    return Join-Path $WorkspaceRoot $fullPath.Substring($prefix.Length)
}

try {
    $useBd = Get-UseBlockDesign
    $mode = if ($useBd) { 'ps_pl' } else { 'pure_pl' }
    $xsa = $null
    $fsblElf = $null
    $appElf = $null

    if ($useBd) {
        $manifestPath = if ($Manifest) { Resolve-File 'JTAG manifest' $Manifest } else {
            Resolve-File 'JTAG manifest' (Join-Path $RepoRoot 'vitis\JTAG.manifest')
        }
        $values = Read-KeyValueManifest $manifestPath
        if ((Get-ManifestValue $values 'manifest_version') -ne '1' -or
            (Get-ManifestValue $values 'design_mode') -ne 'ps_pl') {
            throw 'Unsupported JTAG.manifest. Re-run Vitis build.'
        }
        $xsa = Resolve-ManifestArtifact $values 'xsa' 'hardware handoff' $null
        $bit = Resolve-ManifestArtifact $values 'bitstream' 'bitstream' $Bitstream
        $fsblElf = Resolve-ManifestArtifact $values 'fsbl' 'FSBL ELF' $Fsbl
        $appElf = Resolve-ManifestArtifact $values 'application_elf' 'application ELF' $ApplicationElf
    }
    else {
        if ($Fsbl -or $ApplicationElf -or $Manifest) {
            throw 'Pure-PL mode accepts only a bitstream; FSBL, application ELF, and JTAG manifest are not used.'
        }
        $staleXsa = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'prj') -Filter '*.xsa' -File)
        if ($staleXsa.Count -gt 0) {
            throw "Pure-PL mode is selected but a PS+PL XSA still exists: $($staleXsa.FullName -join ', '). Run Vivado all to rebuild and clear stale hardware artifacts."
        }
        $bit = if ($Bitstream) { Resolve-File 'bitstream' $Bitstream } else {
            Resolve-UniqueFile 'stable bitstream' (Join-Path $RepoRoot 'prj') '*.bit'
        }
    }

    $xsct = Resolve-Xsct $XsctPath
    $jtagTcl = Resolve-File 'JTAG Tcl script' (Join-Path $PSScriptRoot 'download-jtag.tcl')

    $header = "RUN: action=jtag-download mode=$mode`nBITSTREAM: $bit`n"
    if ($useBd) {
        $header += "XSA: $xsa`nFSBL: $fsblElf`nAPPLICATION: $appElf`nMANIFEST: $manifestPath`n"
    }
    [IO.File]::WriteAllText($LogFile, $header, $Utf8NoBom)
    Assert-XsctVersion $xsct

    $drive = New-WorkspaceDrive
    try {
        $workspaceRoot = "$drive\"
        $shortBit = ConvertTo-WorkspacePath $bit $workspaceRoot
        $shortTcl = Join-Path $workspaceRoot 'scripts\download-jtag.tcl'
        $arguments = @($shortTcl, $shortBit)
        if ($useBd) {
            $arguments += (ConvertTo-WorkspacePath $fsblElf $workspaceRoot)
            $arguments += (ConvertTo-WorkspacePath $appElf $workspaceRoot)
        }
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $xsct @arguments 2>&1 | Out-File -LiteralPath $LogFile -Append -Encoding utf8
            $xsctExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($xsctExitCode -ne 0) { throw "XSCT failed with exit code $xsctExitCode. Log: $LogFile" }
    }
    finally {
        if ($null -ne $drive) { & "$env:SystemRoot\System32\subst.exe" $drive /D | Out-Null }
    }

    $jtagErrors = @(Select-String -LiteralPath $LogFile -Pattern '(ERROR:|FATAL:|\[ERROR\])')
    if ($jtagErrors.Count -gt 0) {
        throw "JTAG download failed: $($jtagErrors[-1].Line.Trim()). Log: $LogFile"
    }
    $successMarker = if ($useBd) {
        'SUCCESS: JTAG download completed; application is running.'
    } else {
        'SUCCESS: Pure-PL JTAG configuration completed.'
    }
    if (-not (Select-String -LiteralPath $LogFile -Pattern $successMarker -SimpleMatch -Quiet)) {
        throw "JTAG download did not report its success marker. Log: $LogFile"
    }
    [IO.File]::AppendAllText($LogFile, "RESULT: status=PASS action=jtag-download mode=$mode`n", $Utf8NoBom)
    Write-Host "LOG: $LogFile"
    Write-Host "RESULT: status=PASS action=jtag-download mode=$mode"
    Write-Host $successMarker
}
catch {
    [IO.File]::AppendAllText($LogFile, ($_ | Out-String), $Utf8NoBom)
    [IO.File]::AppendAllText($LogFile, "RESULT: status=FAIL action=jtag-download`n", $Utf8NoBom)
    Write-Host "LOG: $LogFile"
    Write-Host "RESULT: status=FAIL action=jtag-download"
    Write-Host "DIAGNOSTIC: $($_.Exception.Message)"
    exit 1
}
