# Vitis 工程管理脚本
# 通过 scripts/invoke-xilinx.cmd 启动；它会处理 XSCT 的 Windows 工作区路径兼容性。

# XSCT 2022.2 can incorrectly collapse valid Windows Desktop paths when using
# file normalize.  Keep existing absolute paths intact and only anchor relative
# paths to a known base directory.
proc absolute_path {path {base_dir ""}} {
    if {$base_dir eq ""} {
        set base_dir [pwd]
    }
    if {[file pathtype $path] eq "relative"} {
        return [file join $base_dir $path]
    }
    return $path
}

set script_path   [absolute_path [info script]]
set script_dir    [file dirname $script_path]
set root_dir      [file dirname $script_dir]
set workspace_dir $script_dir
set source_dir    [file join $script_dir src]

set config_file [file join $root_dir config.tcl]
if {![file isfile $config_file]} {
    error "Shared configuration file is missing: $config_file"
}
source $config_file

set platform_name $template_config(platform_name)
set app_name      $template_config(app_name)
set domain_name   $template_config(domain_name)
set processor     $template_config(processor)
set os_name       $template_config(os_name)
set app_template  $template_config(app_template)
set app_libraries $template_config(app_libraries)
set app_optimization $template_config(app_optimization)
set num_jobs      $template_config(num_jobs)
set worker_jobs   $num_jobs

# 启动产物模式：
#   jtag       = 发布 bit/FSBL/ELF，供临时 JTAG 下载。
#   ps_pl_qspi = 生成可烧写到 QSPI 的 BOOT.bin，并要求 XSA 启用 PS7 QSPI。
#   ps_pl_sd   = 生成可放入 FAT32 SD 卡根目录的 BOOT.bin，并要求 XSA 启用 PS7 SD0。
#   ps_pl_qspi_sd = 同时保留 QSPI 与 SD 启动配置；可分别执行 boot 或 sd。
#   none       = 不使用本脚本管理启动产物。
set boot_mode     $template_config(boot_mode)
set boot_bif_file [file join $script_dir boot.bif]
set boot_bin_file [file join $script_dir BOOT.bin]
set boot_stage_dir [file join $script_dir boot]
set boot_manifest_file [file join $script_dir BOOT.manifest]
set jtag_manifest_file [file join $script_dir JTAG.manifest]
set app_elf_file  [file join $script_dir "${app_name}.elf"]
set fsbl_elf_file [file join $script_dir fsbl.elf]
set managed_build_marker [file join $script_dir .managed_build_required]
set sd_boot_dir   [file join $root_dir sd_boot]
set sd_boot_file  [file join $sd_boot_dir BOOT.bin]
set sd_manifest_file [file join $sd_boot_dir SD_BOOT.manifest]

proc print_usage {} {
    puts "Usage: scripts/invoke-xilinx.cmd -Tool Vitis -Step <step> \[-Xsa <XSA>\]"
    puts "Steps: help | check | create | update | sync | build | boot | sd | clean | all"
    puts "The XSA argument is required when no unique XSA exists in prj/ or vitis/."
}

proc require_xsct_version {} {
    set detected [version]
    if {![regexp {(^|[^0-9])2022\.2([^0-9]|$)} $detected]} {
        error "Vitis/XSCT 2022.2 is required; detected: $detected"
    }
    puts "Vitis/XSCT version check passed: 2022.2"
}

proc emit_phase_metric {name started_ms} {
    set elapsed [expr {([clock milliseconds] - $started_ms) / 1000.0}]
    puts [format "METRIC: %s_seconds=%.3f" $name $elapsed]
}

proc validate_binary_configuration {} {
    global template_config
    foreach key {use_bd enable_qspi_boot enable_uart1 enable_sd0 enable_gpio_mio enable_fclk0 enable_ila} {
        if {![info exists template_config($key)] || $template_config($key) ni {0 1}} {
            set value [expr {[info exists template_config($key)] ? $template_config($key) : "missing"}]
            error "$key must be exactly 0 or 1: $value"
        }
    }
}

set step [lindex $argv 0]
if {$step eq ""} {
    print_usage
    puts stderr "ERROR: Missing step."
    exit 1
}

proc validate_project_name {name} {
    if {![regexp {^[A-Za-z0-9_]+$} $name]} {
        error "Project name may contain only letters, digits, and underscores: $name"
    }
}

proc validate_boot_mode {} {
    global boot_mode
    if {[lsearch -exact {ps_pl_qspi ps_pl_sd ps_pl_qspi_sd jtag none} $boot_mode] < 0} {
        error "Unsupported boot_mode '$boot_mode'. Use ps_pl_qspi, ps_pl_sd, ps_pl_qspi_sd, jtag, or none."
    }
}

proc boot_mode_requires_qspi {} {
    global boot_mode
    return [expr {[lsearch -exact {ps_pl_qspi ps_pl_qspi_sd} $boot_mode] >= 0}]
}

proc boot_mode_requires_sd {} {
    global boot_mode
    return [expr {[lsearch -exact {ps_pl_sd ps_pl_qspi_sd} $boot_mode] >= 0}]
}

proc boot_mode_generates_image {} {
    return [expr {[boot_mode_requires_qspi] || [boot_mode_requires_sd]}]
}

