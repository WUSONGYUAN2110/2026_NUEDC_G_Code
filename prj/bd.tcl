# G题 LTC2208 PS+PL measurement pipeline.
global template_config

set design_name "system"
set root_dir [file normalize [file join [file dirname [info script]] ..]]
set fir_coe [file normalize [file join $root_dir rtl fir_decimate_25.coe]]

proc connect_pins {args} {
    set pins {}
    foreach pin $args {
        lappend pins [get_bd_pins $pin]
    }
    connect_bd_net {*}$pins
}

proc connect_interfaces {left right} {
    connect_bd_intf_net [get_bd_intf_pins $left] [get_bd_intf_pins $right]
}

proc read_fir_vector {path} {
    set channel [open $path r]
    fconfigure $channel -encoding ascii
    set text [read $channel]
    close $channel
    if {![regexp -nocase {coefdata\s*=\s*([^;]+);} $text -> vector]} {
        error "Unable to parse FIR coefficient vector: $path"
    }
    regsub -all {\s+} $vector {} vector
    return $vector
}

create_bd_design $design_name
current_bd_design $design_name

set ps7 [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ     {33.333333} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE        {DDR 3} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO             {MT41J256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH         {32 Bits} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ           {533.333} \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE           {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE           {LVCMOS 1.8V} \
    CONFIG.PCW_USE_M_AXI_GP0                   {1} \
    CONFIG.PCW_USE_S_AXI_HP0                   {1} \
    CONFIG.PCW_USE_S_AXI_HP1                   {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT            {1} \
    CONFIG.PCW_IRQ_F2P_INTR                    {1} \
    CONFIG.PCW_IRQ_F2P_MODE                    {DIRECT} \
    CONFIG.PCW_EN_CLK0_PORT                    {1} \
    CONFIG.PCW_EN_RST0_PORT                    {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ        {100} \
] $ps7

if {$template_config(enable_uart1)} {
    set_property CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} $ps7
    set_property CONFIG.PCW_UART1_UART1_IO \
        $template_config(uart1_io) $ps7
}

if {$template_config(enable_qspi_boot)} {
    set_property -dict [list \
        CONFIG.PCW_QSPI_PERIPHERAL_ENABLE     {1} \
        CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE {1} \
        CONFIG.PCW_QSPI_QSPI_IO               {MIO 1 .. 6} \
        CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO      {MIO 1 .. 6} \
        CONFIG.PCW_SINGLE_QSPI_DATA_MODE      {x4} \
    ] $ps7
}

if {$template_config(enable_gpio_mio)} {
    set_property -dict [list \
        CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
        CONFIG.PCW_GPIO_MIO_GPIO_IO     {MIO} \
    ] $ps7
}

apply_bd_automation \
    -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "0"} \
    $ps7

# External ADC and board-clock ports.
set sys_clk [create_bd_port -dir I -type clk -freq_hz 50000000 sys_clk]
set adc_data [create_bd_port -dir I -from 15 -to 0 adc_b_data]
set adc_clk [create_bd_port -dir O -type clk adc_b_clk]
set_property CONFIG.FREQ_HZ 50000000 $adc_clk

# Constants and resets.
set const_zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero]
set_property CONFIG.CONST_VAL {0} $const_zero
set const_one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one]
set_property CONFIG.CONST_VAL {1} $const_one

set reset_not [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:util_vector_logic:2.0 reset_not]
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] $reset_not
connect_pins ps7/FCLK_RESET0_N reset_not/Op1

