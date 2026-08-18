# Vivado 工程管理脚本
# 在仓库根目录使用以下命令执行：
# vivado -mode batch -nolog -nojournal -notrace \
#        -tempDir "<仓库绝对路径>/prj/.Xil" \
#        -source prj/run.tcl -tclargs <create|ip|bd|synth|build|sim|all>

set script_dir    [file dirname [file normalize [info script]]]
set root_dir      [file dirname $script_dir]

set config_file [file join $root_dir config.tcl]
if {![file isfile $config_file]} {
    error "Shared configuration file is missing: $config_file"
}
source $config_file

set proj_name     $template_config(proj_name)
set top_name      $template_config(top_name)
set default_tb    $template_config(default_tb)
set default_time  $template_config(default_time)
set part          $template_config(part)
set num_jobs      $template_config(num_jobs)
set use_bd        $template_config(use_bd)
set enable_ila    $template_config(enable_ila)
set ila_clock_net $template_config(ila_clock_net)
set ila_probe_patterns $template_config(ila_probe_patterns)
set ila_data_depth $template_config(ila_data_depth)
set check_hardware_state unknown
set project_file  [file join $script_dir "${proj_name}.xpr"]

set step [lindex $argv 0]
if {$step eq ""} {
    puts "Usage: vivado ... -source prj/run.tcl -tclargs <step>"
    puts "Steps: check | create | sync | ip | bd | synth | build | sim | all"
    puts stderr "ERROR: Missing step."
    exit 1
}

proc require_vivado_version {} {
    set detected [version -short]
    if {![regexp {^2022\.2(?:$|[^0-9])} $detected]} {
        error "Vivado 2022.2 is required; detected '$detected'."
    }
    puts "Vivado version check passed: 2022.2"
}

proc emit_phase_metric {name started_ms} {
    set elapsed [expr {([clock milliseconds] - $started_ms) / 1000.0}]
    puts [format "METRIC: %s_seconds=%.3f" $name $elapsed]
}

proc require_no_parent_critical_warnings {} {
    # Vivado does not include launch_runs subprocess messages in this count;
    # the PowerShell launcher performs the final complete-log check and rolls
    # back a started publication transaction if subprocess warnings remain.
    set count [get_msg_config -severity {CRITICAL WARNING} -count]
    if {$count > 0} {
        error "Vivado reported $count Critical Warning(s); refusing stable hardware publication."
    }
}

# 只删除 prj/ 目录下由工程名称派生的已知生成路径。
proc delete_generated_path {path} {
    global script_dir

    set base   [string map {\\ /} [file normalize $script_dir]]
    set target [string map {\\ /} [file normalize $path]]
    set parent [string map {\\ /} [file dirname $target]]

    if {![string equal -nocase $parent $base]} {
        error "Refusing to delete path outside the prj/ root: $target"
    }

    if {[file exists $target]} {
        puts "Deleting old generated path: $target"
        file delete -force -- $target
    }
}

# prj/ 是单工程目录。创建配置的 XPR 前，先删除旧工程及其已知生成目录。
proc clean_old_projects {} {
    global script_dir proj_name

    set old_names [list $proj_name]
    foreach xpr [glob -nocomplain -types f [file join $script_dir *.xpr]] {
        lappend old_names [file rootname [file tail $xpr]]
    }

    foreach old_name [lsort -unique $old_names] {
        foreach suffix {
            .xpr .bit .xsa .ltx .hardware.manifest .structure.manifest
            .mark_debug.xdc .ila_debug.xdc .ila_post.tcl .cache .gen .hw .incremental
            .ioplanning .ip_user_files .runs .sim .srcs
        } {
            delete_generated_path [file join $script_dir "${old_name}${suffix}"]
        }
        foreach sidecar_bit [glob -nocomplain -types f \
                [file join $script_dir ".${old_name}.*.bit"]] {
            delete_generated_path $sidecar_bit
        }
    }
    delete_generated_path [file join $script_dir aie_primitive.json]
}

proc glob_files {dir patterns} {
    set result {}
    foreach pattern $patterns {
        lappend result {*}[glob -nocomplain -types f [file join $dir $pattern]]
    }
    return [lsort -unique $result]
}

proc glob_files_recursive {dir patterns} {
    if {![file isdirectory $dir]} {
        return {}
    }
    set result [glob_files $dir $patterns]
    foreach child [glob -nocomplain -types d -directory $dir *] {
        lappend result {*}[glob_files_recursive $child $patterns]
    }
    return [lsort -unique $result]
}

proc normalized_path {path} {
    return [string map {\\ /} [file normalize $path]]
}

proc path_is_under {path directory} {
    set candidate [string tolower [normalized_path $path]]
    set base [string trimright [string tolower [normalized_path $directory]] /]
    return [expr {[string first "${base}/" $candidate] == 0}]
}

proc normalized_file_list {files} {
    set result {}
    foreach path $files {
        lappend result [normalized_path $path]
    }
    return [lsort -dictionary -unique $result]
}

proc discover_persistent_files {} {
    global root_dir

    set rtl_dir [file join $root_dir rtl]
    set sim_dir [file join $root_dir sim]
    return [dict create \
        rtl [normalized_file_list [glob_files_recursive $rtl_dir {*.v *.sv *.vh *.svh *.mem *.hex *.coe}]] \
        xdc  [normalized_file_list [glob_files_recursive $rtl_dir {*.xdc}]] \
        sim  [normalized_file_list [glob_files_recursive $sim_dir {*.v *.sv *.vh *.svh *.mem *.hex}]]]
}

proc header_directories {files} {
    set result {}
    foreach path $files {
        if {[lsearch -exact {.vh .svh} [string tolower [file extension $path]]] >= 0} {
            lappend result [file dirname $path]
        }
    }
    return [lsort -dictionary -unique $result]
}

proc configure_persistent_include_dirs {} {
    set persistent [discover_persistent_files]
    set rtl_dirs [header_directories [dict get $persistent rtl]]
    set sim_dirs [header_directories [concat \
        [dict get $persistent rtl] [dict get $persistent sim]]]
    set_property include_dirs $rtl_dirs [get_filesets sources_1]
    set_property include_dirs $sim_dirs [get_filesets sim_1]
}

# 创建工程前做轻量静态检查，避免明显配置错误先删除旧工程。
proc rtl_declares_module {rtl_files module_name} {
    foreach rtl_file $rtl_files {
        if {[lsearch -exact {.v .sv} [string tolower [file extension $rtl_file]]] < 0} {
            continue
        }
        set channel [open $rtl_file r]
        fconfigure $channel -encoding utf-8
        set contents [read $channel]
        close $channel

        foreach line [split $contents "\n"] {
            if {[regexp {^[ \t]*(\(\*.*\*\)[ \t]*)*module[ \t]+([A-Za-z_][A-Za-z0-9_$]*)} \
                    $line -> attributes declared_name] && $declared_name eq $module_name} {
                return 1
            }
        }
    }
    return 0
}