proc resolve_xsa {} {
    global argv root_dir script_dir

    if {[llength $argv] > 1} {
        set xsa [absolute_path [lindex $argv 1]]
        if {![string equal -nocase [file extension $xsa] ".xsa"]} {
            error "Hardware handoff must be an XSA file: $xsa"
        }
    } else {
        set candidates {}
        lappend candidates {*}[glob -nocomplain -types f [file join $root_dir prj *.xsa]]
        lappend candidates {*}[glob -nocomplain -types f [file join $script_dir *.xsa]]
        set candidates [lsort -unique $candidates]

        if {[llength $candidates] == 0} {
            error "No XSA found. Pass the Vivado-exported XSA as the second argument."
        }
        if {[llength $candidates] > 1} {
            error "Multiple XSA files found; pass the intended file explicitly: $candidates"
        }
        set xsa [absolute_path [lindex $candidates 0]]
    }

    if {![file isfile $xsa]} {
        error "XSA does not exist: $xsa"
    }
    return $xsa
}

proc glob_files_recursive {dir patterns} {
    if {![file isdirectory $dir]} {
        return {}
    }

    set result {}
    foreach pattern $patterns {
        lappend result {*}[glob -nocomplain -types f [file join $dir $pattern]]
    }
    foreach child [glob -nocomplain -types d -directory $dir *] {
        lappend result {*}[glob_files_recursive $child $patterns]
    }
    return [lsort -unique $result]
}

proc require_sources {} {
    global source_dir

    set sources [glob_files_recursive $source_dir {*.c *.cc *.cpp *.cxx *.s *.S}]
    if {[llength $sources] == 0} {
        error "No C/C++/assembly sources found under: $source_dir"
    }
    return $sources
}

proc get_hsi_property_or_empty {object property} {
    if {[catch {hsi get_property $property $object} value]} {
        return ""
    }
    return $value
}

proc find_ps7_cell {} {
    set candidates {}
    foreach cell [hsi get_cells -hierarchical] {
        set ip_name [get_hsi_property_or_empty $cell IP_NAME]
        set vlnv    [get_hsi_property_or_empty $cell VLNV]
        if {$ip_name eq "processing_system7" || [string first "processing_system7" $vlnv] >= 0} {
            lappend candidates $cell
        }
    }
    if {[llength $candidates] != 1} {
        error "Expected exactly one processing_system7 cell in XSA; found: $candidates"
    }
    return [lindex $candidates 0]
}

proc value_is_enabled {value} {
    set v [string tolower [string trim $value]]
    return [expr {$v eq "1" || $v eq "true" || $v eq "enable" || $v eq "enabled"}]
}

proc require_qspi_boot_configuration {} {
    set ps7 [find_ps7_cell]
    set qspi_enable [get_hsi_property_or_empty $ps7 CONFIG.PCW_QSPI_PERIPHERAL_ENABLE]
    set single_ss   [get_hsi_property_or_empty $ps7 CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE]
    set qspi_io     [get_hsi_property_or_empty $ps7 CONFIG.PCW_QSPI_QSPI_IO]
    set single_ss_io [get_hsi_property_or_empty $ps7 CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO]
    set data_mode    [get_hsi_property_or_empty $ps7 CONFIG.PCW_SINGLE_QSPI_DATA_MODE]

    if {![value_is_enabled $qspi_enable]} {
        error "The selected boot_mode requires PS7 QSPI enabled in XSA. Set template_config(enable_qspi_boot) to 1 in config.tcl, then rebuild Vivado all and Vitis platform/FSBL."
    }
    if {$single_ss ne "" && ![value_is_enabled $single_ss]} {
        error "boot_mode=ps_pl_qspi requires QSPI single-SS enabled for the board Flash. Check prj/bd.tcl."
    }
    if {$qspi_io ne "" && [string first "MIO 1 .. 6" $qspi_io] < 0} {
        error "boot_mode=ps_pl_qspi expects QSPI on MIO 1 .. 6; XSA reports '$qspi_io'. Check board wiring and prj/bd.tcl."
    }
    if {[string trim $single_ss_io] ne "MIO 1 .. 6"} {
        error "boot_mode=ps_pl_qspi requires QSPI single-SS group on MIO 1 .. 6; XSA reports '$single_ss_io'. Set CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO in prj/bd.tcl, then rebuild Vivado all and Vitis platform/FSBL."
    }
    if {![string equal -nocase [string trim $data_mode] "x4"]} {
        error "boot_mode=ps_pl_qspi requires QSPI x4 data mode; XSA reports '$data_mode'. Set CONFIG.PCW_SINGLE_QSPI_DATA_MODE to x4 in prj/bd.tcl, then rebuild Vivado all and Vitis platform/FSBL."
    }

    puts "QSPI boot configuration check passed: enable=$qspi_enable single_ss=$single_ss io=$qspi_io single_ss_io=$single_ss_io data_mode=$data_mode"
}

