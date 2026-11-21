# EmbeddedVideoIP CDC policy.
# Synchronizer inputs and async reset pins are excluded from synchronous timing.
# Gray FIFO pointers remain timed by max-delay and bus-skew constraints.
set_false_path -quiet \
  -from [get_clocks -quiet -of_objects [get_ports -quiet aclk]] \
  -to [get_pins -quiet -of_objects [get_cells -quiet -hier -filter {ASYNC_REG == TRUE && NAME !~ *rd_gray_wsync1_reg* && NAME !~ *wr_gray_rsync1_reg*}] -filter {REF_PIN_NAME == D}]
set_false_path -quiet \
  -from [get_clocks -quiet -of_objects [get_ports -quiet audio_pcm_clk]] \
  -to [get_pins -quiet -of_objects [get_cells -quiet -hier -filter {ASYNC_REG == TRUE && NAME !~ *rd_gray_wsync1_reg* && NAME !~ *wr_gray_rsync1_reg*}] -filter {REF_PIN_NAME == D}]
set_false_path -quiet \
  -from [get_clocks -quiet -include_generated_clocks -of_objects [get_ports -quiet hdmi_ref_clk]] \
  -to [get_pins -quiet -of_objects [get_cells -quiet -hier -filter {ASYNC_REG == TRUE && NAME !~ *rd_gray_wsync1_reg* && NAME !~ *wr_gray_rsync1_reg*}] -filter {REF_PIN_NAME == D}]

set_false_path -quiet \
  -from [get_clocks -quiet -of_objects [get_ports -quiet aclk]] \
  -to [get_pins -quiet -of_objects [get_cells -quiet -hier -filter {ASYNC_REG == TRUE}] -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
set_false_path -quiet \
  -from [get_clocks -quiet -of_objects [get_ports -quiet audio_pcm_clk]] \
  -to [get_pins -quiet -of_objects [get_cells -quiet -hier -filter {ASYNC_REG == TRUE}] -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
set_false_path -quiet \
  -from [get_clocks -quiet -include_generated_clocks -of_objects [get_ports -quiet hdmi_ref_clk]] \
  -to [get_pins -quiet -of_objects [get_cells -quiet -hier -filter {ASYNC_REG == TRUE}] -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]

# The PCM FIFO holds each sample until its synchronized read pointer permits capture.
set_false_path -quiet \
  -from [get_clocks -quiet -of_objects [get_ports -quiet audio_pcm_clk]] \
  -to [get_pins -quiet -hier -filter {NAME =~ *sample_buffer_reg*/D}]

# Bound both directions of the asynchronous FIFO Gray-pointer bus.
set_max_delay -quiet -datapath_only 8.000 \
  -from [get_pins -quiet -hier -filter {NAME =~ *u_audio_fifo/rd_gray_reg*/Q}] \
  -to [get_pins -quiet -hier -filter {NAME =~ *u_audio_fifo/rd_gray_wsync1_reg*/D}]
set_bus_skew -quiet 3.000 \
  -from [get_pins -quiet -hier -filter {NAME =~ *u_audio_fifo/rd_gray_reg*/Q}] \
  -to [get_pins -quiet -hier -filter {NAME =~ *u_audio_fifo/rd_gray_wsync1_reg*/D}]
set_max_delay -quiet -datapath_only 8.000 \
  -from [get_pins -quiet -hier -filter {NAME =~ *u_audio_fifo/wr_gray_reg*/Q}] \
  -to [get_pins -quiet -hier -filter {NAME =~ *u_audio_fifo/wr_gray_rsync1_reg*/D}]
set_bus_skew -quiet 3.000 \
  -from [get_pins -quiet -hier -filter {NAME =~ *u_audio_fifo/wr_gray_reg*/Q}] \
  -to [get_pins -quiet -hier -filter {NAME =~ *u_audio_fifo/wr_gray_rsync1_reg*/D}]

# VGA and HD profiles are selected by a mutually exclusive clock mux.
# Do not time data paths between inactive profile clocks.
set_clock_groups -quiet -logically_exclusive \
  -group [get_clocks -quiet -regexp {.*embedded_video_ip_video_out_clk_wiz_vga_0.*}] \
  -group [get_clocks -quiet -regexp {.*embedded_video_ip_video_out_clk_wiz_hd_0.*}]

# BUFGCTRL S pins are dedicated glitch-free asynchronous clock selectors.
# They do not use the destination clock's setup/hold timing model.
set_false_path -quiet -to [get_pins -quiet -hier -filter {NAME =~ *u_pixel_clock_profile_mux/S0 || NAME =~ *u_pixel_clock_profile_mux/S1 || NAME =~ *u_serial_clock_profile_mux/S0 || NAME =~ *u_serial_clock_profile_mux/S1}]

# The reset IP filters its asynchronous external request into the pixel domain.
set_false_path -quiet -to [get_pins -quiet -hier -filter {NAME =~ *pixel_reset/U0/EXT_LPF/lpf_int_reg/D}]
