# 把分散的HDMI视频单元替换成单一EmbeddedVideoIP复合IP。
proc evip_bd_disconnect_pin {pin_path} {
    set pin [get_bd_pins -quiet $pin_path]
    if {[llength $pin] == 0} { return }
    set nets [get_bd_nets -quiet -of_objects $pin]
    foreach net $nets {
        disconnect_bd_net $net $pin
    }
}

proc evip_bd_disconnect_intf {pin_path} {
    set pin [get_bd_intf_pins -quiet $pin_path]
    if {[llength $pin] == 0} { return }
    set nets [get_bd_intf_nets -quiet -of_objects $pin]
    foreach net $nets {
        disconnect_bd_intf_net $net $pin
    }
}

proc evip_bd_delete_cell {cell_name} {
    set cell [get_bd_cells -quiet $cell_name]
    if {[llength $cell] == 0} { return }
    foreach pin [get_bd_pins -quiet -of_objects $cell] {
        set nets [get_bd_nets -quiet -of_objects $pin]
        foreach net $nets {
            disconnect_bd_net $net $pin
        }
    }
    foreach pin [get_bd_intf_pins -quiet -of_objects $cell] {
        set nets [get_bd_intf_nets -quiet -of_objects $pin]
        foreach net $nets {
            disconnect_bd_intf_net $net $pin
        }
    }
    delete_bd_objs $cell
}

proc evip_bd_delete_ports {port_names} {
    foreach port_name $port_names {
        set port [get_bd_ports -quiet $port_name]
        if {[llength $port] > 0} {
            set nets [get_bd_nets -quiet -of_objects $port]
            foreach net $nets {
                disconnect_bd_net $net $port
            }
            delete_bd_objs $port
        }
    }
}

proc evip_validate_tmds_interface_repo {evip_ip_repo} {
    set interface_dir [file join $evip_ip_repo if tmds_v1_0]
    foreach filename {tmds.xml tmds_rtl.xml} {
        set definition [file join $interface_dir $filename]
        if {![file isfile $definition]} {
            error "EmbeddedVideoIP TMDS interface definition is missing: $definition"
        }
    }
}

# Expose the codec's serial playback data and clocks as one standard I2S bus.
# MCLK and MUTEN remain standalone board signals.
proc gba_bd_configure_i2s_tx {} {
    set i2s_pin [get_bd_intf_pins -quiet gba_pl_top_0/i2s_tx]
    if {[llength $i2s_pin] != 1} {
        error "GBA I2S TX module-reference interface is missing; the RTL interface was not inferred."
    }

    set i2s_port [get_bd_intf_ports -quiet i2s_tx]
    if {[llength $i2s_port] == 0} {
        # Remove the old scalar exports only on first conversion. Once the bus
        # exists, its physical members are part of the interface and must remain.
        foreach signal_name {ac_bclk ac_pblrc ac_pbdat} {
            set scalar_port [get_bd_ports -quiet $signal_name]
            set scalar_pin [get_bd_pins -quiet gba_pl_top_0/$signal_name]
            set stale_nets {}
            if {[llength $scalar_port] > 0} {
                set stale_nets [concat $stale_nets [get_bd_nets -quiet -of_objects $scalar_port]]
            }
            if {[llength $scalar_pin] > 0} {
                set stale_nets [concat $stale_nets [get_bd_nets -quiet -of_objects $scalar_pin]]
            }
            foreach net [lsort -unique $stale_nets] {
                foreach port [get_bd_ports -quiet -of_objects $net] {
                    disconnect_bd_net $net $port
                }
                foreach pin [get_bd_pins -quiet -of_objects $net] {
                    disconnect_bd_net $net $pin
                }
                delete_bd_objs $net
            }
            if {[llength $scalar_port] > 0} { delete_bd_objs $scalar_port }
        }

        make_bd_intf_pins_external $i2s_pin
        set created_ports [get_bd_intf_ports -quiet i2s_tx*]
        if {[llength $created_ports] != 1} {
            error "Vivado did not create exactly one external I2S TX interface."
        }
        set_property name i2s_tx [lindex $created_ports 0]
        set i2s_port [get_bd_intf_ports -quiet i2s_tx]
    }
    if {[llength $i2s_port] != 1} {
        error "Expected exactly one external i2s_tx interface."
    }

    foreach obj [list $i2s_pin $i2s_port] {
        foreach net [get_bd_intf_nets -quiet -of_objects $obj] {
            disconnect_bd_intf_net $net $obj
        }
    }
    connect_bd_intf_net $i2s_pin $i2s_port

    set nets [get_bd_intf_nets -quiet -of_objects $i2s_pin]
    if {[llength $nets] != 1 ||
        [lsearch -exact [get_bd_intf_ports -quiet -of_objects [lindex $nets 0]] $i2s_port] < 0} {
        error "The GBA I2S TX interface is not connected to its external BD port."
    }
}

