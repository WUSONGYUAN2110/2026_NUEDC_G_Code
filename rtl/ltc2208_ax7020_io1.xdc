# AX7020 IO1 (J10) LTC2208 channel-B constraints.
#
# This file contains only board pin assignments and electrical properties.
# The AX7020 PL_GCLK pin is documented in the board IO table and belongs in
# the project top-level design, not in this reusable ADC pin reference.
# Clock and input-timing constraints must be added by the parent design after
# its actual adc_drive_clk/sample_clk clock plan is known.
#
# IMPORTANT:
# - adc_b_clk is an FPGA output connected to the LTC2208-B ENC+ input.
#   They are forwarded encode clocks, not ADC CLKOUT return clocks.
# - Do not apply the LTC2208 DATA-to-CLKOUT +/-0.6 ns skew directly to this
#   interface.  With the present wiring, set_input_delay must include the
#   LTC2208 ENC-to-DATA min/max delay plus the outbound/inbound PCB delays.
# - The parent design must create the forwarded/generated encode clock, define
#   the capture-clock phase, and constrain both setup and hold.  Numeric delays
#   cannot be made active here until that clock topology and the board delays
#   are known.  The parent design currently uses the board-measured 135-degree
#   inherited capture phase only as a starting point; channel B still needs
#   its own documented stable phase-sweep window and final setup/hold evidence.

# This reference is also loaded while a PS-only block-design skeleton is being
# built.  The -quiet form leaves these constraints inactive until the ADC front
# end is integrated into the actual top level.  Interface completeness must be
# checked by the parent design and DRC; managed XDC files do not support Tcl
# flow-control commands such as if/unset.

# J10 PIN19..PIN36: channel B data B15, B13, ..., B0 and AD_CLKB.
set_property -quiet PACKAGE_PIN U17 [get_ports -quiet {adc_b_data[15]}]
set_property -quiet PACKAGE_PIN V18 [get_ports -quiet {adc_b_data[13]}]
set_property -quiet PACKAGE_PIN V17 [get_ports -quiet {adc_b_data[14]}]
set_property -quiet PACKAGE_PIN T15 [get_ports -quiet {adc_b_data[11]}]
set_property -quiet PACKAGE_PIN T14 [get_ports -quiet {adc_b_data[12]}]
set_property -quiet PACKAGE_PIN V13 [get_ports -quiet {adc_b_data[9]}]
set_property -quiet PACKAGE_PIN U13 [get_ports -quiet {adc_b_data[10]}]
set_property -quiet PACKAGE_PIN W13 [get_ports -quiet {adc_b_data[7]}]
set_property -quiet PACKAGE_PIN V12 [get_ports -quiet {adc_b_data[8]}]
set_property -quiet PACKAGE_PIN U12 [get_ports -quiet {adc_b_data[5]}]
set_property -quiet PACKAGE_PIN T12 [get_ports -quiet {adc_b_data[6]}]
set_property -quiet PACKAGE_PIN T10 [get_ports -quiet {adc_b_data[3]}]
set_property -quiet PACKAGE_PIN T11 [get_ports -quiet {adc_b_data[4]}]
set_property -quiet PACKAGE_PIN A20 [get_ports -quiet {adc_b_data[1]}]
set_property -quiet PACKAGE_PIN B19 [get_ports -quiet {adc_b_data[2]}]
set_property -quiet PACKAGE_PIN B20 [get_ports -quiet adc_b_clk]
set_property -quiet PACKAGE_PIN C20 [get_ports -quiet {adc_b_data[0]}]

set_property -quiet IOSTANDARD LVCMOS33 [get_ports -quiet {adc_b_data[*]}]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports -quiet adc_b_clk]
set_property -quiet DRIVE 8 [get_ports -quiet adc_b_clk]
set_property -quiet SLEW FAST [get_ports -quiet adc_b_clk]