proc require_sd_boot_configuration {} {
    set ps7 [find_ps7_cell]
    set sd_enable [get_hsi_property_or_empty $ps7 CONFIG.PCW_SD0_PERIPHERAL_ENABLE]
    set sd_io     [get_hsi_property_or_empty $ps7 CONFIG.PCW_SD0_SD0_IO]
    set cd_enable [get_hsi_property_or_empty $ps7 CONFIG.PCW_SD0_GRP_CD_ENABLE]
    set cd_io     [get_hsi_property_or_empty $ps7 CONFIG.PCW_SD0_GRP_CD_IO]

    if {![value_is_enabled $sd_enable]} {
        error "The selected boot_mode requires PS7 SD0 enabled in XSA. Set template_config(enable_sd0) to 1 in config.tcl, then rebuild Vivado all and Vitis platform/FSBL."
    }
    if {[string trim $sd_io] ne "MIO 40 .. 45"} {
        error "boot_mode=ps_pl_sd requires SD0 on MIO 40 .. 45; XSA reports '$sd_io'. Check prj/bd.tcl."
    }
    if {![value_is_enabled $cd_enable] || [string trim $cd_io] ne "MIO 47"} {
        error "boot_mode=ps_pl_sd requires the AX7020 SD card-detect signal on MIO 47; XSA reports enable='$cd_enable' io='$cd_io'. Check prj/bd.tcl."
    }

    puts "SD boot configuration check passed: enable=$sd_enable io=$sd_io card_detect=$cd_enable card_detect_io=$cd_io"
}

proc cleanup_repository_xsa_sidecars {xsa} {
    global root_dir

    set prj_dir [string map [list "\\" "/"] [absolute_path [file join $root_dir prj]]]
    set xsa_dir [string map [list "\\" "/"] [file dirname [absolute_path $xsa]]]
    if {![string equal -nocase [string trimright $xsa_dir "/"] [string trimright $prj_dir "/"]]} {
        return
    }

    set project_name [file rootname [file tail $xsa]]
    set generated [list [file join $xsa_dir aie_primitive.json]]
    foreach name {
        ps7_init.c ps7_init.h ps7_init.html ps7_init.tcl
        ps7_init_gpl.c ps7_init_gpl.h
    } {
        lappend generated [file join $xsa_dir $name]
    }
    lappend generated {*}[glob -nocomplain -types f \
        [file join $xsa_dir ".${project_name}.*.bit"]]

    foreach path $generated {
        if {[file isfile $path]} {
            file delete -force -- $path
        }
    }
}

proc do_check {xsa} {
    global processor boot_mode

    require_sources
    set old_dir   [pwd]
    set temp_root [absolute_path \
        [expr {[info exists ::env(TEMP)] ? $::env(TEMP) : $::env(TMP)}]]
    set check_dir [file join $temp_root \
        "vitis_xsa_check_[pid]_[clock clicks]"]
    set temp_parent_compare [string map {\\ /} [file dirname $check_dir]]
    set temp_root_compare   [string map {\\ /} $temp_root]
    if {![string equal -nocase $temp_parent_compare $temp_root_compare]} {
        error "Invalid temporary check directory: $check_dir"
    }
    file mkdir $check_dir

    set code [catch {
        cd $check_dir
        openhw $xsa
        set processors [hsi get_cells -hierarchical -filter {IP_TYPE == PROCESSOR}]
        if {[lsearch -exact $processors $processor] < 0} {
            error "Configured processor '$processor' not found in XSA. Available: $processors"
        }
        if {[boot_mode_requires_qspi]} {
            require_qspi_boot_configuration
        }
        if {[boot_mode_requires_sd]} {
            require_sd_boot_configuration
        }
    } message options]
    catch {closehw $xsa}
    cd $old_dir
    catch {file delete -force -- $check_dir}
    cleanup_repository_xsa_sidecars $xsa
    if {$code != 0} {
        return -options $options $message
    }

    puts "Configuration check passed: $xsa"
}

proc delete_generated_path {path} {
    global workspace_dir

    set base   [string map {\\ /} [absolute_path $workspace_dir]]
    set target [string map {\\ /} [absolute_path $path]]
    set parent [string map {\\ /} [file dirname $target]]

    if {![string equal -nocase $parent $base]} {
        error "Refusing to delete path outside the Vitis workspace: $target"
    }
    if {[file exists $target]} {
        puts "Deleting old generated path: $target"
        file delete -force -- $target
    }
}

proc reset_workspace_metadata {} {
    global workspace_dir

    # Vitis stores the registered Platform/Application projects in .metadata.
    # A workspace copied from an earlier release can retain stale registrations
    # even after the generated project directories have been recreated.
    set metadata_dir [file join $workspace_dir .metadata]
    if {[file exists $metadata_dir]} {
        puts "Deleting stale Vitis workspace metadata: $metadata_dir"
        delete_generated_path $metadata_dir
    }
}

proc list_contains {items name} {
    return [expr {[lsearch -exact $items $name] >= 0}]
}

proc invalidate_boot_manifest {} {
    global boot_manifest_file

    if {[file exists $boot_manifest_file]} {
        file delete -force -- $boot_manifest_file
    }
}

proc invalidate_jtag_manifest {} {
    global jtag_manifest_file

    if {[file exists $jtag_manifest_file]} {
        file delete -force -- $jtag_manifest_file
    }
}

proc delete_sd_boot_outputs {} {
    global root_dir sd_boot_dir

    set base   [string map {\\ /} [absolute_path $root_dir]]
    set target [string map {\\ /} [absolute_path $sd_boot_dir]]
    if {![string equal -nocase [file dirname $target] $base]} {
        error "Refusing to delete SD boot output outside the repository: $target"
    }
    if {[file exists $target]} {
        puts "Invalidating previous SD boot package: $target"
        file delete -force -- $target
    }
}