proc validate_configuration {action {tb_top ""}} {
    global template_config proj_name top_name default_tb part num_jobs use_bd \
        enable_ila ila_clock_net ila_probe_patterns ila_data_depth
    set required {
        proj_name top_name default_tb default_time part num_jobs use_bd
        enable_qspi_boot enable_uart1 uart1_io enable_sd0 enable_gpio_mio
        enable_fclk0 fclk0_mhz enable_ila ila_clock_net ila_probe_patterns
        ila_data_depth platform_name app_name domain_name processor os_name
        app_template boot_mode
    }
    foreach key $required {
        if {![info exists template_config($key)]} { error "Missing config key: $key" }
    }
    set booleans {
        use_bd enable_qspi_boot enable_uart1 enable_sd0 enable_gpio_mio
        enable_fclk0 enable_ila
    }
    foreach key $booleans {
        if {$template_config($key) ni {0 1}} { error "$key must be exactly 0 or 1: $template_config($key)" }
    }
    if {$part ne "xc7z020clg400-2"} { error "AX7020 part must be xc7z020clg400-2: $part" }
    if {![string is integer -strict $num_jobs] || $num_jobs < 1} { error "num_jobs must be a positive integer: $num_jobs" }
    foreach key {proj_name platform_name app_name domain_name} {
        if {![regexp {^[A-Za-z0-9_]+$} $template_config($key)]} { error "$key allows only letters, digits, and underscores." }
    }
    if {[lsearch -exact {{MIO 8 .. 9} {MIO 48 .. 49}} $template_config(uart1_io)] < 0} { error "Invalid uart1_io: $template_config(uart1_io)" }
    if {![string is double -strict $template_config(fclk0_mhz)] ||
        $template_config(fclk0_mhz) <= 0.0 || $template_config(fclk0_mhz) > 250.0} {
        error "fclk0_mhz must be in (0,250]: $template_config(fclk0_mhz)"
    }
    set boot_mode $template_config(boot_mode)
    if {[lsearch -exact {ps_pl_qspi ps_pl_sd ps_pl_qspi_sd jtag none} $boot_mode] < 0} { error "Unsupported boot_mode: $boot_mode" }
    if {!$use_bd} {
        foreach key {enable_qspi_boot enable_uart1 enable_sd0 enable_gpio_mio enable_fclk0} {
            if {$template_config($key)} { error "$key requires use_bd=1." }
        }
        if {$boot_mode ne "none"} { error "Pure PL requires boot_mode=none." }
    }
    if {[lsearch -exact {ps_pl_qspi ps_pl_qspi_sd} $boot_mode] >= 0 &&
        !$template_config(enable_qspi_boot)} { error "$boot_mode requires enable_qspi_boot=1." }
    if {[lsearch -exact {ps_pl_sd ps_pl_qspi_sd} $boot_mode] >= 0 &&
        !$template_config(enable_sd0)} { error "$boot_mode requires enable_sd0=1." }
    if {![string is integer -strict $ila_data_depth] ||
        [lsearch -exact {1024 2048 4096 8192 16384 32768 65536 131072} $ila_data_depth] < 0} {
        error "Unsupported ila_data_depth: $ila_data_depth"
    }
    if {$enable_ila} {
        if {[string trim $ila_clock_net] eq ""} { error "enable_ila requires ila_clock_net." }
        if {![llength $ila_probe_patterns]} { error "enable_ila requires ila_probe_patterns." }
    }
    if {$proj_name eq "Project"} { puts "WARNING: proj_name still uses the template default." }
    if {!$use_bd && [lsearch -exact {check create sync all} $action] >= 0 &&
        $top_name eq "TOP_MODULE"} { error "Set top_name when use_bd=0; TOP_MODULE is a placeholder." }
    if {$action eq "sim" && $tb_top eq $default_tb &&
        $default_tb eq "TESTBENCH_MODULE"} { error "Set default_tb or pass -TbTop; TESTBENCH_MODULE is a placeholder." }
}

proc validate_create_inputs {} {
    global script_dir root_dir top_name use_bd

    validate_configuration create

    set bd_script [file join $script_dir bd.tcl]
    set persistent [discover_persistent_files]
    set rtl_files [dict get $persistent rtl]
    if {$use_bd && ![file isfile $bd_script]} {
        error "use_bd is 1, but Block Design script does not exist: $bd_script"
    }
    if {!$use_bd} {
        if {[llength $rtl_files] == 0} {
            error "No Verilog/SystemVerilog sources found under rtl/."
        }
        if {![regexp {^[A-Za-z_][A-Za-z0-9_$]*$} $top_name]} {
            error "Invalid pure-PL top module name: $top_name"
        }
        if {![rtl_declares_module $rtl_files $top_name]} {
            error "Configured pure-PL top '$top_name' is not declared under rtl/."
        }
    }
    return $rtl_files
}

proc do_create {} {
    global script_dir root_dir proj_name top_name default_tb part project_file use_bd

    set rtl_files [validate_create_inputs]
    set persistent [discover_persistent_files]
    invalidate_published_hardware 1
    clean_old_projects
    create_project $proj_name $script_dir -part $part
    set_property default_lib xil_defaultlib [current_project]

    if {[llength $rtl_files] > 0} {
        add_files -norecurse -fileset sources_1 $rtl_files
        update_compile_order -fileset sources_1
    }

    set xdc_files [dict get $persistent xdc]
    if {[llength $xdc_files] > 0} {
        add_files -norecurse -fileset constrs_1 $xdc_files
    }

    set sim_files [dict get $persistent sim]
    if {[llength $sim_files] > 0} {
        add_files -norecurse -fileset sim_1 $sim_files
        set_property top $default_tb [get_filesets sim_1]
        update_compile_order -fileset sim_1
    }
    configure_persistent_include_dirs

    if {$use_bd} {
        puts "Block Design enabled; synthesis top will be set by the bd step."
    } else {
        if {[lsearch -exact [find_top] $top_name] < 0} {
            error "Configured top '$top_name' not found in RTL sources"
        }
        set_property top $top_name [get_filesets sources_1]
        update_compile_order -fileset sources_1
        puts "Synthesis top: $top_name"
    }

    puts "Project created: [file normalize $project_file]"
    write_structure_manifest
}

proc sha256_file {path} {
    set output [exec certutil -hashfile $path SHA256]
    if {![regexp -nocase {[0-9a-f]{64}} $output hash]} {
        error "Unable to calculate SHA-256 for: $path"
    }
    return [string tolower $hash]
}

proc read_key_value_file {path} {
    if {![file isfile $path]} {
        error "Manifest does not exist: $path"
    }
    set values [dict create]
    set channel [open $path r]
    fconfigure $channel -encoding utf-8
    while {[gets $channel line] >= 0} {
        set text [string trim $line]
        if {$text eq "" || [string index $text 0] eq "#"} {
            continue
        }
        set separator [string first = $text]
        if {$separator <= 0} {
            close $channel
            error "Invalid manifest line in $path: $line"
        }
        set key [string trim [string range $text 0 [expr {$separator - 1}]]]
        set value [string trim [string range $text [expr {$separator + 1}] end]]
        if {[dict exists $values $key]} {
            close $channel
            error "Duplicate manifest key '$key' in $path"
        }
        dict set values $key $value
    }
    close $channel
    return $values
}

proc write_key_value_file {path values} {
    set temp_file "${path}.tmp.[pid]"
    catch {file delete -force -- $temp_file}
    set channel [open $temp_file w]
    fconfigure $channel -encoding utf-8 -translation lf
    foreach key [lsort [dict keys $values]] {
        puts $channel "$key=[dict get $values $key]"
    }
    close $channel
    file rename -force -- $temp_file $path
}

proc optional_file_hash {path} {
    if {![file isfile $path]} {
        return "absent"
    }
    return [sha256_file $path]
}