set adc_clock [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 adc_clock]
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ                    {50.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ      {50.000} \
    CONFIG.CLKOUT1_REQUESTED_PHASE         {0.000} \
    CONFIG.CLKOUT2_USED                    {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ      {50.000} \
    CONFIG.CLKOUT2_REQUESTED_PHASE         {135.000} \
    CONFIG.USE_LOCKED                      {true} \
    CONFIG.USE_RESET                       {true} \
] $adc_clock
connect_bd_net $sys_clk [get_bd_pins adc_clock/clk_in1]
connect_pins const_zero/dout adc_clock/reset

set rst_axi [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_axi]
connect_pins ps7/FCLK_CLK0 rst_axi/slowest_sync_clk
connect_pins reset_not/Res rst_axi/ext_reset_in
connect_pins const_one/dout rst_axi/dcm_locked

set rst_adc [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_adc]
connect_pins adc_clock/clk_out2 rst_adc/slowest_sync_clk
connect_pins reset_not/Res rst_adc/ext_reset_in
connect_pins adc_clock/locked rst_adc/dcm_locked

# Fixed LTC2208 channel-B front end.  Channel A is not sampled or clocked.
set frontend [create_bd_cell -type module \
    -reference ltc2208_b_frontend frontend]
connect_pins adc_clock/clk_out1 frontend/adc_drive_clk
connect_pins adc_clock/clk_out2 frontend/sample_clk
connect_pins rst_adc/peripheral_reset frontend/sample_reset
connect_bd_net $adc_data [get_bd_pins frontend/adc_b_data]
connect_bd_net [get_bd_pins frontend/adc_b_clk] $adc_clk

# 625-tap, 25:1 official polyphase FIR.
set fir [create_bd_cell -type ip -vlnv xilinx.com:ip:fir_compiler:7.2 fir_decimator]
set fir_vector [read_fir_vector $fir_coe]
# The integer Q1.23 coefficient sum is 2^23.  FIR Compiler selects one extra
# headroom bit when a 24-bit output is requested, producing a fixed 0.5 gain.
# Keep the unity-gain 25-bit result and saturate explicitly back to the
# existing signed Q8 24-bit stream below.
set_property -dict [list \
    CONFIG.Filter_Type                 {Decimation} \
    CONFIG.Rate_Change_Type            {Integer} \
    CONFIG.Decimation_Rate             {25} \
    CONFIG.CoefficientSource           {Vector} \
    CONFIG.CoefficientVector           $fir_vector \
    CONFIG.Coefficient_Width           {24} \
    CONFIG.Data_Width                  {24} \
    CONFIG.Output_Width                {25} \
    CONFIG.Output_Rounding_Mode        {Convergent_Rounding_to_Even} \
    CONFIG.Clock_Frequency             {50} \
    CONFIG.Sample_Frequency            {50} \
    CONFIG.Has_ARESETn                 {true} \
] $fir
connect_pins adc_clock/clk_out2 fir_decimator/aclk
connect_pins rst_adc/peripheral_aresetn fir_decimator/aresetn
connect_interfaces frontend/m_axis fir_decimator/S_AXIS_DATA

set fir_saturator [create_bd_cell -type module \
    -reference axis_signed_saturate_25_to_24 fir_saturator]
connect_pins adc_clock/clk_out2 fir_saturator/aclk
connect_interfaces fir_decimator/M_AXIS_DATA fir_saturator/s_axis

set axis_cdc [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axis_clock_converter:1.1 axis_cdc]
set_property CONFIG.TDATA_NUM_BYTES {3} $axis_cdc
connect_pins adc_clock/clk_out2 axis_cdc/s_axis_aclk
connect_pins rst_adc/peripheral_aresetn axis_cdc/s_axis_aresetn
connect_pins ps7/FCLK_CLK0 axis_cdc/m_axis_aclk
connect_pins rst_axi/peripheral_aresetn axis_cdc/m_axis_aresetn
connect_interfaces fir_saturator/m_axis axis_cdc/S_AXIS

set sample_fifo [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axis_data_fifo:2.0 sample_fifo]
# The radix-2 burst FFT temporarily backpressures the shared sample stream.
# A 4096-word FIFO was observed to empty exactly at a 4096-sample phase jump
# on hardware.  Buffer half a short record so the continuous ADC/FIR stream
# remains lossless while the FFT completes its non-input phases.
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {3} \
    CONFIG.FIFO_DEPTH {32768} \
    CONFIG.HAS_TLAST {1} \
] $sample_fifo
connect_pins ps7/FCLK_CLK0 sample_fifo/s_axis_aclk
connect_pins rst_axi/peripheral_aresetn sample_fifo/s_axis_aresetn
connect_interfaces axis_cdc/M_AXIS sample_fifo/S_AXIS

# PS-visible control/status GPIO.
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 measurement_gpio]
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {32} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_ALL_INPUTS_2 {1} \
] $gpio

set control [create_bd_cell -type module \
    -reference measurement_control_status control_status]
connect_pins ps7/FCLK_CLK0 control_status/aclk
connect_pins rst_axi/peripheral_aresetn control_status/aresetn
connect_bd_net [get_bd_pins measurement_gpio/gpio_io_o] [get_bd_pins control_status/control_word]
connect_bd_net [get_bd_pins control_status/status_word] [get_bd_pins measurement_gpio/gpio2_io_i]
connect_pins adc_clock/locked control_status/mmcm_locked
connect_pins frontend/input_stall_sticky control_status/frontend_stall