proc invalidate_boot_outputs {} {
    global workspace_dir boot_bin_file boot_manifest_file boot_stage_dir jtag_manifest_file

    foreach bin [glob -nocomplain -types f [file join $workspace_dir *.bin]] {
        delete_generated_path $bin
    }
    foreach manifest [glob -nocomplain -types f [file join $workspace_dir *.manifest]] {
        if {[string equal -nocase [absolute_path $manifest] [absolute_path $jtag_manifest_file]]} {
            continue
        }
        delete_generated_path $manifest
    }
    foreach path [list $boot_bin_file $boot_manifest_file $boot_stage_dir] {
        delete_generated_path $path
    }
    delete_sd_boot_outputs
}

proc invalidate_application_download_artifacts {} {
    global workspace_dir fsbl_elf_file

    invalidate_jtag_manifest
    invalidate_boot_outputs
    foreach pattern {*.bin *.manifest} {
        foreach artifact [glob -nocomplain -types f [file join $workspace_dir $pattern]] {
            delete_generated_path $artifact
        }
    }
    foreach elf [glob -nocomplain -types f [file join $workspace_dir *.elf]] {
        if {[string equal -nocase [absolute_path $elf] [absolute_path $fsbl_elf_file]]} {
            continue
        }
        delete_generated_path $elf
    }
}

proc invalidate_all_vitis_download_artifacts {} {
    global fsbl_elf_file

    invalidate_application_download_artifacts
    delete_generated_path $fsbl_elf_file
}

