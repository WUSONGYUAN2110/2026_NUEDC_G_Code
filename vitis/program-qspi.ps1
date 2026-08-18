<#
.SYNOPSIS
    Validate and program the published AX7020 QSPI boot artifacts.

.DESCRIPTION
    vitis/run.tcl boot is the only command that generates BOOT.bin and its
    inputs. This script consumes the published BOOT.manifest, BOOT.bin,
    fsbl.elf, application ELF, and prj/<project>.bit without rediscovering or
    rebuilding Vitis projects. The manifest-verified project bitstream is
    configured before program_flash accesses QSPI.
#>
[CmdletBinding()]
param(
    [string]$XilinxRoot,
    [ValidateSet('qspi-x4-single')]
    [string]$FlashType = 'qspi-x4-single',
    [UInt32]$Offset = 0,
    [switch]$YesIHaveConfirmedBoardReady,
    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ManifestPath = Join-Path $PSScriptRoot 'BOOT.manifest'
$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("program-qspi-{0}-pid{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID)
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$FlashCapacityBytes = [UInt64](32MB)

function Write-Log {
    param([string]$Message)
    [IO.File]::AppendAllText($LogFile, $Message + [Environment]::NewLine, $Utf8NoBom)
}

function Write-Summary {
    param([string]$Message)
    Write-Host $Message
    Write-Log $Message
}

function Resolve-ExistingFile {
    param([string]$Description, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Description path is empty." }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer) { return $item.FullName }
    throw "$Description is a directory, not a file: $Path"
}

function Resolve-XilinxTools {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = $env:XILINX_VITIS
    }
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $commands = @(Get-Command -Name 'xsct' -CommandType Application -ErrorAction SilentlyContinue)
        if ($commands.Count -gt 0) {
            $command = $commands[0]
            $xsct = if ($command.Source) { $command.Source } else { $command.Path }
            $Root = Split-Path -Parent (Split-Path -Parent $xsct)
        }
        else {
            $vivadoCommand = @(Get-Command -Name 'vivado' -CommandType Application -ErrorAction Stop)[0]
            $vivado = if ($vivadoCommand.Source) { $vivadoCommand.Source } else { $vivadoCommand.Path }
            $vivadoVersionRoot = Split-Path -Parent (Split-Path -Parent $vivado)
            $version = Split-Path -Leaf $vivadoVersionRoot
            $xilinxRoot = Split-Path -Parent (Split-Path -Parent $vivadoVersionRoot)
            $Root = Join-Path $xilinxRoot "Vitis\$version"
            $xsct = Join-Path $Root 'bin\xsct.bat'
        }
    }
    else {
        $Root = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
        $xsct = Join-Path $Root 'bin\xsct.bat'
    }

    if (-not (Test-Path -LiteralPath $xsct -PathType Leaf)) { throw "xsct.bat not found: $xsct" }
    if ((Split-Path -Leaf $Root) -ne '2022.2') { throw "Xilinx Vitis 2022.2 is required; resolved root: $Root" }

    $programFlash = Join-Path $Root 'bin\program_flash.bat'
    $hwServer = Join-Path $Root 'bin\hw_server.bat'
    if (-not (Test-Path -LiteralPath $programFlash -PathType Leaf)) {
        throw "Xilinx Program Flash executable is missing: $programFlash"
    }
    if (-not (Test-Path -LiteralPath $hwServer -PathType Leaf)) {
        throw "Xilinx hardware server executable is missing: $hwServer"
    }
    return [pscustomobject]@{
        Root = $Root
        Xsct = $xsct
        ProgramFlash = $programFlash
        HwServer = $hwServer
    }
}

function Assert-XsctVersion {
    param([string]$Executable)

    $versionScript = Join-Path ([IO.Path]::GetTempPath()) ("xsct-version-{0}.tcl" -f [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($versionScript, "puts [version]`n", [Text.Encoding]::ASCII)
        Invoke-LoggedNative 'XSCT version check' $Executable @($versionScript) '2022.2'
    }
    finally {
        Remove-Item -LiteralPath $versionScript -Force -ErrorAction SilentlyContinue
    }
}

function Read-BootManifest {
    param([string]$Path)

    $resolved = Resolve-ExistingFile 'BOOT manifest' $Path
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($resolved, [Text.Encoding]::UTF8)) {
        $text = $line.Trim()
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
        $separator = $text.IndexOf('=')
        if ($separator -le 0) { throw "Invalid BOOT manifest line: $line" }
        $key = $text.Substring(0, $separator).Trim()
        $value = $text.Substring($separator + 1).Trim()
        if ($values.ContainsKey($key)) { throw "Duplicate BOOT manifest key: $key" }
        $values[$key] = $value
    }
    return $values
}

function Get-ManifestValue {
    param([hashtable]$Manifest, [string]$Key)
    if (-not $Manifest.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace([string]$Manifest[$Key])) {
        throw "BOOT manifest is missing required key: $Key"
    }
    return [string]$Manifest[$Key]
}

function Resolve-RepositoryRelativeFile {
    param([string]$Description, [string]$RelativePath)

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Description path must be repository-relative: $RelativePath"
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $RepoRoot ($RelativePath -replace '/', '\')))
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description path escapes the repository: $RelativePath"
    }
    return (Resolve-ExistingFile -Description $Description -Path $candidate)
}

function Assert-SamePath {
    param([string]$Description, [string]$Actual, [string]$Expected)
    $actualFull = [IO.Path]::GetFullPath($Actual)
    $expectedFull = [IO.Path]::GetFullPath($Expected)
    if (-not $actualFull.Equals($expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must be the stable published artifact '$expectedFull'; manifest points to '$actualFull'."
    }
}

function Assert-ManifestArtifact {
    param([hashtable]$Manifest, [string]$Key, [string]$Description)

    $relativePath = Get-ManifestValue $Manifest "${Key}_path"
    $path = Resolve-RepositoryRelativeFile $Description $relativePath
    [UInt64]$expectedSize = 0
    if (-not [UInt64]::TryParse((Get-ManifestValue $Manifest "${Key}_size"), [ref]$expectedSize)) {
        throw "Invalid ${Key}_size in BOOT manifest."
    }
    $manifestMtime = Get-ManifestValue $Manifest "${Key}_mtime"
    $item = Get-Item -LiteralPath $path
    if ([UInt64]$item.Length -ne $expectedSize -or $item.Length -le 0) {
        throw "$Description size does not match BOOT.manifest. Re-run the Vitis boot step."
    }
    $expectedSha256 = Get-ManifestValue $Manifest "${Key}_sha256"
    $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $sha256.Equals($expectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description SHA-256 does not match BOOT.manifest. Re-run the Vitis boot step."
    }
    Write-Log ("ARTIFACT: kind={0} path={1} size={2} manifest_mtime={3} sha256={4}" -f `
        $Key, $path, $item.Length, $manifestMtime, $sha256)
    return [pscustomobject]@{
        Path = $path
        Item = $item
        Sha256 = $sha256
    }
}

function Invoke-LoggedNative {
    param(
        [string]$Title,
        [string]$Exe,
        [string[]]$Arguments,
        [string]$RequiredSuccessMarker
    )

    Write-Log ''
    Write-Log "===== $Title ====="
    Write-Log ("COMMAND: `"{0}`" {1}" -f $Exe, ($Arguments -join ' '))
    Write-Summary "DETAIL: stage=$Title status=started"
    $startLine = [IO.File]::ReadAllLines($LogFile).Length
    $exitCode = -1
    $invocationError = $null
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 | Out-File -LiteralPath $LogFile -Append -Encoding utf8
        if ($null -ne $LASTEXITCODE) { $exitCode = [int]$LASTEXITCODE }
    }
    catch {
        $invocationError = $_
        $_ | Out-String | Out-File -LiteralPath $LogFile -Append -Encoding utf8
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Write-Log "EXITCODE: $exitCode"

    $stageLines = @(Get-Content -LiteralPath $LogFile -Encoding UTF8 | Select-Object -Skip $startLine)
    $errorLines = @($stageLines | Select-String -Pattern '(ERROR:|FATAL:|\[ERROR\])')
    if ($null -ne $invocationError) {
        throw "$Title could not be invoked: $($invocationError.Exception.Message). Log: $LogFile"
    }
    if ($exitCode -ne 0) { throw "$Title failed with exit code $exitCode. Log: $LogFile" }
    if ($errorLines.Count -gt 0) {
        throw "$Title printed an error: $($errorLines[-1].Line.Trim()). Log: $LogFile"
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredSuccessMarker) -and
        -not ($stageLines | Select-String -Pattern $RequiredSuccessMarker -SimpleMatch -Quiet)) {
        throw "$Title did not print required success marker '$RequiredSuccessMarker'. Log: $LogFile"
    }
    Write-Summary "DETAIL: stage=$Title status=completed"
}

function Start-LocalHwServer {
    param([Parameter(Mandatory)][string]$Executable)

    $existing = @(Get-NetTCPConnection -State Listen -LocalPort 3121 -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        $owners = @($existing | Select-Object -ExpandProperty OwningProcess -Unique)
        if ($owners.Count -ne 1) {
            throw "Multiple processes are listening on TCP port 3121: $($owners -join ', ')."
        }
        Write-Log "HW_SERVER: reusing listener pid=$($owners[0]) url=TCP:127.0.0.1:3121"
        return [pscustomobject]@{
            Url = 'TCP:127.0.0.1:3121'
            OwnedProcessId = $null
        }
    }

    $stdout = "$LogFile.hw-server.stdout.log"
    $stderr = "$LogFile.hw-server.stderr.log"
    $launcher = Start-Process -FilePath $Executable -ArgumentList '-q' -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 3121 -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            $owners = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
            if ($owners.Count -ne 1) {
                throw "Multiple processes are listening on TCP port 3121: $($owners -join ', ')."
            }
            Write-Log "HW_SERVER: started launcher_pid=$($launcher.Id) listener_pid=$($owners[0]) url=TCP:127.0.0.1:3121"
            return [pscustomobject]@{
                Url = 'TCP:127.0.0.1:3121'
                OwnedProcessId = [int]$owners[0]
            }
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $launcher.HasExited) {
        Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue
    }
    throw "hw_server did not open TCP port 3121. Review $stdout and $stderr."
}

function Stop-LocalHwServer {
    param($Server)

    if ($null -ne $Server -and $null -ne $Server.OwnedProcessId) {
        Stop-Process -Id $Server.OwnedProcessId -Force -ErrorAction SilentlyContinue
        Write-Log "HW_SERVER: stopped listener pid=$($Server.OwnedProcessId)"
    }
}

function Write-PreflightSummary {
    $matches = @(Select-String -LiteralPath $LogFile -Pattern 'INFO: (FPGA_TARGET|ARM_TARGET):' |
        Select-Object -Last 2)
    foreach ($match in $matches) {
        Write-Summary ("DETAIL: {0}" -f $match.Line.Trim())
    }
}

function Invoke-QspiWorkflow {
    Write-Summary 'RUN: tool=qspi'
    Write-Summary "LOG: $LogFile"

    $tools = Resolve-XilinxTools $XilinxRoot
    $Xsct = $tools.Xsct
    $ProgramFlash = $tools.ProgramFlash
    $HwServer = $tools.HwServer
    $resolvedXilinxRoot = $tools.Root
    Write-Log "XILINX_ROOT: $resolvedXilinxRoot"
    Assert-XsctVersion $Xsct

    $manifest = Read-BootManifest $ManifestPath
    if ((Get-ManifestValue $manifest 'manifest_version') -ne '1') {
        throw 'Unsupported BOOT.manifest version. Re-run the Vitis boot step.'
    }
    $projectName = Get-ManifestValue $manifest 'project_name'
    $applicationName = Get-ManifestValue $manifest 'application_name'
    if ($projectName -notmatch '^[A-Za-z0-9_]+$' -or $applicationName -notmatch '^[A-Za-z0-9_]+$') {
        throw 'Invalid project or application name in BOOT.manifest.'
    }
    if ((Get-ManifestValue $manifest 'flash_type') -ne $FlashType) {
        throw "Flash type does not match BOOT.manifest. Expected: $(Get-ManifestValue $manifest 'flash_type')"
    }
    if ($FlashType -ne 'qspi-x4-single') { throw 'AX7020 supports only qspi-x4-single in this workflow.' }
    if ($Offset -ne 0 -or (Get-ManifestValue $manifest 'offset') -ne '0') {
        throw 'AX7020 QSPI cold-boot BOOT.bin must be programmed at offset 0.'
    }
    [UInt64]$manifestCapacity = 0
    if (-not [UInt64]::TryParse((Get-ManifestValue $manifest 'flash_capacity'), [ref]$manifestCapacity) -or
        $manifestCapacity -ne $FlashCapacityBytes) {
        throw 'BOOT.manifest Flash capacity does not match the AX7020 W25Q256 (32 MiB).'
    }

    $boot = Assert-ManifestArtifact $manifest 'boot_bin' 'BOOT.bin'
    $fsbl = Assert-ManifestArtifact $manifest 'fsbl' 'FSBL ELF'
    $bit = Assert-ManifestArtifact $manifest 'bitstream' 'bitstream'
    $elf = Assert-ManifestArtifact $manifest 'application_elf' 'application ELF'

    Assert-SamePath 'BOOT.bin' $boot.Path (Join-Path $PSScriptRoot 'BOOT.bin')
    Assert-SamePath 'FSBL ELF' $fsbl.Path (Join-Path $PSScriptRoot 'fsbl.elf')
    Assert-SamePath 'bitstream' $bit.Path (Join-Path $RepoRoot "prj\${projectName}.bit")
    Assert-SamePath 'application ELF' $elf.Path (Join-Path $PSScriptRoot "${applicationName}.elf")

    $imageEnd = [UInt64]$Offset + [UInt64]$boot.Item.Length
    if ($imageEnd -gt $FlashCapacityBytes) {
        throw "BOOT.bin exceeds the AX7020 W25Q256 capacity at offset $Offset."
    }
    Write-Log ("PROGRAM_PLAN: flash_type={0} offset={1} image_size={2} image_end={3} capacity={4}" -f `
        $FlashType, $Offset, $boot.Item.Length, $imageEnd, $FlashCapacityBytes)
    Write-Summary ("DETAIL: flash_type={0} offset={1} image_size={2} boot_sha256={3}" -f `
        $FlashType, $Offset, $boot.Item.Length, $boot.Sha256)

    $PreflightTcl = Join-Path ([IO.Path]::GetTempPath()) ("qspi_preflight_{0}.tcl" -f ([Guid]::NewGuid().ToString('N')))
    $ConfigureTcl = Join-Path ([IO.Path]::GetTempPath()) ("qspi_configure_{0}.tcl" -f ([Guid]::NewGuid().ToString('N')))
    $flashServer = $null
    try {
        @'
proc fail {message} { puts stderr "ERROR: $message"; exit 1 }
proc target_count {target_listing} {
    set count 0
    foreach line [split $target_listing "\n"] {
        if {[regexp {^[ \t]*[0-9]+[ \t]+} $line]} {
            incr count
        }
    }
    return $count
}
connect
set fpga_targets [targets -filter {name =~ "xc7z020*"}]
if {[target_count $fpga_targets] != 1} { fail "Expected exactly one XC7Z020 target; found $fpga_targets" }
puts "INFO: FPGA_TARGET: $fpga_targets"
set arm_targets [targets -filter {name =~ "ARM*#0"}]
if {[target_count $arm_targets] != 1} { fail "Expected exactly one ARM#0 target; found $arm_targets" }
puts "INFO: ARM_TARGET: $arm_targets"
targets -set -filter {name =~ "ARM*#0"}
puts "INFO: QSPI_PREFLIGHT_DONE"
'@ | Set-Content -LiteralPath $PreflightTcl -Encoding ASCII

        if ($PreflightOnly) {
            Invoke-LoggedNative 'JTAG preflight' $Xsct @($PreflightTcl) 'QSPI_PREFLIGHT_DONE'
            Write-PreflightSummary
            Write-Summary 'RESULT: status=PASS action=qspi-preflight'
            Write-Summary 'SUCCESS: QSPI preflight completed.'
            return
        }

        if (-not $YesIHaveConfirmedBoardReady) {
            throw 'Board operation not confirmed. Run -PreflightOnly first, then re-run with -YesIHaveConfirmedBoardReady after confirming the reported target, power, JTAG, Flash type, and offset.'
        }

        Write-Summary ("DETAIL: fpga_config_source=manifest_project_bitstream path={0} sha256={1}" -f `
            $bit.Path, $bit.Sha256)

        @'
proc fail {message} { puts stderr "ERROR: $message"; exit 1 }
proc target_count {target_listing} {
    set count 0
    foreach line [split $target_listing "\n"] {
        if {[regexp {^[ \t]*[0-9]+[ \t]+} $line]} {
            incr count
        }
    }
    return $count
}
if {[llength $argv] != 1} { fail "Expected the project bitstream path." }
set bit_file [lindex $argv 0]
connect
set fpga_targets [targets -filter {name =~ "xc7z020*"}]
if {[target_count $fpga_targets] != 1} { fail "Expected exactly one XC7Z020 target; found $fpga_targets" }
targets -set -filter {name =~ "xc7z020*"}
puts "INFO: Configuring FPGA bitstream before Flash access: $bit_file"
if {[catch {fpga -file $bit_file} fpga_message]} { fail "FPGA configuration failed: $fpga_message" }
puts "INFO: FPGA_CONFIGURATION_DONE"
'@ | Set-Content -LiteralPath $ConfigureTcl -Encoding ASCII

        Invoke-LoggedNative 'JTAG preflight' $Xsct @($PreflightTcl) 'QSPI_PREFLIGHT_DONE'
        Write-PreflightSummary
        Invoke-LoggedNative 'FPGA configuration for Flash access' $Xsct @(
            $ConfigureTcl,
            $bit.Path
        ) 'FPGA_CONFIGURATION_DONE'
        $flashServer = Start-LocalHwServer -Executable $HwServer
        Invoke-LoggedNative 'program_flash' $ProgramFlash @(
            '-f', $boot.Path,
            '-offset', [string]$Offset,
            '-flash_type', $FlashType,
            '-fsbl', $fsbl.Path,
            '-verify',
            '-url', $flashServer.Url
        ) 'Flash Operation Successful'
    }
    finally {
        Remove-Item -LiteralPath $PreflightTcl -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ConfigureTcl -Force -ErrorAction SilentlyContinue
        Stop-LocalHwServer $flashServer
    }

    Write-Summary 'RESULT: status=PASS action=qspi-program'
    Write-Summary 'SUCCESS: QSPI programming completed.'
    Write-Summary 'NEXT: Verify cold-start behavior manually.'
}

try {
    Invoke-QspiWorkflow
}
catch {
    Write-Log ("ERROR_DETAIL: {0}" -f ($_ | Out-String).Trim())
    Write-Summary 'RESULT: status=FAIL action=qspi'
    Write-Summary ("DIAGNOSTIC: {0}" -f $_.Exception.Message)
    exit 1
}