# Official broadcaster creates independent time and FFT branches.  Each branch
# uses the same frame builder so frame IDs and boundaries remain identical.
set broadcaster [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axis_broadcaster:1.1 sample_broadcaster]
set_property -dict [list \
    CONFIG.NUM_MI {2} \
    CONFIG.S_TDATA_NUM_BYTES {3} \
    CONFIG.M_TDATA_NUM_BYTES {3} \
] $broadcaster
connect_pins ps7/FCLK_CLK0 sample_broadcaster/aclk
connect_pins rst_axi/peripheral_aresetn sample_broadcaster/aresetn
connect_interfaces sample_fifo/M_AXIS sample_broadcaster/S_AXIS

foreach router_name {time_router fft_router} {
    set router [create_bd_cell -type module \
        -reference measurement_frame_router $router_name]
    connect_pins ps7/FCLK_CLK0 ${router_name}/aclk
    connect_pins rst_axi/peripheral_aresetn ${router_name}/aresetn
    connect_pins control_status/run ${router_name}/run
    connect_pins control_status/soft_reset ${router_name}/soft_reset
    connect_pins control_status/capture_epoch ${router_name}/capture_epoch
    connect_pins adc_clock/locked ${router_name}/mmcm_locked
    connect_pins frontend/input_stall_sticky ${router_name}/frontend_stall
    connect_bd_net [get_bd_pins frontend/clip_count_total] \
        [get_bd_pins ${router_name}/clip_count_total]
    connect_bd_net [get_bd_pins frontend/jump_count_total] \
        [get_bd_pins ${router_name}/jump_count_total]
    connect_bd_net [get_bd_pins frontend/saturation_run_max] \
        [get_bd_pins ${router_name}/saturation_run_max]
    connect_bd_net [get_bd_pins frontend/raw_min_code] \
        [get_bd_pins ${router_name}/raw_min_code]
    connect_bd_net [get_bd_pins frontend/raw_max_code] \
        [get_bd_pins ${router_name}/raw_max_code]
}
connect_pins const_zero/dout time_router/fft_enable
connect_pins const_one/dout time_router/m_fft_tready
connect_pins control_status/fft_enable fft_router/fft_enable
connect_pins const_one/dout fft_router/m_time_tready
connect_interfaces sample_broadcaster/M00_AXIS time_router/s_axis
connect_interfaces sample_broadcaster/M01_AXIS fft_router/s_axis
connect_pins time_router/frame_active control_status/frame_active
connect_pins fft_router/frame_active control_status/fft_frame_active

# Streaming window multiplier with an inferred block-ROM coefficient table.
set window [create_bd_cell -type module \
    -reference blackman_harris_window fft_window]
connect_pins ps7/FCLK_CLK0 fft_window/aclk
connect_pins rst_axi/peripheral_aresetn fft_window/aresetn
connect_bd_net [get_bd_pins fft_router/fft_mean_q8] \
    [get_bd_pins fft_window/frame_mean_q8]
connect_interfaces fft_router/m_fft fft_window/s_axis

# 65536-point official FFT, natural order, block floating point.
set fft [create_bd_cell -type ip -vlnv xilinx.com:ip:xfft:9.1 fft]
set_property -dict [list \
    CONFIG.transform_length        {65536} \
    CONFIG.implementation_options  {radix_2_burst_io} \
    CONFIG.data_format             {fixed_point} \
    CONFIG.input_width             {24} \
    CONFIG.phase_factor_width      {24} \
    CONFIG.scaling_options         {block_floating_point} \
    CONFIG.output_ordering         {natural_order} \
    CONFIG.rounding_modes          {convergent_rounding} \
    CONFIG.memory_options_data     {block_ram} \
    CONFIG.memory_options_phase_factors {block_ram} \
    CONFIG.memory_options_reorder  {block_ram} \
    CONFIG.aresetn                 {true} \
    CONFIG.target_clock_frequency  {100} \
    CONFIG.target_data_throughput  {2} \
] $fft
connect_pins ps7/FCLK_CLK0 fft/aclk
connect_pins rst_axi/peripheral_aresetn fft/aresetn
connect_interfaces fft_window/m_axis fft/S_AXIS_DATA

set fft_config [create_bd_cell -type module \
    -reference fft_config_source fft_config]
connect_pins ps7/FCLK_CLK0 fft_config/aclk
connect_pins rst_axi/peripheral_aresetn fft_config/aresetn
connect_interfaces fft_config/m_axis fft/S_AXIS_CONFIG

set fft_event_concat [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconcat:2.1 fft_event_concat]
set_property CONFIG.NUM_PORTS {6} $fft_event_concat
connect_pins fft/event_frame_started fft_event_concat/In0
connect_pins fft/event_tlast_unexpected fft_event_concat/In1
connect_pins fft/event_tlast_missing fft_event_concat/In2
connect_pins fft/event_data_in_channel_halt fft_event_concat/In3
connect_pins fft/event_data_out_channel_halt fft_event_concat/In4
connect_pins fft/event_status_channel_halt fft_event_concat/In5
connect_bd_net [get_bd_pins fft_event_concat/dout] [get_bd_pins control_status/fft_events]