proc require_managed_build {} {
    global managed_build_marker

    set channel [open $managed_build_marker w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel "A Vitis-managed build is required after a project or source-set change."
    close $channel
}

proc clear_managed_build_requirement {} {
    global managed_build_marker

    if {[file isfile $managed_build_marker]} {
        file delete -force -- $managed_build_marker
    }
}

proc find_incremental_application_build_dir {} {
    global workspace_dir app_name managed_build_marker

    if {[file exists $managed_build_marker]} {
        return ""
    }
    set candidates {}
    foreach makefile [glob -nocomplain -types f \
            [file join $workspace_dir $app_name * makefile]] {
        set build_dir [file dirname $makefile]
        if {[file isfile [file join $build_dir "${app_name}.elf"]]} {
            lappend candidates $build_dir
        }
    }
    if {[llength $candidates] == 1} {
        return [lindex $candidates 0]
    }
    return ""
}

proc build_application_makefile {build_dir} {
    global worker_jobs

    set old_dir [pwd]
    set code [catch {
        cd $build_dir
        set output [exec make -j $worker_jobs --no-print-directory all 2>@1]
    } message options]
    cd $old_dir
    if {$code != 0} {
        return -options $options $message
    }
    if {[string trim $output] ne ""} {
        puts $output
    }
}

# 兼容处理：项目列表为空时，部分 Vitis 环境会抛出错误而非返回空字符串。
proc get_project_list {project_type} {
    set commands [dict create \
        application {app list} \
        system      {sysproj list} \
        platform    {platform list}]
    set empty_keywords [dict create \
        application {application app} \
        system      {system sysproj} \
        platform    {platform}]
    if {![dict exists $commands $project_type]} {
        error "Unsupported Vitis project type: $project_type"
    }

    set command [dict get $commands $project_type]
    if {[catch {uplevel #0 $command} projects options]} {
        foreach keyword [dict get $empty_keywords $project_type] {
            if {[regexp -nocase "no .*${keyword}.* exist" $projects]} {
                return {}
            }
        }
        return -options $options $projects
    }
    return $projects
}

proc clean_old_projects {} {
    global workspace_dir platform_name app_name

    set system_name "${app_name}_system"
    # This repository owns one generated Vitis project set. Remove every old
    # registration and every top-level Eclipse project so renamed applications
    # cannot leave nested ELF files or stale platforms behind.
    foreach name [get_project_list application] { catch {app remove $name} }
    catch {app remove $app_name}
    foreach name [get_project_list system]      { catch {sysproj remove $name} }
    catch {sysproj remove $system_name}
    foreach name [get_project_list platform]    { catch {platform remove $name} }
    catch {platform remove $platform_name}

    set old_names [list $platform_name $app_name $system_name]
    foreach directory [glob -nocomplain -types d [file join $workspace_dir *]] {
        if {[file isfile [file join $directory .project]]} {
            lappend old_names [file tail $directory]
        }
    }
    foreach name [lsort -unique $old_names] {
        delete_generated_path [file join $workspace_dir $name]
    }
}

proc restore_generated_projects {} {
    global workspace_dir platform_name app_name

    set system_name "${app_name}_system"
    foreach {project_type project_name} [list \
            platform $platform_name \
            system $system_name \
            application $app_name] {
        if {[list_contains [get_project_list $project_type] $project_name]} {
            continue
        }
        set project_dir [file join $workspace_dir $project_name]
        if {![file isfile [file join $project_dir .project]]} {
            continue
        }
        puts "Restoring generated Vitis project registration: $project_dir"
        if {[catch {importprojects $project_dir} message]} {
            set compact [string map [list "\r" " " "\n" " " "ERROR:" "error:"] $message]
            puts "WARNING: Unable to restore '$project_name'; full recreation may be required: $compact"
        }
    }
}

proc require_platform {} {
    global platform_name
    if {![list_contains [get_project_list platform] $platform_name]} {
        error "Platform project '$platform_name' does not exist. Run create first."
    }
}

proc require_application {} {
    global app_name
    if {![list_contains [get_project_list application] $app_name]} {
        error "Application project '$app_name' does not exist. Run create first."
    }
}

proc configure_application {} {
    global app_name app_libraries app_optimization

    foreach library $app_libraries {
        app config -name $app_name -add libraries $library
    }
    app config -name $app_name -set compiler-optimization $app_optimization
    puts "Application build settings: libraries=$app_libraries optimization=$app_optimization"
}

proc do_create {xsa} {
    global platform_name app_name domain_name processor os_name app_template source_dir

    set phase_started [clock milliseconds]

    invalidate_all_vitis_download_artifacts
    require_managed_build
    clean_old_projects
    platform create -name $platform_name -hw $xsa -proc $processor -os $os_name
    platform active $platform_name
    platform generate

    app create -name $app_name -platform $platform_name -domain $domain_name \
        -template $app_template
    configure_application
    importsources -name $app_name -path $source_dir -soft-link
    publish_fsbl

    puts "Vitis projects created: platform=$platform_name application=$app_name"
    emit_phase_metric platform_create $phase_started
}

proc do_update {xsa} {
    # XSCT 2022.2 emits an ERROR for platform config -updatehw when it sees
    # a valid Vivado XSA without the HwDb metadata it expects. That output
    # makes the launcher fail even if Tcl catches the error. Recreate only
    # generated Vitis projects instead; vitis/src stays persistent.
    puts "Recreating generated Vitis projects for hardware update."
    do_create $xsa
    puts "Hardware platform recreated: $xsa"
}

# JTAG downloads need the FSBL even when a QSPI BOOT.bin is not requested.
# Publish it alongside the stable application ELF after platform generation.
proc publish_fsbl {} {
    global workspace_dir platform_name fsbl_elf_file

    set generated_fsbl [absolute_path [file join $workspace_dir $platform_name export \
        $platform_name sw $platform_name boot fsbl.elf]]
    if {![file isfile $generated_fsbl] || [file size $generated_fsbl] <= 0} {
        error "Exported FSBL is missing or empty: $generated_fsbl. Run Vitis create/update with a valid PS XSA."
    }
    file copy -force -- $generated_fsbl $fsbl_elf_file
    if {![file isfile $fsbl_elf_file] || [file size $fsbl_elf_file] != [file size $generated_fsbl]} {
        error "Failed to publish stable FSBL: $fsbl_elf_file"
    }
    puts "FSBL published for JTAG: [absolute_path $fsbl_elf_file]"
}

proc do_build {} {
    global workspace_dir app_name app_elf_file

    set phase_started [clock milliseconds]

    require_sources
    invalidate_application_download_artifacts
    set incremental_build_dir [find_incremental_application_build_dir]
    if {$incremental_build_dir ne ""} {
        puts "Application build mode: incremental make (skips unchanged platform, FSBL, and BSP traversal)."
        build_application_makefile $incremental_build_dir
    } else {
        # XSCT 2022.2 does not always reload applications recorded in a previous
        # command-line session. Re-import existing generated projects before using
        # the expensive platform/application recreation fallback.
        if {![list_contains [get_project_list application] $app_name]} {
            restore_generated_projects
            if {![list_contains [get_project_list application] $app_name]} {
                set xsa [resolve_xsa]
                do_check $xsa
                puts "Application project cannot be restored; recreating generated Vitis projects."
                do_create $xsa
            }
        }
        require_application
        puts "Application build mode: Vitis managed (refreshes platform, FSBL, and BSP dependencies)."
        app build -name $app_name
        clear_managed_build_requirement
    }

    set elf_files [glob -nocomplain -types f \
        [file join $workspace_dir $app_name * "${app_name}.elf"]]
    if {[llength $elf_files] == 0 && $incremental_build_dir eq ""} {
        # An imported 2022.2 workspace can register the application while only
        # rebuilding its platform BSP. Recreate generated projects once rather
        # than publishing a stale or missing ELF.
        set xsa [resolve_xsa]
        do_check $xsa
        puts "Imported application produced no ELF; recreating generated Vitis projects once."
        do_create $xsa
        app build -name $app_name
        clear_managed_build_requirement
        set elf_files [glob -nocomplain -types f \
            [file join $workspace_dir $app_name * "${app_name}.elf"]]
    }
    if {[llength $elf_files] != 1} {
        error "Build finished but expected one ${app_name}.elf; found: $elf_files. Check build logs under [file join $workspace_dir $app_name Debug]."
    }
    set built_elf [absolute_path [lindex $elf_files 0]]
    if {[file size $built_elf] <= 0} {
        error "Application ELF is empty: $built_elf"
    }
    file copy -force -- $built_elf $app_elf_file
    if {![file isfile $app_elf_file] || [file size $app_elf_file] != [file size $built_elf]} {
        error "Failed to publish stable application ELF: $app_elf_file"
    }
    puts "Application build complete: [absolute_path $app_elf_file]"
    write_jtag_manifest [resolve_xsa]
    emit_phase_metric application_build $phase_started
}

proc do_sync {} {
    global app_name source_dir

    require_sources
    invalidate_application_download_artifacts
    if {![list_contains [get_project_list application] $app_name]} {
        restore_generated_projects
    }
    require_application
    importsources -name $app_name -path $source_dir -soft-link
    require_managed_build
    puts "Application sources synchronized: $source_dir"
    # XSCT 2022.2 can leave the Eclipse workspace dirty when importsources is
    # the last managed command in a session. Refresh the generated makefiles in
    # this same session, then let the required following build use direct make.
    puts "Refreshing the application source set with a managed Vitis build."
    app build -name $app_name
    clear_managed_build_requirement
    puts "Application source-set refresh completed: $app_name"
}

proc stage_boot_file {source target_name} {
    global boot_stage_dir
    file mkdir $boot_stage_dir
    set target [file join $boot_stage_dir $target_name]
    file copy -force -- $source $target
    return [absolute_path $target]
}

proc repo_relative_path {path} {
    global workspace_dir

    # Use a one-character backslash mapping. In a braced Tcl list, {\\ /}
    # matches two consecutive backslashes and leaves ordinary Windows paths
    # unchanged, which breaks the temporary-drive workflow on Windows.
    # The launcher can source this script through its original drive while
    # Vitis creates artifacts through the temporary workspace drive. Anchor
    # the repository check to the latter so both paths are comparable.
    set base   [string trimright \
        [string map [list "\\" "/"] [file dirname $workspace_dir]] "/"]
    set target [string map [list "\\" "/"] [absolute_path $path]]
    set prefix "${base}/"
    if {![string equal -nocase [string range $target 0 [expr {[string length $prefix] - 1}]] $prefix]} {
        error "Artifact is outside the repository: $target"
    }
    return [string range $target [string length $prefix] end]
}

proc sha256_file {path} {
    set output [exec certutil -hashfile $path SHA256]
    if {![regexp -nocase {[0-9a-f]{64}} $output hash]} {
        error "Unable to calculate SHA-256 for: $path"
    }
    return [string tolower $hash]
}

proc write_jtag_manifest {xsa} {
    global root_dir app_name app_elf_file fsbl_elf_file jtag_manifest_file

    set project_name [file rootname [file tail $xsa]]
    validate_project_name $project_name
    set bit_file [file join $root_dir prj "${project_name}.bit"]
    set artifacts [list \
        xsa             $xsa \
        bitstream       $bit_file \
        fsbl            $fsbl_elf_file \
        application_elf $app_elf_file]

    foreach {key path} $artifacts {
        if {![file isfile $path] || [file size $path] <= 0} {
            error "Cannot publish JTAG manifest; missing or empty $key artifact: $path"
        }
    }
    if {[file mtime $fsbl_elf_file] < [file mtime $xsa]} {
        error "FSBL is older than the selected XSA. Run Vitis update/create before build."
    }

    set values [dict create \
        manifest_version 1 \
        design_mode ps_pl \
        project_name $project_name \
        application_name $app_name]
    foreach {key path} $artifacts {
        dict set values "${key}_path" [repo_relative_path $path]
        dict set values "${key}_size" [file size $path]
        dict set values "${key}_sha256" [sha256_file $path]
    }

    set temp_file "${jtag_manifest_file}.tmp.[pid]"
    set channel [open $temp_file w]
    fconfigure $channel -encoding utf-8 -translation lf
    foreach key [lsort [dict keys $values]] {
        puts $channel "$key=[dict get $values $key]"
    }
    close $channel
    file rename -force -- $temp_file $jtag_manifest_file
    puts "JTAG manifest published: [absolute_path $jtag_manifest_file]"
}

proc write_boot_manifest {project_name bit_file app_file} {
    global app_name boot_manifest_file boot_bin_file fsbl_elf_file

    set artifacts [list \
        boot_bin        $boot_bin_file \
        fsbl            $fsbl_elf_file \
        bitstream       $bit_file \
        application_elf $app_file]
    set values [dict create \
        manifest_version 1 \
        project_name     $project_name \
        application_name $app_name \
        flash_type       qspi-x4-single \
        offset            0 \
        flash_capacity    33554432]
    foreach {key path} $artifacts {
        if {![file isfile $path] || [file size $path] <= 0} {
            error "Cannot record missing or empty boot artifact: $path"
        }
        dict set values "${key}_path" [repo_relative_path $path]
        dict set values "${key}_size" [file size $path]
        dict set values "${key}_mtime" [file mtime $path]
        dict set values "${key}_sha256" [sha256_file $path]
    }

    set temp_file "${boot_manifest_file}.tmp.[pid]"
    set channel [open $temp_file w]
    fconfigure $channel -encoding utf-8 -translation lf
    foreach key [lsort [dict keys $values]] {
        puts $channel "$key=[dict get $values $key]"
    }
    close $channel
    file rename -force -- $temp_file $boot_manifest_file
}

proc write_sd_manifest {project_name} {
    global app_name sd_manifest_file sd_boot_file boot_bin_file fsbl_elf_file

    foreach {description path} [list \
            {SD BOOT.bin} $sd_boot_file \
            {source BOOT.bin} $boot_bin_file \
            {FSBL ELF} $fsbl_elf_file] {
        if {![file isfile $path] || [file size $path] <= 0} {
            error "Cannot record missing or empty $description: $path"
        }
    }

    set values [dict create \
        manifest_version 1 \
        project_name $project_name \
        application_name $app_name \
        boot_source sd0 \
        filesystem FAT32 \
        sd_root_filename BOOT.bin \
        boot_bin_path [repo_relative_path $sd_boot_file] \
        boot_bin_size [file size $sd_boot_file] \
        boot_bin_sha256 [sha256_file $sd_boot_file] \
        source_boot_bin_path [repo_relative_path $boot_bin_file] \
        source_boot_bin_sha256 [sha256_file $boot_bin_file] \
        fsbl_path [repo_relative_path $fsbl_elf_file] \
        fsbl_sha256 [sha256_file $fsbl_elf_file]]

    set temp_file "${sd_manifest_file}.tmp.[pid]"
    set channel [open $temp_file w]
    fconfigure $channel -encoding utf-8 -translation lf
    foreach key [lsort [dict keys $values]] {
        puts $channel "$key=[dict get $values $key]"
    }
    close $channel
    file rename -force -- $temp_file $sd_manifest_file
}

proc publish_sd_boot {xsa} {
    global sd_boot_dir sd_boot_file boot_bin_file

    if {![file isfile $boot_bin_file] || [file size $boot_bin_file] <= 0} {
        error "Stable BOOT.bin is missing or empty: $boot_bin_file. Run the boot step first."
    }
    file mkdir $sd_boot_dir
    set temp_file [file join $sd_boot_dir ".BOOT.bin.[pid].tmp"]
    catch {file delete -force -- $temp_file}
    if {[catch {
        file copy -force -- $boot_bin_file $temp_file
        file rename -force -- $temp_file $sd_boot_file
    } message options]} {
        catch {file delete -force -- $temp_file}
        return -options $options $message
    }
    if {![file isfile $sd_boot_file] || [file size $sd_boot_file] != [file size $boot_bin_file]} {
        error "Failed to publish SD BOOT.bin: $sd_boot_file"
    }

    set project_name [file rootname [file tail $xsa]]
    write_sd_manifest $project_name
    puts "SD boot package published: [absolute_path $sd_boot_file]"
    puts "SD boot manifest published: [absolute_path $::sd_manifest_file]"
}

proc do_boot {xsa} {
    global root_dir script_dir workspace_dir platform_name app_name boot_mode boot_bif_file \
        boot_bin_file app_elf_file fsbl_elf_file

    set phase_started [clock milliseconds]

    if {![boot_mode_generates_image]} {
        error "The boot step requires boot_mode=ps_pl_qspi, ps_pl_sd, or ps_pl_qspi_sd; current boot_mode=$boot_mode"
    }
    if {![file isfile $boot_bif_file]} {
        error "Boot image template is missing: $boot_bif_file"
    }

    set fsbl [absolute_path [file join $workspace_dir $platform_name export \
        $platform_name sw $platform_name boot fsbl.elf]]
    if {![file isfile $fsbl] || [file size $fsbl] <= 0} {
        error "Exported FSBL is missing or empty: $fsbl. Run Vitis create/update before boot."
    }
    set project_name [file rootname [file tail $xsa]]
    validate_project_name $project_name
    set bit [absolute_path [file join $root_dir prj "${project_name}.bit"]]
    if {![file isfile $bit] || [file size $bit] <= 0} {
        error "Stable bitstream is missing or empty: $bit. Rebuild Vivado to publish prj/${project_name}.bit."
    }
    if {![file isfile $app_elf_file] || [file size $app_elf_file] <= 0} {
        error "Stable application ELF is missing or empty: $app_elf_file. Run the Vitis build step first."
    }
    if {[file mtime $fsbl] < [file mtime $xsa]} {
        error "FSBL is older than the selected XSA. Run Vitis update/create before boot."
    }
    if {[file mtime $app_elf_file] < [file mtime $xsa]} {
        error "Application ELF is older than the selected XSA. Run Vitis build before boot."
    }

    invalidate_boot_outputs
    file copy -force -- $fsbl $fsbl_elf_file
    if {![file isfile $fsbl_elf_file] || [file size $fsbl_elf_file] != [file size $fsbl]} {
        error "Failed to publish stable FSBL: $fsbl_elf_file"
    }

    set staged_fsbl [stage_boot_file $fsbl_elf_file fsbl.elf]
    set staged_bit  [stage_boot_file $bit system.bit]
    set staged_elf  [stage_boot_file $app_elf_file application.elf]
    puts "Boot inputs staged:"
    puts "  FSBL: $staged_fsbl"
    puts "  BIT : $staged_bit"
    puts "  ELF : $staged_elf"

    set bootgen_log_dir [file join $script_dir logs]
    file mkdir $bootgen_log_dir
    set bootgen_log [absolute_path [file join $bootgen_log_dir \
        "bootgen-[pid]-[clock clicks].log"]]
    set temp_boot_bin "${boot_bin_file}.tmp.[pid]"
    catch {file delete -force -- $temp_boot_bin}
    set old_dir [pwd]
    cd $script_dir
    set code [catch {
        exec bootgen -arch zynq -image $boot_bif_file -w -o $temp_boot_bin > $bootgen_log 2>@1
    } output options]
    cd $old_dir
    if {$code != 0} {
        catch {file delete -force -- $temp_boot_bin}
        return -options $options "bootgen failed while generating BOOT.bin. Log: $bootgen_log"
    }
    if {![file isfile $temp_boot_bin] || [file size $temp_boot_bin] <= 0} {
        catch {file delete -force -- $temp_boot_bin}
        error "bootgen finished but its BOOT.bin output is missing or empty. Log: $bootgen_log"
    }
    file rename -force -- $temp_boot_bin $boot_bin_file
    write_boot_manifest $project_name $bit $app_elf_file
    puts "Bootgen log: $bootgen_log"
    puts "Boot image generated: [absolute_path $boot_bin_file]"
    puts "Boot manifest generated: [absolute_path $::boot_manifest_file]"
    emit_phase_metric boot_image $phase_started
}

proc do_sd {xsa} {
    global boot_mode

    if {![boot_mode_requires_sd]} {
        error "Vitis sd requires boot_mode ps_pl_sd or ps_pl_qspi_sd; current boot_mode is '$boot_mode'."
    }
    do_boot $xsa
    publish_sd_boot $xsa
}

proc do_clean {} {
    global app_name

    require_application
    invalidate_application_download_artifacts
    app clean -name $app_name
    puts "Application build output cleaned: $app_name"
}

proc open_workspace {} {
    global workspace_dir

    cd $workspace_dir
    setws $workspace_dir
}

proc emit_next_hint {} {
    global step

    switch $step {
        help  { puts "NEXT: Choose the minimal Vitis step from AGENTS.md." }
        check { puts "NEXT: Vitis create, update, or build according to workspace state." }
        create - update - sync {
            puts "NEXT: Vitis build"
        }
        build {
            if {[boot_mode_requires_sd]} {
                puts "NEXT: Vitis sd for a boot package, or JTAG download after hardware confirmation."
            } elseif {[boot_mode_generates_image]} {
                puts "NEXT: Vitis boot, then QSPI preflight before any confirmed Flash write."
            } else {
                puts "NEXT: JTAG download only after board power and connection are confirmed."
            }
        }
        boot {
            if {[boot_mode_requires_sd]} {
                puts "NEXT: Vitis sd"
            } else {
                puts "NEXT: Run QSPI preflight before any confirmed Flash write."
            }
        }
        sd    { puts "NEXT: Copy sd_boot/BOOT.bin to a FAT32 card; the script does not write the card." }
        clean { puts "NEXT: Vitis build"
        }
        all   { puts "NEXT: Use JTAG, SD, or QSPI only after the required hardware confirmation." }
    }
}

proc main {} {
    global argv step workspace_dir platform_name app_name boot_mode template_config num_jobs worker_jobs

    require_xsct_version
    validate_project_name $platform_name
    validate_project_name $app_name
    validate_binary_configuration
    if {[string equal -nocase $app_name "fsbl"]} {
        error "Application name 'fsbl' is reserved for the stable FSBL download artifact."
    }
    validate_boot_mode
    if {![string is integer -strict $num_jobs] || $num_jobs < 1} {
        error "template_config(num_jobs) must be a positive integer; got '$num_jobs'."
    }
    set worker_jobs [expr {$num_jobs < 8 ? $num_jobs : 8}]
    puts "Vitis worker limit: $worker_jobs (num_jobs=$num_jobs)"

    if {!$template_config(use_bd) && $step ne "help"} {
        error "Pure-PL mode does not use Vitis or XSA. Run the Vivado flow and download the stable bitstream directly."
    }

    if {[llength $argv] > 2} {
        error "Unexpected arguments: [lrange $argv 2 end]"
    }
    if {[llength $argv] == 2 &&
        [lsearch -exact {check create update boot sd all} $step] < 0} {
        error "Step '$step' does not accept an XSA argument."
    }

    set publication_scope ""
    switch $step {
        create - update - all { set publication_scope vitis_all }
        sync - build         { set publication_scope vitis_application }
        boot - sd            { set publication_scope vitis_boot }
    }
    if {$publication_scope ne ""} {
        puts "PUBLISH_TRANSACTION: scope=$publication_scope state=started"
    }

    switch $step {
        help {
            print_usage
        }
        check {
            do_check [resolve_xsa]
        }
        create {
            set xsa [resolve_xsa]
            do_check $xsa
            reset_workspace_metadata
            open_workspace
            do_create $xsa
        }
        update {
            set xsa [resolve_xsa]
            do_check $xsa
            reset_workspace_metadata
            open_workspace
            do_update $xsa
        }
        sync {
            open_workspace
            do_sync
        }
        build {
            open_workspace
            do_build
        }
        boot {
            set xsa [resolve_xsa]
            do_check $xsa
            open_workspace
            do_boot $xsa
        }
        sd {
            set xsa [resolve_xsa]
            do_check $xsa
            open_workspace
            do_sd $xsa
        }
        clean {
            open_workspace
            do_clean
        }
        all {
            set xsa [resolve_xsa]
            do_check $xsa
            reset_workspace_metadata
            open_workspace
            do_create $xsa
            do_build
            if {[boot_mode_generates_image]} {
                do_boot $xsa
                if {[boot_mode_requires_sd]} {
                    publish_sd_boot $xsa
                }
            }
        }
        default {
            print_usage
            error "Unknown step: $step"
        }
    }
    if {$publication_scope ne ""} {
        puts "PUBLISH_TRANSACTION: scope=$publication_scope state=committed"
    }
    emit_next_hint
}

if {[catch {main} message options]} {
    puts stderr "ERROR: $message"
    if {[dict exists $options -errorinfo]} {
        puts stderr "DETAIL: [dict get $options -errorinfo]"
    }
    exit 1
}
puts "SUCCESS: Vitis step '$step' completed."