proc current_structure_values {} {
    global template_config script_dir part top_name use_bd

    set values [dict create \
        manifest_version 1 \
        part $part \
        top_name $top_name \
        use_bd $use_bd \
        bd_tcl_sha256 [optional_file_hash [file join $script_dir bd.tcl]] \
        ip_tcl_sha256 [optional_file_hash [file join $script_dir ip.tcl]]]
    foreach key {
        enable_qspi_boot enable_uart1 uart1_io enable_sd0 enable_gpio_mio
        enable_fclk0 fclk0_mhz
    } {
        dict set values $key $template_config($key)
    }
    return $values
}

proc structure_manifest_path {} {
    global script_dir proj_name
    return [file join $script_dir "${proj_name}.structure.manifest"]
}

proc write_structure_manifest {} {
    set path [structure_manifest_path]
    write_key_value_file $path [current_structure_values]
    puts "Project structure manifest updated: [normalized_path $path]"
}

proc assert_project_structure_current {} {
    global part top_name use_bd

    set path [structure_manifest_path]
    if {![file isfile $path]} {
        error "Project structure manifest is missing. Run Vivado all once."
    }
    set recorded [read_key_value_file $path]
    set expected [current_structure_values]
    foreach key [dict keys $expected] {
        if {![dict exists $recorded $key] ||
            [dict get $recorded $key] ne [dict get $expected $key]} {
            set old_value [expr {[dict exists $recorded $key] ?
                [dict get $recorded $key] : "<missing>"}]
            error "Project structure changed at '$key' (project=$old_value config=[dict get $expected $key]). Run Vivado all."
        }
    }
    set project_part [get_property PART [current_project]]
    if {$project_part ne $part} {
        error "Open project part is '$project_part', expected '$part'. Run Vivado all."
    }
    set bd_files [get_files -quiet *.bd]
    if {$use_bd && [llength $bd_files] != 1} {
        error "use_bd=1 expects one Block Design in the project; found [llength $bd_files]. Run Vivado all."
    }
    if {!$use_bd && [llength $bd_files] != 0} {
        error "use_bd=0 but the project contains a Block Design. Run Vivado all."
    }
    if {!$use_bd && [get_property TOP [get_filesets sources_1]] ne $top_name} {
        error "Pure-PL synthesis top changed. Run Vivado all."
    }
}

proc project_persistent_files {kind} {
    global root_dir

    switch $kind {
        rtl {
            set fileset [get_filesets sources_1]
            set directory [file join $root_dir rtl]
            set extensions {.v .sv .vh .svh .mem .hex .coe}
        }
        xdc {
            set fileset [get_filesets constrs_1]
            set directory [file join $root_dir rtl]
            set extensions {.xdc}
        }
        sim {
            set fileset [get_filesets sim_1]
            set directory [file join $root_dir sim]
            set extensions {.v .sv .vh .svh .mem .hex}
        }
        default { error "Unknown persistent file kind: $kind" }
    }

    set result {}
    foreach file_object [get_files -quiet -of_objects $fileset] {
        set path [get_property NAME $file_object]
        if {$path eq ""} {
            set path $file_object
        }
        if {[path_is_under $path $directory] &&
            [lsearch -exact $extensions [string tolower [file extension $path]]] >= 0} {
            lappend result [normalized_path $path]
        }
    }
    return [lsort -dictionary -unique $result]
}

proc list_difference_nocase {left right} {
    set right_keys [dict create]
    foreach value $right {
        dict set right_keys [string tolower $value] 1
    }
    set result {}
    foreach value $left {
        if {![dict exists $right_keys [string tolower $value]]} {
            lappend result $value
        }
    }
    return $result
}

proc persistent_file_drift {} {
    set disk [discover_persistent_files]
    set result [dict create]
    foreach kind {rtl xdc sim} {
        set project [project_persistent_files $kind]
        dict set result "${kind}_added" [list_difference_nocase \
            [dict get $disk $kind] $project]
        dict set result "${kind}_removed" [list_difference_nocase \
            $project [dict get $disk $kind]]
    }
    return $result
}

proc drift_has_changes {drift} {
    foreach key [dict keys $drift] {
        if {[llength [dict get $drift $key]] > 0} {
            return 1
        }
    }
    return 0
}

proc drift_summary {drift} {
    set fields {}
    foreach kind {rtl xdc sim} {
        foreach direction {added removed} {
            set key "${kind}_${direction}"
            lappend fields "${key}=[llength [dict get $drift $key]]"
        }
    }
    return [join $fields " "]
}

proc assert_persistent_file_sets_current {} {
    set drift [persistent_file_drift]
    if {[drift_has_changes $drift]} {
        set details {}
        foreach key [dict keys $drift] {
            if {[llength [dict get $drift $key]] > 0} {
                lappend details "$key={[join [dict get $drift $key] {, }]}"
            }
        }
        error "Persistent file-set drift detected: [join $details {; }]. Run Vivado sync."
    }
}

proc remove_project_files {paths} {
    foreach path $paths {
        set objects [get_files -quiet $path]
        if {[llength $objects] == 0} {
            error "Project file disappeared while synchronizing: $path"
        }
        remove_files $objects
    }
}

proc do_sync {} {
    global default_tb top_name use_bd

    validate_configuration sync
    assert_project_structure_current
    set drift [persistent_file_drift]
    puts "SYNC: [drift_summary $drift]"
    if {![drift_has_changes $drift]} {
        puts "Persistent source files already match the project."
        return
    }

    set hardware_changed [expr {
        [llength [dict get $drift rtl_added]] > 0 ||
        [llength [dict get $drift rtl_removed]] > 0 ||
        [llength [dict get $drift xdc_added]] > 0 ||
        [llength [dict get $drift xdc_removed]] > 0}]
    if {$hardware_changed} {
        invalidate_published_hardware 1
    }

    remove_project_files [dict get $drift rtl_removed]
    remove_project_files [dict get $drift xdc_removed]
    remove_project_files [dict get $drift sim_removed]
    foreach {kind fileset} {rtl sources_1 xdc constrs_1 sim sim_1} {
        set paths [dict get $drift "${kind}_added"]
        if {[llength $paths] > 0} {
            add_files -norecurse -fileset $fileset $paths
        }
    }
    configure_persistent_include_dirs
    update_compile_order -fileset sources_1
    if {[llength [get_files -quiet -of_objects [get_filesets sim_1]]] > 0} {
        set_property top $default_tb [get_filesets sim_1]
        update_compile_order -fileset sim_1
    }
    if {!$use_bd} {
        if {[lsearch -exact [find_top] $top_name] < 0} {
            error "Configured top '$top_name' is not available after synchronization."
        }
        set_property top $top_name [get_filesets sources_1]
    }

    if {$hardware_changed} {
        set synth_run [get_runs -quiet synth_1]
        if {[llength $synth_run] > 0 &&
            [get_property STATUS $synth_run] ne "Not started"} {
            reset_runs synth_1
        }
    }
    puts "Source synchronization completed; hardware_invalidated=$hardware_changed."
}