proc evip_bd_set_composite_config {cell} {
    global evip_max_input_width evip_max_input_height
    global evip_max_scaler_width evip_max_scaler_height
    global evip_enable_bram_source evip_enable_hls_source evip_enable_vdma_source
    global evip_source_select_mode evip_fixed_source
    global evip_format_select_mode evip_fixed_format evip_enable_scaler
    global evip_line_buffer_implementation evip_enable_hdmi_audio

    set_property -dict [list \
        CONFIG.MAX_INPUT_WIDTH $evip_max_input_width \
        CONFIG.MAX_INPUT_HEIGHT $evip_max_input_height \
        CONFIG.BRAM_ADDR_WIDTH {18} \
        CONFIG.AXI_ADDR_WIDTH {6} \
        CONFIG.ENABLE_BRAM_SOURCE $evip_enable_bram_source \
        CONFIG.ENABLE_HLS_SOURCE $evip_enable_hls_source \
        CONFIG.ENABLE_VDMA_SOURCE $evip_enable_vdma_source \
        CONFIG.SOURCE_SELECT_MODE $evip_source_select_mode \
        CONFIG.FIXED_SOURCE $evip_fixed_source \
        CONFIG.FORMAT_SELECT_MODE $evip_format_select_mode \
        CONFIG.FIXED_FORMAT $evip_fixed_format \
        CONFIG.MAX_SCALER_INPUT_WIDTH $evip_max_scaler_width \
        CONFIG.MAX_SCALER_INPUT_HEIGHT $evip_max_scaler_height \
        CONFIG.ENABLE_SCALER $evip_enable_scaler \
        CONFIG.LINE_BUFFER_IMPLEMENTATION $evip_line_buffer_implementation \
        CONFIG.ENABLE_HDMI_AUDIO $evip_enable_hdmi_audio \
    ] $cell
}
proc evip_bd_configure_composite {} {
    global evip_vlnv
    global evip_max_input_width evip_max_input_height
    global evip_max_scaler_width evip_max_scaler_height
    global evip_enable_bram_source evip_enable_hls_source evip_enable_vdma_source
    global evip_source_select_mode evip_fixed_source
    global evip_format_select_mode evip_fixed_format evip_enable_scaler
    global evip_line_buffer_implementation evip_enable_hdmi_audio
    global evip_control_offset

    # A regenerated seed BD already contains the current composite IP and its
    # validated AXI address path. Keep that hierarchy intact on later rebuilds.
    set existing_pipeline [get_bd_cells -quiet hdmi_video_pipeline]
    set existing_clock [get_bd_cells -quiet hdmi_video_ctrl_clock]
    if {[llength $existing_pipeline] == 1 && [llength $existing_clock] == 1 &&
        [get_property VLNV $existing_pipeline] eq $evip_vlnv} {
        # The consumer may import a newer coreRevision under the same VLNV.
        # Upgrade this existing BD cell before writing parameters; otherwise
        # Vivado rejects set_property because the cell remains revision-locked.
        set evip_upgraded_cells [upgrade_bd_cells $existing_pipeline]
        set existing_pipeline [get_bd_cells -quiet hdmi_video_pipeline]
        if {[llength $existing_pipeline] != 1} {
            error "EmbeddedVideoIP cell disappeared during upgrade_bd_cells."
        }
        if {[get_property VLNV $existing_pipeline] ne $evip_vlnv} {
            error "EmbeddedVideoIP BD cell VLNV changed during core upgrade."
        }
        evip_bd_set_composite_config $existing_pipeline
        evip_bd_configure_150m_video
        return
    }

    # 先断开旧控制通道，再删除旧视频输出、VTC、Clock Wizard 和 TMDS 发送器。
    foreach path {
        axi_ctrl_ic/M03_AXI
        hdmi_video_ctrl_clock/S_AXI
        hdmi_video_ctrl_clock/M_AXI
        hdmi_vdma/M_AXIS_MM2S
        gba_pl_top_0/audio_pcm
    } {
        evip_bd_disconnect_intf $path
    }

    # The seed BD may already contain the previous composite IP address map.
    # Remove it before replacing the hierarchy so the new AXI path is rebuilt.
    set old_video_seg [get_bd_addr_segs -quiet -filter {NAME =~ *SEG_hdmi_video_pipeline_reg0*}]
    if {[llength $old_video_seg] > 0} {
        delete_bd_objs $old_video_seg
    }
    foreach cell_name {
        hdmi_video_pipeline hdmi_video_ctrl_clock hdmi_vid_out hdmi_tc
        hdmi_clk_gen hdmi_dvi_enc hdmi_vid_reset_inv rst_serial rst_pixel
        hdmi_rgb_pack hdmi_video_unused_zero32 hdmi_video_unused_zero1
    } {
        evip_bd_delete_cell $cell_name
    }
    foreach cell [get_bd_cells -quiet -filter {NAME =~ hdmi_rgb_pack_*}] {
        evip_bd_delete_cell [get_property NAME $cell]
    }

    # 保留现有 TMDS 外部接口，断开旧发送器的连接；稍后接入 EmbeddedVideoIP。
    set tmds_port [get_bd_intf_ports -quiet tmds_tx]
    if {[llength $tmds_port] > 0} {
        foreach net [get_bd_intf_nets -quiet -of_objects $tmds_port] {
            disconnect_bd_intf_net $net $tmds_port
        }
        # Recreate the external bus from the current project-owned VLNV so
        # Vivado does not retain the interface type from the previous IP seed.
        delete_bd_objs $tmds_port
    }

    create_bd_cell -type ip -vlnv $evip_vlnv hdmi_video_pipeline
    evip_bd_set_composite_config [get_bd_cells hdmi_video_pipeline]

    # GBA不使用BRAM/HLS输入，常量只用于连接被静态裁剪的输入端口。
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 hdmi_video_unused_zero32
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 hdmi_video_unused_zero1
    set_property -dict [list CONFIG.CONST_WIDTH {32} CONFIG.CONST_VAL {0}] \
        [get_bd_cells hdmi_video_unused_zero32]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] \
        [get_bd_cells hdmi_video_unused_zero1]
    connect_bd_net [get_bd_pins hdmi_video_unused_zero32/dout] \
        [get_bd_pins hdmi_video_pipeline/bram_dout] \
        [get_bd_pins hdmi_video_pipeline/s_axis_hls_tdata]
    connect_bd_net [get_bd_pins hdmi_video_unused_zero1/dout] \
        [get_bd_pins hdmi_video_pipeline/s_axis_hls_tvalid] \
        [get_bd_pins hdmi_video_pipeline/s_axis_hls_tuser] \
        [get_bd_pins hdmi_video_pipeline/s_axis_hls_tlast]

    # PS的50 MHz控制AXI经Clock Converter进入100 MHz IP控制域。
    set_property CONFIG.NUM_MI {4} [get_bd_cells axi_ctrl_ic]
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 hdmi_video_ctrl_clock
    set_property -dict [list \
        CONFIG.PROTOCOL {AXI4LITE} \
        CONFIG.ADDR_WIDTH {32} \
        CONFIG.DATA_WIDTH {32} \
        CONFIG.ACLK_ASYNC {1} \
    ] [get_bd_cells hdmi_video_ctrl_clock]
    connect_bd_intf_net [get_bd_intf_pins axi_ctrl_ic/M03_AXI] \
        [get_bd_intf_pins hdmi_video_ctrl_clock/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins hdmi_video_ctrl_clock/M_AXI] \
        [get_bd_intf_pins hdmi_video_pipeline/s_axi]
    connect_bd_intf_net [get_bd_intf_pins hdmi_vdma/M_AXIS_MM2S] \
        [get_bd_intf_pins hdmi_video_pipeline/s_axis_vdma]
    connect_bd_intf_net [get_bd_intf_pins gba_pl_top_0/audio_pcm] \
        [get_bd_intf_pins hdmi_video_pipeline/s_axis_audio_pcm]

    connect_bd_net [get_bd_pins ps_core/FCLK_CLK0] \
        [get_bd_pins axi_ctrl_ic/M03_ACLK] \
        [get_bd_pins hdmi_video_ctrl_clock/s_axi_aclk] \
        [get_bd_pins hdmi_video_pipeline/hdmi_ref_clk]
    connect_bd_net [get_bd_pins rst_50M/peripheral_aresetn] \
        [get_bd_pins axi_ctrl_ic/M03_ARESETN] \
        [get_bd_pins hdmi_video_ctrl_clock/s_axi_aresetn]
    connect_bd_net [get_bd_pins ps_core/FCLK_CLK1] \
        [get_bd_pins hdmi_video_pipeline/aclk] \
        [get_bd_pins hdmi_video_ctrl_clock/m_axi_aclk]
    connect_bd_net [get_bd_pins rst_100M/peripheral_aresetn] \
        [get_bd_pins hdmi_video_pipeline/aresetn] \
        [get_bd_pins hdmi_video_ctrl_clock/m_axi_aresetn]
    connect_bd_net [get_bd_pins gba_pl_top_0/audio_pcm_clk] \
        [get_bd_pins hdmi_video_pipeline/audio_pcm_clk]

    # HDMI DDC/HPD remains consumer PS management. Connect the TMDS bus as one
    # interface while retaining its existing physical lane port names in XDC.
    set tmds_pin [get_bd_intf_pins -quiet hdmi_video_pipeline/tmds_tx]
    if {[llength $tmds_pin] != 1} {
        error "EmbeddedVideoIP tmds_tx interface is missing from its packaged component."
    }
    set tmds_port [get_bd_intf_ports -quiet tmds_tx]
    if {[llength $tmds_port] == 0} {
        make_bd_intf_pins_external $tmds_pin
        set created_ports [get_bd_intf_ports -quiet tmds_tx*]
        if {[llength $created_ports] != 1} {
            error "Vivado did not create exactly one external TMDS interface."
        }
        set_property name tmds_tx [lindex $created_ports 0]
        set tmds_port [get_bd_intf_ports -quiet tmds_tx]
    }
    if {[llength $tmds_port] != 1} {
        error "Expected exactly one external tmds_tx interface."
    }
    foreach obj [list $tmds_pin $tmds_port] {
        foreach net [get_bd_intf_nets -quiet -of_objects $obj] {
            disconnect_bd_intf_net $net $obj
        }
    }
    connect_bd_intf_net $tmds_pin $tmds_port
    set tmds_nets [get_bd_intf_nets -quiet -of_objects $tmds_pin]
    if {[llength $tmds_nets] != 1 ||
        [lsearch -exact [get_bd_intf_ports -quiet -of_objects [lindex $tmds_nets 0]] $tmds_port] < 0} {
        error "EmbeddedVideoIP TMDS interface is not connected to the external BD port."
    }

    set video_core_seg [get_bd_addr_segs -quiet hdmi_video_pipeline/s_axi/reg0]
    set video_ps_seg [get_bd_addr_segs -quiet -filter \
        {NAME == "SEG_hdmi_video_pipeline_reg0"}]
    if {[llength $video_core_seg] == 0} {
        error "EmbeddedVideoIP s_axi/reg0 address segment is missing."
    }
    if {[llength $video_ps_seg] == 0} {
        create_bd_addr_seg -range 4K -offset $evip_control_offset \
            [get_bd_addr_spaces ps_core/Data] $video_core_seg \
            SEG_hdmi_video_pipeline_reg0
    } else {
        set_property offset $evip_control_offset $video_ps_seg
        set_property range 4K $video_ps_seg
    }

    evip_bd_configure_150m_video

    # 删除旧视频链路拆除后遗留的无驱动标量网和悬空AXI接口网。
    foreach net_name {
        hdmi_clk_gen_clk_out1 hdmi_clk_gen_clk_out2 hdmi_clk_gen_locked
        hdmi_vid_out_vtg_ce hdmi_vid_reset_inv_Res1
        hdmi_video_unused_zero1_dout1 hdmi_video_unused_zero32_dout1
        rst_pixel_peripheral_aresetn rst_pixel_peripheral_reset
        rst_serial_peripheral_aresetn
    } {
        set net [get_bd_nets -quiet $net_name]
        if {[llength $net] > 0} { delete_bd_objs $net }
    }
    foreach net_name {
        axi_ctrl_ic_M03_AXI hdmi_dvi_enc_TMDS hdmi_tc_vtiming_out
        hdmi_vdma_M_AXIS_MM2S hdmi_vid_out_vid_io_out
        hdmi_video_ctrl_clock_M_AXI1 hdmi_video_pipeline_M_AXIS_VIDEO_1
    } {
        set net [get_bd_intf_nets -quiet $net_name]
        if {[llength $net] > 0} { delete_bd_objs $net }
    }
}
# Pixel throughput for 1080p60 is 124.416 Mpixel/s. Keep the GBA domain at 100 MHz.
proc evip_bd_configure_150m_video {} {
    set_property -dict [list CONFIG.PCW_EN_CLK2_PORT {1} CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {150}] [get_bd_cells ps_core]
    if {[llength [get_bd_cells -quiet rst_video_150M]] == 0} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_video_150M
    }
    # PS FCLKs are available with the PS reset release; no external MMCM lock.
    if {[llength [get_bd_cells -quiet ps_fclk_locked]] == 0} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 ps_fclk_locked
        set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells ps_fclk_locked]
    }
    foreach pin {rst_100M/dcm_locked rst_video_150M/dcm_locked} {
        evip_bd_disconnect_pin $pin
        connect_bd_net [get_bd_pins ps_fclk_locked/dout] [get_bd_pins $pin]
    }
    evip_bd_disconnect_pin rst_video_150M/ext_reset_in
    connect_bd_net [get_bd_pins ps_core/FCLK_RESET0_N] [get_bd_pins rst_video_150M/ext_reset_in]
    foreach pin {hdmi_video_pipeline/aclk hdmi_video_ctrl_clock/m_axi_aclk hdmi_vdma/m_axi_mm2s_aclk hdmi_vdma/m_axis_mm2s_aclk hdmi_ddr_pc/aclk ps_core/S_AXI_HP3_ACLK rst_video_150M/slowest_sync_clk} {
        evip_bd_disconnect_pin $pin
        connect_bd_net [get_bd_pins ps_core/FCLK_CLK2] [get_bd_pins $pin]
    }
    foreach pin {hdmi_video_pipeline/aresetn hdmi_video_ctrl_clock/m_axi_aresetn hdmi_ddr_pc/aresetn} {
        evip_bd_disconnect_pin $pin
        connect_bd_net [get_bd_pins rst_video_150M/peripheral_aresetn] [get_bd_pins $pin]
    }
}
# Zybo profile keeps EmbeddedVideoIP's scoped CDC exceptions active. The board
# XDC groups only PS root clocks; the IP XDC constrains Gray-bus CDC paths.
proc evip_bd_apply_z7_clock_constraints {} {
    set ip_cdc_xdc [get_files -all -quiet *embedded_video_ip_clocks.xdc]
    if {[llength $ip_cdc_xdc] != 1} {
        error {Zybo profile must locate exactly one EmbeddedVideoIP CDC XDC.}
    }
    set_property USED_IN_synthesis true $ip_cdc_xdc
    set_property USED_IN_implementation true $ip_cdc_xdc

    # The VGA Clock Wizard subcore XDC is redundant with the canonical scoped
    # EmbeddedVideoIP clock model. The HD PLL is RTL (not a Clock Wizard IP).
    set clk_wiz_vga_xdc [get_files -all -quiet *embedded_video_ip_video_out_clk_wiz_vga_0.xdc]
    foreach redundant_clock_xdc $clk_wiz_vga_xdc {
        set_property USED_IN_synthesis false $redundant_clock_xdc
        set_property USED_IN_implementation false $redundant_clock_xdc
    }
    set legacy_hd_clock_xdc [get_files -all -quiet *embedded_video_ip_video_out_clk_wiz_hd_0.xdc]
    if {[llength $legacy_hd_clock_xdc] > 0} {
        error {Stale HD Clock Wizard XDC remains after canonical package import.}
    }

    set board_xdc [get_files -quiet *zybo_z7_20.xdc]
    if {[llength $board_xdc] != 1} {
        error {Zybo profile must locate exactly one board XDC.}
    }
    set_property PROCESSING_ORDER LATE $board_xdc
}
