# Attach-only AX7020 ILA capture. Programming the device is intentionally absent.
if {[llength $argv] != 5} {
    puts stderr "ERROR: capture-ila.tcl expects <ltx> <ila-name-or-empty> <trigger-tcl-or-empty> <csv> <vcd-or-empty>."
    exit 1
}

lassign $argv ltx_file requested_name trigger_tcl csv_file vcd_file
if {$requested_name eq "-"} { set requested_name "" }
if {$trigger_tcl eq "-"} { set trigger_tcl "" }
if {$vcd_file eq "-"} { set vcd_file "" }

proc require_single_ax7020 {} {
    set matches {}
    foreach device [get_hw_devices -quiet] {
        set part [get_property PART $device]
        if {[string match -nocase xc7z020* $part] ||
            [string match -nocase xc7z020* [get_property NAME $device]]} {
            lappend matches $device
        }
    }
    if {[llength $matches] != 1} {
        error "Expected exactly one attached XC7Z020 device; found [llength $matches]: $matches"
    }
    return [lindex $matches 0]
}

proc select_ila {requested_name} {
    set ilas [get_hw_ilas -quiet]
    if {$requested_name eq ""} {
        if {[llength $ilas] != 1} {
            error "Expected exactly one hardware ILA; found [llength $ilas]. Pass -IlaName when multiple ILAs exist."
        }
        return [lindex $ilas 0]
    }

    set matches {}
    foreach ila $ilas {
        foreach property {NAME CELL_NAME DISPLAY_NAME} {
            if {[catch {set value [get_property $property $ila]}]} {
                continue
            }
            if {$value eq $requested_name} {
                lappend matches $ila
                break
            }
        }
    }
    if {[llength $matches] != 1} {
        error "ILA name '$requested_name' must identify exactly one hardware ILA; found [llength $matches]."
    }
    return [lindex $matches 0]
}

if {[catch {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    open_hw_target
    set device [require_single_ax7020]
    current_hw_device $device
    set_property PROBES.FILE $ltx_file $device
    set_property FULL_PROBES.FILE $ltx_file $device
    refresh_hw_device $device

    set ila [select_ila $requested_name]
    current_hw_ila $ila
    set ila_name [get_property NAME $ila]
    puts "CAPTURE_ILA_NAME=$ila_name"
    if {$trigger_tcl eq ""} {
        run_hw_ila $ila -trigger_now
    } else {
        source $trigger_tcl
        current_hw_ila $ila
        run_hw_ila $ila
    }
    wait_on_hw_ila $ila
    set uploaded [upload_hw_ila_data $ila]
    if {[llength $uploaded] == 0} {
        set uploaded [get_hw_ila_data -quiet -of_objects $ila]
    }
    if {[llength $uploaded] == 0} {
        error "ILA upload completed without a hardware data object."
    }
    set data [lindex $uploaded end]
    write_hw_ila_data -force -csv_file $csv_file $data
    if {$vcd_file ne ""} {
        write_hw_ila_data -force -vcd_file $vcd_file $data
    }
    puts "SUCCESS: ILA capture exported."
} message options]} {
    catch {close_hw_target}
    catch {disconnect_hw_server}
    catch {close_hw_manager}
    puts stderr "ERROR: $message"
    if {[dict exists $options -errorinfo]} {
        puts stderr [dict get $options -errorinfo]
    }
    exit 1
}

catch {close_hw_target}
catch {disconnect_hw_server}
catch {close_hw_manager}