proc do_check {} {
    global project_file default_tb use_bd check_hardware_state

    validate_configuration check
    set rtl_files [validate_create_inputs]
    set persistent [discover_persistent_files]
    set sim_files [dict get $persistent sim]
    if {[llength $sim_files] > 0} {
        if {$default_tb eq "TESTBENCH_MODULE"} {
            error "Simulation sources exist, but default_tb is still TESTBENCH_MODULE."
        }
        if {![rtl_declares_module $sim_files $default_tb]} {
            error "Configured default_tb '$default_tb' is not declared under sim/."
        }
    }
    puts "CHECK: rtl=[llength $rtl_files] xdc=[llength [dict get $persistent xdc]] sim=[llength $sim_files] use_bd=$use_bd"

    if {![file isfile $project_file]} {
        set check_hardware_state [verify_hardware_manifest_if_published 0]
        puts "CHECK: project=absent; configuration and persistent inputs are valid."
        return
    }
    open_project $project_file
    assert_project_structure_current
    set drift [persistent_file_drift]
    puts "CHECK: [drift_summary $drift]"
    if {[drift_has_changes $drift]} {
        puts "NEXT: Vivado sync"
        error "Project file sets do not match persistent sources ([drift_summary $drift]). Run Vivado sync."
    }
    set check_hardware_state [verify_hardware_manifest_if_published]
    puts "Configuration check passed: [normalized_path $project_file]"
}

# 项目专用 IP 配置入口（按需添加 create_ip 调用）。
proc do_ip {} {
    global script_dir

    set ip_script [file join $script_dir ip.tcl]
    if {![file isfile $ip_script]} {
        puts "No custom IP script found; skipping IP step: $ip_script"
        return
    }

    puts "Sourcing custom IP script: $ip_script"
    source $ip_script
    puts "Custom IP script completed: $ip_script"
}

# 执行单个 Block Design 的配置（PS7 初始化等）。
# use_bd=1 时执行 prj/bd.tcl；use_bd=0 时跳过（适用于纯 PL 设计）。
proc do_bd {} {
    global script_dir use_bd
    set bd_script [file join $script_dir bd.tcl]
    if {!$use_bd} {
        puts "use_bd=0; skipping Block Design step (pure PL design)."
        return
    }
    if {![file isfile $bd_script]} {
        error "use_bd is 1, but Block Design script does not exist: $bd_script"
    }

    # bd.tcl 只负责创建 Block Design；工程生命周期由此处统一管理。
    # 仅移除已有 BD 对应的精确 Wrapper，避免影响用户自己的 *_wrapper RTL。
    set old_bds [get_files -quiet *.bd]
    foreach old_bd $old_bds {
        set old_design [file rootname [file tail $old_bd]]
        set wrapper_stem "${old_design}_wrapper"
        foreach source_file [get_files -quiet] {
            set extension [string tolower [file extension $source_file]]
            if {[file rootname [file tail $source_file]] eq $wrapper_stem &&
                [lsearch -exact {.v .sv .vhd .vhdl} $extension] >= 0} {
                remove_files $source_file
            }
        }
        if {[llength [get_bd_designs -quiet $old_design]] > 0} {
            close_bd_design [get_bd_designs $old_design]
        }
        remove_files $old_bd
    }

    source $bd_script

    set bd_files [get_files -quiet *.bd]
    if {[llength $bd_files] != 1} {
        error "Expected exactly one Block Design after sourcing bd.tcl; found: $bd_files"
    }

    set bd_file    [lindex $bd_files 0]
    set design_name [file rootname [file tail $bd_file]]
    current_bd_design $design_name
    validate_bd_design
    save_bd_design
    generate_target all $bd_file

    set wrapper [make_wrapper -files $bd_file -top]
    if {$wrapper eq "" || ![file isfile $wrapper]} {
        error "Failed to generate BD wrapper for ${design_name}.bd"
    }
    add_files -norecurse $wrapper

    set wrapper_top "${design_name}_wrapper"
    set_property top $wrapper_top [get_filesets sources_1]
    update_compile_order -fileset sources_1
    puts "Block Design configured; synthesis top: $wrapper_top"
}

proc run_needs_refresh {run} {
    set status [get_property STATUS $run]
    if {[string match -nocase "*out-of-date*" $status]} {
        return 1
    }

    # NEEDS_REFRESH is available on Vivado project runs. Keep the status
    # fallback above so the flow remains readable if a patch release omits it.
    if {![catch {get_property NEEDS_REFRESH $run} refresh] &&
        [string is boolean -strict $refresh]} {
        return [expr {$refresh ? 1 : 0}]
    }
    return 0
}

proc run_is_current_success {run_name} {
    set run [get_runs -quiet $run_name]
    if {[llength $run] == 0} {
        error "Vivado run does not exist: $run_name"
    }

    set status   [get_property STATUS $run]
    set progress [get_property PROGRESS $run]
    return [expr {$progress eq "100%" &&
        [string first "Complete!" $status] >= 0 &&
        ![run_needs_refresh $run]}]
}

proc prepare_run_for_launch {run_name} {
    set run [get_runs -quiet $run_name]
    if {[llength $run] == 0} {
        error "Vivado run does not exist: $run_name"
    }
    if {[run_is_current_success $run_name]} {
        puts "Reusing current $run_name results."
        return 0
    }

    set status [get_property STATUS $run]
    if {$status ne "Not started"} {
        puts "Resetting stale $run_name (previous status: $status)"
        reset_runs $run_name
    }
    return 1
}

proc require_run_success {run_name} {
    set run      [get_runs $run_name]
    set status   [get_property STATUS $run]
    set progress [get_property PROGRESS $run]
    if {$progress ne "100%" || [string first "Complete!" $status] < 0} {
        set log_file [file join [get_property DIRECTORY $run] runme.log]
        error "$run_name failed (status: $status, progress: $progress). Log: $log_file"
    }
}

proc require_nonnegative_slack {type} {
    set paths [get_timing_paths -quiet -$type -max_paths 1]
    if {[llength $paths] == 0} {
        return "N/A"
    }

    set slack [get_property SLACK [lindex $paths 0]]
    if {$slack < 0.0} {
        error "[string totitle $type] timing failed: worst slack is $slack ns."
    }
    return $slack
}

proc require_implementation_quality {} {
    open_run impl_1

    # 运行 DRC 并刷新 get_drc_violations 可查询的结果；-return_string 用于避免输出完整报告。
    report_drc -return_string
    set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
    if {[llength $drc_errors] > 0} {
        error "Implementation DRC has Error violations: $drc_errors"
    }

    if {![report_route_status -boolean_check ROUTED_FULLY]} {
        error "Implementation is not fully routed."
    }
    if {[report_route_status -boolean_check ERRORS_IN_ROUTES]} {
        error "Implementation contains routing errors."
    }

    # 只检查不依赖板级 IO 时序假设的两类关键未约束问题。
    set timing_check [check_timing -override_defaults \
        {no_clock unconstrained_internal_endpoints} -return_string]
    puts $timing_check
    if {![regexp -nocase {register/latch pins with no clock} $timing_check]} {
        error "Unable to read the no_clock result from check_timing."
    }
    if {[regexp -nocase {There are[ \t]+([1-9][0-9]*)[ \t]+register/latch pins with no clock} \
            $timing_check -> no_clock_count]} {
        error "Timing constraints incomplete: check_timing found at least $no_clock_count sequential clock pins without a clock."
    }
    if {![regexp -nocase {pins that are not constrained for maximum delay} $timing_check]} {
        error "Unable to read the unconstrained_internal_endpoints result from check_timing."
    }
    if {[regexp -nocase {There are[ \t]+([1-9][0-9]*)[ \t]+pins that are not constrained for maximum delay} \
            $timing_check -> unconstrained_count]} {
        error "Timing constraints incomplete: check_timing found $unconstrained_count unconstrained internal endpoints."
    }

    set setup_slack [require_nonnegative_slack setup]
    set hold_slack  [require_nonnegative_slack hold]

    puts "Implementation checks passed: DRC errors=0, fully routed, setup slack=$setup_slack ns, hold slack=$hold_slack ns."
}

