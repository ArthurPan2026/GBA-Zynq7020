# EmbeddedVideoIP CDC policy.
# Synchronizer inputs and async reset pins are excluded from synchronous timing.
# Gray FIFO pointers remain timed by max-delay and bus-skew constraints.
# The serializer MMCM output dividers change only while video logic is reset.
# Each legal mode has its own clock model; different modes never coexist.
set evip_vga_in [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/serializer_mmcm/CLKIN1}]
set evip_hd_in [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/serializer_mmcm/CLKIN2}]
set evip_hd_root [get_clocks -quiet -of_objects [get_pins -quiet -hier -filter {NAME =~ *clocks/hd_reference/CLKOUT0}]]
set evip_vga_root [get_clocks -quiet -of_objects [get_pins -quiet -hier -filter {NAME =~ *clocks/vga_reference/inst/mmcm_adv_inst/CLKOUT1}]]

# The MMCM has separate period-accurate inputs for VGA and HD references.
# -add keeps each mutually-exclusive profile on the corresponding buffer pin.
create_generated_clock -name evip_480_serial -add -source $evip_vga_in -master_clock $evip_vga_root -multiply_by 5 -divide_by 5 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/u_tmds_bufio/O}]
create_generated_clock -name evip_480_serdes -add -source $evip_vga_in -master_clock $evip_vga_root -multiply_by 5 -divide_by 25 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/u_serdes_bufr/O}]
create_generated_clock -name evip_480_pixel -add -source $evip_vga_in -master_clock $evip_vga_root -multiply_by 5 -divide_by 25 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/logic_pixel_buffer/O}]
create_generated_clock -name evip_480_monitor -add -source $evip_vga_in -master_clock $evip_vga_root -multiply_by 5 -divide_by 5 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/serial_monitor_buffer/O}]
create_generated_clock -name evip_720_serial -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 2 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/u_tmds_bufio/O}]
create_generated_clock -name evip_720_serdes -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 10 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/u_serdes_bufr/O}]
create_generated_clock -name evip_720_pixel -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 10 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/logic_pixel_buffer/O}]
create_generated_clock -name evip_720_monitor -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 5 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/serial_monitor_buffer/O}]
create_generated_clock -name evip_1080p30_serial -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 2 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/u_tmds_bufio/O}]
create_generated_clock -name evip_1080p30_serdes -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 10 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/u_serdes_bufr/O}]
create_generated_clock -name evip_1080p30_pixel -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 10 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/logic_pixel_buffer/O}]
create_generated_clock -name evip_1080p30_monitor -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 5 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/serial_monitor_buffer/O}]
create_generated_clock -name evip_1080p60_serial -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 1 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/u_tmds_bufio/O}]
create_generated_clock -name evip_1080p60_serdes -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 5 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/u_serdes_bufr/O}]
create_generated_clock -name evip_1080p60_pixel -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 5 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/logic_pixel_buffer/O}]
create_generated_clock -name evip_1080p60_monitor -add -source $evip_hd_in -master_clock $evip_hd_root -multiply_by 5 -divide_by 5 [get_pins -quiet -hier -filter {NAME =~ *video_output/clocks/serial_monitor_buffer/O}]
set_clock_groups -name evip_runtime_modes -physically_exclusive \
  -group [get_clocks evip_480_*] -group [get_clocks evip_720_*] \
  -group [get_clocks evip_1080p30_*] -group [get_clocks evip_1080p60_*] \
  -group [get_clocks {mmcm_feedback raw_serial raw_pixel logic_pixel_raw monitor_raw serdes_pixel_clk}] \
  -group [get_clocks {mmcm_feedback_1 raw_serial_1 raw_pixel_1 logic_pixel_raw_1 monitor_raw_1 serdes_pixel_clk_1}]

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
  -from [get_clocks -quiet evip_*] \
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
set_false_path -quiet \
  -from [get_clocks -quiet evip_*] \
  -to [get_pins -quiet -of_objects [get_cells -quiet -hier -filter {ASYNC_REG == TRUE}] -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]

# Audio samples become visible in the pixel domain only after the write pointer
# has crossed the FIFO's two-stage synchronizer. The distributed-RAM data bus is
# therefore an asynchronous FIFO payload path, not a same-edge clock path. Keep
# the exception limited to the capture registers; Gray pointers stay constrained.
set_false_path -quiet \
  -from [get_clocks -quiet -of_objects [get_ports -quiet audio_pcm_clk]] \
  -to [get_pins -quiet -hier -filter {NAME =~ *gain_sample_left_reg*/D || NAME =~ *gain_sample_right_reg*/D}]

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

# CLKINSEL selects the active MMCM reference only while the MMCM is reset.
set_false_path -quiet -to [get_pins -quiet -hier -filter {NAME =~ *serializer_mmcm/CLKINSEL}]