set packer [create_bd_cell -type module \
    -reference fft_spectrum_packer spectrum_packer]
connect_pins ps7/FCLK_CLK0 spectrum_packer/aclk
connect_pins rst_axi/peripheral_aresetn spectrum_packer/aresetn
connect_pins control_status/soft_reset spectrum_packer/soft_reset
connect_pins fft_router/fft_frame_start spectrum_packer/frame_start
connect_bd_net [get_bd_pins fft_router/fft_frame_id] [get_bd_pins spectrum_packer/frame_id]
connect_bd_net [get_bd_pins fft_router/fft_frame_epoch] \
    [get_bd_pins spectrum_packer/frame_epoch]
connect_bd_net [get_bd_pins fft_router/fft_mean_q8] [get_bd_pins spectrum_packer/frame_mean_q8]
connect_interfaces fft/M_AXIS_DATA spectrum_packer/s_axis
connect_interfaces fft/M_AXIS_STATUS spectrum_packer/s_status
connect_bd_net [get_bd_pins fft_event_concat/dout] [get_bd_pins spectrum_packer/fft_events]
connect_pins spectrum_packer/busy control_status/spectrum_busy

# Two receive-only SG DMA engines.
set dma_time [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma_time]
set_property -dict [list \
    CONFIG.c_include_sg {1} \
    CONFIG.c_include_mm2s {0} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_s2mm_burst_size {64} \
] $dma_time
connect_interfaces time_router/m_time dma_time/S_AXIS_S2MM

set dma_spectrum [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma_spectrum]
set_property -dict [list \
    CONFIG.c_include_sg {1} \
    CONFIG.c_include_mm2s {0} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
    CONFIG.c_s2mm_burst_size {64} \
] $dma_spectrum
connect_interfaces spectrum_packer/m_axis dma_spectrum/S_AXIS_S2MM

# GP0 control interconnect.
set ctrl_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ctrl_ic]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] $ctrl_ic
connect_interfaces ps7/M_AXI_GP0 ctrl_ic/S00_AXI
connect_interfaces ctrl_ic/M00_AXI dma_time/S_AXI_LITE
connect_interfaces ctrl_ic/M01_AXI dma_spectrum/S_AXI_LITE
connect_interfaces ctrl_ic/M02_AXI measurement_gpio/S_AXI

# HP0 and HP1 each carry descriptor and payload traffic for one DMA.
set hp0_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hp0_ic]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $hp0_ic
connect_interfaces dma_time/M_AXI_SG hp0_ic/S00_AXI
connect_interfaces dma_time/M_AXI_S2MM hp0_ic/S01_AXI
connect_interfaces hp0_ic/M00_AXI ps7/S_AXI_HP0

set hp1_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hp1_ic]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $hp1_ic
connect_interfaces dma_spectrum/M_AXI_SG hp1_ic/S00_AXI
connect_interfaces dma_spectrum/M_AXI_S2MM hp1_ic/S01_AXI
connect_interfaces hp1_ic/M00_AXI ps7/S_AXI_HP1

# Shared 100 MHz AXI clocks and resets.
foreach pin {
    ps7/M_AXI_GP0_ACLK ps7/S_AXI_HP0_ACLK ps7/S_AXI_HP1_ACLK
    ctrl_ic/aclk hp0_ic/aclk hp1_ic/aclk
    measurement_gpio/s_axi_aclk
    dma_time/s_axi_lite_aclk dma_time/m_axi_sg_aclk dma_time/m_axi_s2mm_aclk
    dma_spectrum/s_axi_lite_aclk dma_spectrum/m_axi_sg_aclk
    dma_spectrum/m_axi_s2mm_aclk
} {
    connect_pins ps7/FCLK_CLK0 $pin
}
foreach pin {
    ctrl_ic/aresetn hp0_ic/aresetn hp1_ic/aresetn measurement_gpio/s_axi_aresetn
    dma_time/axi_resetn dma_spectrum/axi_resetn
} {
    connect_pins rst_axi/peripheral_aresetn $pin
}

# DMA interrupts into PS IRQ_F2P[1:0].
set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 irq_concat]
set_property CONFIG.NUM_PORTS {2} $irq_concat
connect_pins dma_time/s2mm_introut irq_concat/In0
connect_pins dma_spectrum/s2mm_introut irq_concat/In1
connect_bd_net [get_bd_pins irq_concat/dout] [get_bd_pins ps7/IRQ_F2P]

assign_bd_address
regenerate_bd_layout