proc configure_incremental_implementation {} {
    global script_dir proj_name

    set impl_run [get_runs -quiet impl_1]
    if {[llength $impl_run] == 0} {
        error "Vivado implementation run does not exist: impl_1"
    }
    set checkpoint_dir [file normalize \
        [file join $script_dir "${proj_name}.incremental" impl_1]]
    file mkdir $checkpoint_dir
    set_property AUTO_INCREMENTAL_CHECKPOINT 1 $impl_run
    set_property AUTO_INCREMENTAL_CHECKPOINT.DIRECTORY $checkpoint_dir $impl_run
    set_property incremental_checkpoint.directive RuntimeOptimized $impl_run
    puts "Automatic incremental implementation enabled: $checkpoint_dir"
}

proc configure_incremental_synthesis {} {
    global script_dir proj_name

    set synth_run [get_runs -quiet synth_1]
    if {[llength $synth_run] == 0} {
        error "Vivado synthesis run does not exist: synth_1"
    }
    set checkpoint_dir [file normalize \
        [file join $script_dir "${proj_name}.incremental" synth_1]]
    file mkdir $checkpoint_dir
    set reference_a [file join $checkpoint_dir reference_a.dcp]
    set reference_b [file join $checkpoint_dir reference_b.dcp]
    set legacy_reference [file join $checkpoint_dir reference.dcp]
    set reference_dcp ""
    foreach candidate [list $legacy_reference $reference_a $reference_b] {
        if {![file isfile $candidate]} {
            continue
        }
        if {$reference_dcp eq "" ||
            [file mtime $candidate] > [file mtime $reference_dcp]} {
            set reference_dcp $candidate
        }
    }
    set next_reference [expr {$reference_dcp eq $reference_a ?
        $reference_b : $reference_a}]

    set_property AUTO_INCREMENTAL_CHECKPOINT 0 $synth_run
    set_property WRITE_INCREMENTAL_SYNTH_CHECKPOINT 1 $synth_run
    set_property STEPS.SYNTH_DESIGN.ARGS.INCREMENTAL_MODE default $synth_run
    if {$reference_dcp ne ""} {
        set_property INCREMENTAL_CHECKPOINT $reference_dcp $synth_run
        puts "Incremental synthesis reference enabled: $reference_dcp"
    } else {
        set_property INCREMENTAL_CHECKPOINT {} $synth_run
        puts "Incremental synthesis baseline will be created: $next_reference"
    }
    return $next_reference
}

proc publish_file {source_file target_file} {
    set temp_file [file join [file dirname $target_file] \
        ".[file tail $target_file].[pid].tmp"]
    catch {file delete -force -- $temp_file}
    if {[catch {
        file copy -force -- $source_file $temp_file
        file rename -force -- $temp_file $target_file
    } message options]} {
        catch {file delete -force -- $temp_file}
        return -options $options $message
    }
}

