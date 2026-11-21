# GBA consumer settings for EmbeddedVideoIP 1.0.
# Keep application geometry and source policy in this consumer repository.
set evip_expected_version "0.3.0-dev.2"
set evip_vlnv "panfpga.org:video:embedded_video_ip:1.0"
set evip_max_input_width 1280
set evip_max_input_height 720
set evip_enable_bram_source 0
set evip_enable_hls_source 0
set evip_enable_vdma_source 1
set evip_source_select_mode 1
set evip_fixed_source 2
set evip_format_select_mode 1
set evip_fixed_format 2
set evip_max_scaler_width 1280
set evip_max_scaler_height 720
set evip_enable_scaler 1
set evip_line_buffer_implementation 1
set evip_enable_hdmi_audio 1
set evip_control_offset 0x43010000
