# Temporary JTAG download for an AX7020 PS+PL project.
# Usage from the project root (through a short workspace drive):
# xsct scripts/download-jtag.tcl prj/<project>.bit
# xsct scripts/download-jtag.tcl prj/<project>.bit vitis/fsbl.elf vitis/<application>.elf
#
# This operation configures volatile FPGA fabric and DDR memory only. It does
# not program QSPI Flash. The FSBL must run before the application ELF because
# the application link address normally resides in DDR.

proc fail {message} {
    puts stderr "ERROR: $message"
    exit 1
}

proc target_count {target_listing} {
    set count 0
    foreach line [split $target_listing "\n"] {
        if {[regexp {^[ \t]*[0-9]+[ \t]+} $line]} {
            incr count
        }
    }
    return $count
}

if {[llength $argv] != 1 && [llength $argv] != 3} {
    fail "Expected either a pure-PL bitstream, or bitstream, FSBL, and application ELF paths."
}

set bit_file [file normalize [lindex $argv 0]]
set download_files [list bitstream $bit_file]
if {[llength $argv] == 3} {
    set fsbl_file [file normalize [lindex $argv 1]]
    set elf_file [file normalize [lindex $argv 2]]
    lappend download_files FSBL $fsbl_file application $elf_file
}
foreach {description path} $download_files {
    if {![file isfile $path]} {
        fail "$description file not found: $path"
    }
}

connect
set fpga_targets [targets -filter {name =~ "xc7z020*"}]
if {[target_count $fpga_targets] != 1} {
    fail "Expected exactly one XC7Z020 target; found $fpga_targets"
}
targets -set -filter {name =~ "xc7z020*"}
puts "INFO: Configuring FPGA: $bit_file"
if {[catch {fpga -file $bit_file} message]} {
    fail "FPGA configuration failed: $message"
}

if {[llength $argv] == 1} {
    puts "SUCCESS: Pure-PL JTAG configuration completed."
    exit 0
}

set arm_targets [targets -filter {name =~ "ARM*#0"}]
if {[target_count $arm_targets] != 1} {
    fail "Expected exactly one ARM Cortex-A9 #0 target; found $arm_targets"
}
targets -set -filter {name =~ "ARM*#0"}
puts "INFO: Downloading and starting FSBL for PS/DDR initialization: $fsbl_file"
if {[catch {rst -processor} message]} {
    fail "Processor reset failed: $message"
}
if {[catch {dow $fsbl_file} message]} {
    fail "FSBL download failed: $message"
}
if {[catch {con} message]} {
    fail "FSBL start failed: $message"
}

after 3000
if {[catch {stop} message]} {
    fail "Failed to stop the processor after FSBL initialization: $message"
}
puts "INFO: Downloading application: $elf_file"
if {[catch {dow $elf_file} message]} {
    fail "Application download failed: $message"
}
if {[catch {con} message]} {
    fail "Application start failed: $message"
}
puts "SUCCESS: JTAG download completed; application is running."