proc write_text_if_changed {path contents} {
    if {[file isfile $path]} {
        set channel [open $path r]
        fconfigure $channel -encoding utf-8 -translation lf
        set current [read $channel]
        close $channel
        if {$current eq $contents} {
            return 0
        }
    }
    set temp_file "${path}.tmp.[pid]"
    catch {file delete -force -- $temp_file}
    set channel [open $temp_file w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts -nonewline $channel $contents
    close $channel
    file rename -force -- $temp_file $path
    return 1
}

proc ila_generated_paths {} {
    global script_dir proj_name
    return [dict create \
        mark_xdc [file normalize [file join $script_dir "${proj_name}.mark_debug.xdc"]] \
        debug_xdc [file normalize [file join $script_dir "${proj_name}.ila_debug.xdc"]] \
        post_tcl [file normalize [file join $script_dir "${proj_name}.ila_post.tcl"]] \
        ltx [file normalize [file join $script_dir "${proj_name}.ltx"]]]
}

proc render_ila_mark_xdc {} {
    global ila_probe_patterns

    set lines [list "# Generated by prj/run.tcl; do not edit."]
    foreach pattern $ila_probe_patterns {
        lappend lines [format {set_property -quiet MARK_DEBUG true [get_nets -hierarchical -quiet %s]} \
            [list $pattern]]
    }
    return "[join $lines \n]\n"
}

proc render_ila_post_tcl {} {
    global ila_clock_net ila_probe_patterns ila_data_depth

    set lines [list "# Generated by prj/run.tcl; do not edit."]
    lappend lines [format {set template_ila_clock [get_nets -hierarchical -quiet %s]} \
        [list $ila_clock_net]]
    lappend lines [format {if {[llength $template_ila_clock] != 1} { error %s }} \
        [list "ila_clock_net must match exactly one synthesized net: $ila_clock_net"]]
    lappend lines {create_debug_core template_ila ila}
    lappend lines [format {set_property C_DATA_DEPTH %s [get_debug_cores template_ila]} \
        $ila_data_depth]
    lappend lines {connect_debug_port template_ila/clk $template_ila_clock}
    lappend lines {set template_ila_seen [dict create]}

    set probe_index 0
    foreach pattern $ila_probe_patterns {
        lappend lines [format {set template_ila_probe [get_nets -hierarchical -quiet %s]} \
            [list $pattern]]
        lappend lines [format {if {[llength $template_ila_probe] == 0} { error %s }} \
            [list "ILA probe pattern matched no synthesized nets: $pattern"]]
        lappend lines {foreach template_ila_net $template_ila_probe {
    set template_ila_name [get_property NAME $template_ila_net]
    if {[dict exists $template_ila_seen $template_ila_name]} {
        error "ILA probe patterns overlap at synthesized net: $template_ila_name"
    }
    dict set template_ila_seen $template_ila_name 1
}}
        if {$probe_index > 0} {
            lappend lines {create_debug_port template_ila probe}
        }
        lappend lines [format {set template_ila_port [get_debug_ports template_ila/probe%s]} \
            $probe_index]
        lappend lines {set_property PORT_WIDTH [llength $template_ila_probe] $template_ila_port}
        lappend lines {connect_debug_port $template_ila_port $template_ila_probe}
        incr probe_index
    }
    lappend lines {puts "ILA core generated: name=template_ila probes=[llength [get_debug_ports -quiet template_ila/probe*]]"}
    lappend lines {unset -nocomplain template_ila_clock template_ila_probe template_ila_port template_ila_seen template_ila_net template_ila_name}
    return "[join $lines \n]\n"
}

proc configure_optional_ila {} {
    global enable_ila ila_probe_patterns ila_data_depth

    set paths [ila_generated_paths]
    set mark_xdc [dict get $paths mark_xdc]
    set debug_xdc [dict get $paths debug_xdc]
    set post_tcl [dict get $paths post_tcl]
    set synth_run [get_runs -quiet synth_1]
    if {[llength $synth_run] == 0} {
        error "Vivado synthesis run does not exist: synth_1"
    }

    if {!$enable_ila} {
        set generated_object [get_files -quiet $mark_xdc]
        if {[llength $generated_object] > 0} {
            remove_files $generated_object
        }
        set debug_object [get_files -quiet $debug_xdc]
        if {[llength $debug_object] > 0} {
            remove_files $debug_object
        }
        set_property STEPS.SYNTH_DESIGN.TCL.POST {} $synth_run
        delete_generated_path $mark_xdc
        delete_generated_path $debug_xdc
        delete_generated_path $post_tcl
        delete_generated_path [dict get $paths ltx]
        puts "ILA: disabled"
        return
    }

    set xdc_changed [write_text_if_changed $mark_xdc [render_ila_mark_xdc]]
    set hook_changed [write_text_if_changed $post_tcl [render_ila_post_tcl]]
    if {$xdc_changed || $hook_changed} {
        set debug_object [get_files -quiet $debug_xdc]
        if {[llength $debug_object] > 0} {
            remove_files $debug_object
        }
        delete_generated_path $debug_xdc
    }
    set generated_object [get_files -quiet $mark_xdc]
    if {[llength $generated_object] == 0} {
        add_files -norecurse -fileset constrs_1 $mark_xdc
        set generated_object [get_files $mark_xdc]
    }
    set_property USED_IN_SYNTHESIS true $generated_object
    set_property USED_IN_IMPLEMENTATION false $generated_object
    set_property STEPS.SYNTH_DESIGN.TCL.POST {} $synth_run
    puts "ILA: enabled probes=[llength $ila_probe_patterns] depth=$ila_data_depth generated_xdc=$xdc_changed generated_hook=$hook_changed"
}

proc instrument_synthesis_with_ila {} {
    global enable_ila

    if {!$enable_ila} {
        return
    }
    set debug_xdc [dict get [ila_generated_paths] debug_xdc]
    if {[file isfile $debug_xdc] && [run_is_current_success impl_1]} {
        puts "ILA implementation constraints reused: $debug_xdc"
        return
    }
    open_run synth_1
    if {[llength [get_debug_cores -quiet template_ila]] == 1} {
        puts "ILA synthesized checkpoint already contains template_ila."
        close_design
        return
    }
    set unmanaged {}
    foreach core [get_debug_cores -quiet] {
        if {[get_property NAME $core] ne "dbg_hub"} {
            lappend unmanaged $core
        }
    }
    if {[llength $unmanaged] != 0} {
        close_design
        error "Synthesized checkpoint already contains unmanaged debug cores: $unmanaged. Disable automatic ILA or remove the conflicting cores."
    }
    write_text_if_changed $debug_xdc "# Generated by prj/run.tcl; do not edit.\n"
    set debug_object [get_files -quiet $debug_xdc]
    if {[llength $debug_object] == 0} {
        add_files -norecurse -fileset constrs_1 $debug_xdc
        set debug_object [get_files $debug_xdc]
    }
    set_property USED_IN_SYNTHESIS false $debug_object
    set_property USED_IN_IMPLEMENTATION true $debug_object
    set constrset [get_filesets constrs_1]
    set previous_target [get_property TARGET_CONSTRS_FILE $constrset]
    set_property TARGET_CONSTRS_FILE $debug_xdc $constrset
    set post_tcl [dict get [ila_generated_paths] post_tcl]
    if {[catch {
        source $post_tcl
        save_constraints -force
        close_design
        set_property TARGET_CONSTRS_FILE $previous_target $constrset
    } message options]} {
        catch {close_design}
        catch {set_property TARGET_CONSTRS_FILE $previous_target $constrset}
        return -options $options $message
    }
    puts "ILA implementation constraints published: $debug_xdc"
}

proc add_manifest_artifact {values_var prefix path} {
    upvar 1 $values_var values
    global root_dir

    if {$path eq ""} {
        dict set values "${prefix}_path" absent
        dict set values "${prefix}_size" 0
        dict set values "${prefix}_sha256" absent
        return
    }
    if {![file isfile $path]} {
        error "Hardware manifest input is missing: $path"
    }
    set normalized [normalized_path $path]
    set root [string trimright [normalized_path $root_dir] /]
    if {![path_is_under $normalized $root_dir]} {
        error "Hardware manifest input is outside the repository: $normalized"
    }
    set relative [string range $normalized [expr {[string length $root] + 1}] end]
    dict set values "${prefix}_path" $relative
    dict set values "${prefix}_size" [file size $path]
    dict set values "${prefix}_sha256" [sha256_file $path]
}

proc write_hardware_manifest {bit_file xsa_file ltx_file} {
    global script_dir proj_name part use_bd enable_ila

    set values [dict create \
        manifest_version 1 \
        project_name $proj_name \
        part $part \
        design_mode [expr {$use_bd ? "ps_pl" : "pure_pl"}] \
        ila_enabled [expr {$enable_ila ? 1 : 0}]]
    add_manifest_artifact values bit $bit_file
    add_manifest_artifact values xsa $xsa_file
    add_manifest_artifact values debug_probes $ltx_file
    set path [file normalize [file join $script_dir "${proj_name}.hardware.manifest"]]
    write_key_value_file $path $values
    puts "Hardware manifest published: $path"
}

proc verify_manifest_artifact {values prefix expected_path required} {
    global root_dir

    foreach suffix {path size sha256} {
        set key "${prefix}_${suffix}"
        if {![dict exists $values $key]} {
            error "Hardware manifest is missing '$key'."
        }
    }
    set recorded_path [dict get $values "${prefix}_path"]
    if {!$required} {
        if {$recorded_path ne "absent" || [file isfile $expected_path]} {
            error "Unexpected published $prefix artifact: $recorded_path"
        }
        return
    }
    if {$recorded_path eq "absent"} {
        error "Hardware manifest does not publish required artifact '$prefix'."
    }
    set actual [file normalize [file join $root_dir $recorded_path]]
    if {![path_is_under $actual $root_dir] ||
        ![string equal -nocase [normalized_path $actual] [normalized_path $expected_path]]} {
        error "Hardware manifest $prefix path is unexpected: $recorded_path"
    }
    if {![file isfile $actual]} {
        error "Hardware manifest $prefix artifact is missing: $actual"
    }
    if {[file size $actual] != [dict get $values "${prefix}_size"]} {
        error "Hardware manifest $prefix size is stale: $actual"
    }
    if {[sha256_file $actual] ne [string tolower [dict get $values "${prefix}_sha256"]]} {
        error "Hardware manifest $prefix SHA-256 is stale: $actual"
    }
}

proc verify_hardware_manifest_if_published {{require_current_run 1}} {
    global script_dir proj_name part use_bd enable_ila

    set bit_file [file normalize [file join $script_dir "${proj_name}.bit"]]
    set xsa_file [file normalize [file join $script_dir "${proj_name}.xsa"]]
    set ltx_file [file normalize [file join $script_dir "${proj_name}.ltx"]]
    set manifest [file normalize [file join $script_dir "${proj_name}.hardware.manifest"]]
    if {![file isfile $bit_file]} {
        foreach stale [list $manifest $ltx_file $xsa_file] {
            if {[file isfile $stale]} {
                error "Published hardware is inconsistent: bitstream is absent but artifact remains: $stale"
            }
        }
        puts "CHECK: hardware=absent"
        return absent
    }
    if {![file isfile $manifest]} {
        error "Published bitstream has no hardware manifest. Run Vivado build."
    }
    set values [read_key_value_file $manifest]
    foreach {key expected} [list \
            manifest_version 1 project_name $proj_name part $part \
            design_mode [expr {$use_bd ? "ps_pl" : "pure_pl"}] \
            ila_enabled [expr {$enable_ila ? 1 : 0}]] {
        if {![dict exists $values $key] || [dict get $values $key] ne $expected} {
            error "Hardware manifest '$key' is stale; expected '$expected'. Run Vivado build."
        }
    }
    verify_manifest_artifact $values bit $bit_file 1
    verify_manifest_artifact $values xsa $xsa_file $use_bd
    verify_manifest_artifact $values debug_probes $ltx_file $enable_ila
    if {$require_current_run} {
        if {![run_is_current_success impl_1]} {
            error "Published bitstream is stale because impl_1 is not current. Run Vivado build."
        }
        puts "CHECK: hardware=current manifest=[normalized_path $manifest]"
        return current
    } else {
        puts "CHECK: hardware=integrity_valid run_freshness=not_checked manifest=[normalized_path $manifest]"
        return integrity_valid
    }
}

proc publish_debug_probes {} {
    global enable_ila

    set ltx_file [dict get [ila_generated_paths] ltx]
    if {!$enable_ila} {
        delete_generated_path $ltx_file
        return ""
    }
    if {[llength [get_debug_cores -quiet template_ila]] != 1} {
        error "ILA is enabled, but implemented debug core 'template_ila' is missing or ambiguous."
    }
    set temp_file "${ltx_file}.tmp.[pid]"
    catch {file delete -force -- $temp_file}
    if {[catch {
        write_debug_probes -force $temp_file
        if {![file isfile $temp_file]} {
            error "write_debug_probes did not create: $temp_file"
        }
        file rename -force -- $temp_file $ltx_file
    } message options]} {
        catch {file delete -force -- $temp_file}
        return -options $options $message
    }
    puts "ILA debug probes published: $ltx_file"
    return $ltx_file
}

proc delete_downstream_download_artifacts {} {
    global root_dir

    set root_base [string map {\\ /} [file normalize $root_dir]]
    set vitis_dir [file normalize [file join $root_dir vitis]]
    set vitis_base [string map {\\ /} $vitis_dir]
    foreach pattern {*.elf *.bin *.manifest *.xsa} {
        foreach artifact [glob -nocomplain -types f [file join $vitis_dir $pattern]] {
            set target [string map {\\ /} [file normalize $artifact]]
            if {![string equal -nocase [file dirname $target] $vitis_base]} {
                error "Refusing to delete download artifact outside vitis/: $target"
            }
            puts "Invalidating downstream download artifact: $target"
            file delete -force -- $target
        }
    }

    foreach directory [list [file join $vitis_dir boot] [file join $root_dir sd_boot]] {
        set target [string map {\\ /} [file normalize $directory]]
        set parent [file dirname $target]
        if {![string equal -nocase $parent $vitis_base] &&
            ![string equal -nocase $parent $root_base]} {
            error "Refusing to delete download directory outside the repository: $target"
        }
        if {[file exists $target]} {
            puts "Invalidating downstream download directory: $target"
            file delete -force -- $target
        }
    }
}

proc invalidate_published_hardware {{include_bitstreams 0}} {
    global script_dir proj_name

    set patterns [list *.xsa *.hardware.manifest]
    if {$include_bitstreams} {
        lappend patterns *.bit *.ltx
    }
    foreach pattern $patterns {
        foreach artifact [glob -nocomplain -types f [file join $script_dir $pattern]] {
            delete_generated_path $artifact
        }
    }
    if {$include_bitstreams} {
        delete_downstream_download_artifacts
    }

    set xsa_file [file normalize [file join $script_dir "${proj_name}.xsa"]]
    if {[file exists $xsa_file] && ![file isfile $xsa_file]} {
        error "Refusing to replace non-file XSA path: $xsa_file"
    }
    return $xsa_file
}

proc run_synthesis {} {
    global num_jobs script_dir proj_name

    set checkpoint_dir [file normalize \
        [file join $script_dir "${proj_name}.incremental" synth_1]]
    set references [glob -nocomplain -types f \
        [file join $checkpoint_dir reference*.dcp]]
    if {[run_is_current_success synth_1] && [llength $references] > 0} {
        puts "CACHE: synth=reused"
        puts "Reusing current synth_1 results."
        puts "Synthesis complete."
        return
    }
    if {[run_is_current_success synth_1]} {
        puts "Incremental synthesis baseline is missing; rebuilding synth_1 once."
        reset_runs synth_1
    }

    set next_reference [configure_incremental_synthesis]
    puts "CACHE: synth=rebuilt"
    if {[prepare_run_for_launch synth_1]} {
        set jobs [expr {$num_jobs < 8 ? $num_jobs : 8}]
        launch_runs synth_1 -jobs $jobs
        wait_on_run synth_1
    }
    require_run_success synth_1
    set synth_run [get_runs synth_1]
    set build_top [get_property TOP [get_filesets sources_1]]
    set run_dcp [file normalize \
        [file join [get_property DIRECTORY $synth_run] "${build_top}.dcp"]]
    if {![file isfile $run_dcp]} {
        error "Synthesis completed but its checkpoint is missing: $run_dcp"
    }
    publish_file $run_dcp $next_reference
    if {![file isfile $next_reference]} {
        error "Incremental synthesis checkpoint publication failed: $next_reference"
    }
    puts "Incremental synthesis checkpoint published: $next_reference"
    puts "Synthesis complete."
}

proc do_synth {} {
    # A successful synthesis-only run deliberately does not publish a bitstream
    # or XSA. Invalidate every published hardware/software download artifact so
    # downstream tools cannot consume a stale bitstream, XSA, ELF, or boot image.
    assert_project_structure_current
    assert_persistent_file_sets_current
    configure_optional_ila
    if {![run_is_current_success synth_1] || ![run_is_current_success impl_1]} {
        invalidate_published_hardware 1
    }
    run_synthesis
    instrument_synthesis_with_ila
}

proc do_build {} {
    global num_jobs script_dir proj_name use_bd

    assert_project_structure_current
    assert_persistent_file_sets_current
    configure_optional_ila

    # The launcher uses this marker to roll back stable artifacts if its final
    # complete-log audit rejects the run after Tcl has started publication.
    puts "PUBLISH_TRANSACTION: scope=hardware state=started"
    require_no_parent_critical_warnings

    set manifest [file normalize [file join $script_dir "${proj_name}.hardware.manifest"]]
    if {[run_is_current_success synth_1] && [run_is_current_success impl_1] &&
        [file isfile $manifest]} {
        if {![catch {verify_hardware_manifest_if_published} verify_message]} {
            puts "CACHE: synth=reused"
            puts "CACHE: impl=reused"
            puts "CACHE: publish=reused"
            puts "PUBLISH_TRANSACTION: scope=hardware state=committed"
            puts "Build already current: [file normalize [file join $script_dir "${proj_name}.bit"]]"
            puts "METRIC: build_noop_seconds=0.000"
            return
        }
        puts "CACHE: publish=rebuilt reason=[string map {\n { }} $verify_message]"
    }

    # Invalidate all old published hardware and downstream software downloads
    # before generating the one current bitstream/XSA set.
    set xsa_file [invalidate_published_hardware 1]

    set build_top [get_property TOP [get_filesets sources_1]]
    if {$build_top eq ""} {
        error "Synthesis top is not set. Run 'all' for a fresh build, run 'bd' for PS+PL, or configure top_name/use_bd first."
    }

    set phase_started [clock milliseconds]
    run_synthesis
    emit_phase_metric synth $phase_started
    instrument_synthesis_with_ila
    configure_incremental_implementation

    set phase_started [clock milliseconds]
    set rebuild_impl [prepare_run_for_launch impl_1]
    puts "CACHE: impl=[expr {$rebuild_impl ? "rebuilt" : "reused"}]"
    if {$rebuild_impl} {
        set jobs [expr {$num_jobs < 8 ? $num_jobs : 8}]
        launch_runs impl_1 -to_step write_bitstream -jobs $jobs
        wait_on_run impl_1
    }
    require_run_success impl_1
    emit_phase_metric impl $phase_started
    set phase_started [clock milliseconds]
    require_implementation_quality
    emit_phase_metric quality_check $phase_started
    require_no_parent_critical_warnings

    set bit_file [file normalize \
        [file join [get_property DIRECTORY [get_runs impl_1]] "${build_top}.bit"]]
    if {![file isfile $bit_file]} {
        error "Implementation completed but bitstream is missing: $bit_file"
    }

    # runs/ 保留 Vivado 生成物；稳定副本可纳入版本控制并用于回退后直接下载。
    set phase_started [clock milliseconds]
    set stable_bit [file normalize [file join $script_dir "${proj_name}.bit"]]
    publish_file $bit_file $stable_bit
    if {![file isfile $stable_bit]} {
        error "Bitstream publication failed: $stable_bit"
    }
    puts "Build complete: $stable_bit"

    if {!$use_bd} {
        puts "Pure-PL design: skipping XSA export. The stable bitstream is the complete download artifact."
        set published_ltx [publish_debug_probes]
        require_no_parent_critical_warnings
        write_hardware_manifest $stable_bit "" $published_ltx
        emit_phase_metric publish $phase_started
        puts "PUBLISH_TRANSACTION: scope=hardware state=committed"
        return
    }

    # 导出硬件描述文件供 Vitis 使用
    set xsa_temp [file normalize \
        [file join $script_dir ".${proj_name}.[pid].xsa"]]
    set xsa_sidecar_bit "[file rootname $xsa_temp].bit"
    set aie_primitive_file [file join $script_dir aie_primitive.json]
    catch {file delete -force -- $xsa_temp}
    catch {file delete -force -- $xsa_sidecar_bit}
    if {[catch {
        write_hw_platform -fixed -include_bit -force -file $xsa_temp
        if {![file isfile $xsa_temp]} {
            error "XSA export did not create the expected file: $xsa_temp"
        }
        file rename -force -- $xsa_temp $xsa_file
    } message options]} {
        catch {file delete -force -- $xsa_temp}
        catch {file delete -force -- $xsa_sidecar_bit}
        catch {file delete -force -- $aie_primitive_file}
        return -options $options $message
    }
    catch {file delete -force -- $xsa_sidecar_bit}
    catch {file delete -force -- $aie_primitive_file}
    if {![file isfile $xsa_file]} {
        error "Build completed but XSA export failed: $xsa_file"
    }
    puts "Hardware platform exported: $xsa_file"
    set published_ltx [publish_debug_probes]
    require_no_parent_critical_warnings
    write_hardware_manifest $stable_bit $xsa_file $published_ltx
    emit_phase_metric publish $phase_started
    puts "PUBLISH_TRANSACTION: scope=hardware state=committed"
}

proc do_sim {tb_top sim_time} {
    assert_project_structure_current
    assert_persistent_file_sets_current

    set sim_files [get_files -quiet -of_objects [get_filesets sim_1]]
    if {[llength $sim_files] == 0} {
        error "No simulation sources found. Add .v/.sv files under sim/ and run create/all first."
    }

    set_property top     $tb_top        [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    # XSim parallelizes elaboration rather than the event-simulation kernel.
    # Batch regressions do not need full internal debug visibility or global
    # signal logging; preserving the run directory also avoids needless cleanup.
    set_property xsim.elaborate.mt_level auto [get_filesets sim_1]
    set_property xsim.elaborate.debug_level off [get_filesets sim_1]
    set_property incremental 1 [get_filesets sim_1]
    set_property xsim.simulate.log_all_signals false [get_filesets sim_1]
    set_property xsim.simulate.runtime $sim_time [get_filesets sim_1]
    update_compile_order -fileset sim_1

    launch_simulation -simset sim_1 -mode behavioral -noclean_dir
    close_sim
    puts "Simulation completed by Vivado: testbench=$tb_top duration=$sim_time. Functional pass is evaluated by the launcher."
}

proc open_or_error {xpr} {
    if {![file isfile $xpr]} {
        error "Project does not exist: $xpr. Run the create step first."
    }
    open_project $xpr
}

proc configure_vivado_threads {} {
    global num_jobs
    set threads [expr {$num_jobs < 8 ? $num_jobs : 8}]
    set_param general.maxThreads $threads
    puts "Vivado thread limit: $threads (num_jobs=$num_jobs)"
}

proc emit_next_hint {} {
    global step project_file use_bd check_hardware_state

    switch $step {
        check {
            if {![file isfile $project_file]} {
                puts "NEXT: Vivado all"
            } elseif {$check_hardware_state eq "absent"} {
                puts "NEXT: Vivado build when a published bitstream is required."
            } else {
                puts "NEXT: none; project, sources, and published hardware are current."
            }
        }
        create { puts "NEXT: Vivado ip" }
        ip     { puts "NEXT: Vivado bd" }
        bd     { puts "NEXT: Vivado build" }
        sync   { puts "NEXT: Vivado sim, synth, or build as needed."
        }
        synth  { puts "NEXT: Vivado build when a bitstream is required." }
        sim    { puts "NEXT: Vivado synth or build when RTL is ready." }
        build - all {
            if {$use_bd} {
                puts "NEXT: Vitis update for an existing workspace, or Vitis all for a first/full release."
            } else {
                puts "NEXT: Download the bitstream only after board power and JTAG are confirmed."
            }
        }
    }
}

proc main {} {
    global argv step project_file default_tb default_time

    require_vivado_version
    if {$step eq "sim"} {
        set initial_tb $default_tb
        if {[llength $argv] > 1} { set initial_tb [lindex $argv 1] }
        validate_configuration sim $initial_tb
    } else {
        validate_configuration $step
    }
    configure_vivado_threads

    switch $step {
        check {
            do_check
            catch {close_project}
        }
        create {
            do_create
            close_project
        }
        sync {
            open_or_error $project_file
            do_sync
            close_project
        }
        ip {
            open_or_error $project_file
            do_ip
            close_project
        }
        bd {
            open_or_error $project_file
            do_bd
            close_project
        }
        synth {
            open_or_error $project_file
            do_synth
            close_project
        }
        build {
            open_or_error $project_file
            do_build
            close_project
        }
        sim {
            set tb_top   $default_tb
            set sim_time $default_time
            if {[llength $argv] > 1} { set tb_top   [lindex $argv 1] }
            if {[llength $argv] > 2} { set sim_time [lindex $argv 2] }
            validate_configuration sim $tb_top
            open_or_error $project_file
            do_sim $tb_top $sim_time
            close_project
        }
        all {
            do_create
            do_ip
            do_bd
            do_build
            close_project
        }
        default {
            puts "Available steps: check | create | sync | ip | bd | synth | build | sim | all"
            error "Unknown step: $step"
        }
    }
    emit_next_hint
}

if {[catch {main} message options]} {
    catch {close_project}
    puts stderr "ERROR: $message"
    if {[dict exists $options -errorinfo]} {
        puts stderr "DETAIL: Tcl errorInfo follows:"
        puts stderr [dict get $options -errorinfo]
    }
    exit 1
}

puts "SUCCESS: Vivado step '$step' completed."
