# AX7020 template shared configuration.
# Keep each assignment on one line: PowerShell download helpers also read
# use_bd from this file to select PS+PL or pure-PL behavior.

# Vivado project
set template_config(proj_name)    "g_signal_analyzer"
set template_config(top_name)     "system_wrapper"
set template_config(default_tb)   "tb_measurement_pl"
set template_config(default_time) "5ms"
set template_config(part)         "xc7z020clg400-2"
set template_config(num_jobs)     8
set template_config(use_bd)       1

# PS7 board peripherals used when use_bd=1
set template_config(enable_qspi_boot) 1
set template_config(enable_uart1)     1
set template_config(uart1_io)         "MIO 8 .. 9"
set template_config(enable_sd0)       0
set template_config(enable_gpio_mio)  1
set template_config(enable_fclk0)     1
set template_config(fclk0_mhz)        100

# Optional single-clock ILA (generated files stay under prj/)
set template_config(enable_ila)         0
set template_config(ila_clock_net)      ""
set template_config(ila_probe_patterns) {}
set template_config(ila_data_depth)     1024

# Vitis project
set template_config(platform_name) "g_signal_platform"
set template_config(app_name)      "g_signal_app"
set template_config(domain_name)   "standalone_domain"
set template_config(processor)     "ps7_cortexa9_0"
set template_config(os_name)       "standalone"
set template_config(app_template)  "Empty Application"
set template_config(app_libraries) {m}
set template_config(app_optimization) "Optimize more (-O2)"
set template_config(boot_mode)     "ps_pl_qspi"
