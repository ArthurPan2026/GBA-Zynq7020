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

proc evip_bd_configure_composite {} {
    global evip_vlnv
    global evip_max_input_width evip_max_input_height
    global evip_max_scaler_width evip_max_scaler_height
    global evip_enable_bram_source evip_enable_hls_source evip_enable_vdma_source
    global evip_source_select_mode evip_fixed_source
    global evip_format_select_mode evip_fixed_format evip_enable_scaler
    global evip_line_buffer_implementation evip_enable_hdmi_audio
    global evip_control_offset

    # 先断开旧控制通道，再删除独立video-out/VTC/Clock Wizard/rgb2dvi。
    foreach path {
        axi_ctrl_ic/M03_AXI
        hdmi_video_ctrl_clock/S_AXI
        hdmi_video_ctrl_clock/M_AXI
        hdmi_vdma/M_AXIS_MM2S
        gba_pl_top_0/audio_pcm
    } {
        evip_bd_disconnect_intf $path
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

    # TMDS差分线改由复合IP的四组标量输出驱动。
    # 保留已有TMDS接口端口和其物理成员，仅断开旧发送器的内部连接。
    # 约束文件使用的标量成员名不变，由复合IP直接驱动这些成员。
    set old_tmds [get_bd_intf_ports -quiet TMDS]
    if {[llength $old_tmds] > 0} {
        foreach net [get_bd_intf_nets -quiet -of_objects $old_tmds] {
            disconnect_bd_intf_net $net $old_tmds
        }
    }

    create_bd_cell -type ip -vlnv $evip_vlnv hdmi_video_pipeline
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
    ] [get_bd_cells hdmi_video_pipeline]

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

    # HDMI DDC/HPDはconsumerのPS側で直接管理する。EVIPの外にはTMDSだけ出す。
    foreach {port_name direction width} {
        tmds_tx_clk_p O 1
        tmds_tx_clk_n O 1
        tmds_tx_data_p O 3
        tmds_tx_data_n O 3
    } {
        set external_port [get_bd_ports -quiet $port_name]
        if {[llength $external_port] == 0} {
            if {$width == 1} {
                create_bd_port -dir $direction $port_name
            } else {
                create_bd_port -dir $direction -from [expr {$width - 1}] -to 0 $port_name
            }
            set external_port [get_bd_ports $port_name]
        }
        connect_bd_net [get_bd_pins hdmi_video_pipeline/$port_name] $external_port
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
# Zybo消费profile：关闭通用的AXI/PCM/HDMI三组异步XDC，由板级FCLK0/FCLK1约束统一描述实际时钟关系。
proc evip_bd_apply_z7_clock_constraints {} {
    set ip_cdc_xdc [get_files -all -quiet *embedded_video_ip_clocks.xdc]
    if {[llength $ip_cdc_xdc] != 1} {
        error {Zybo profile must locate exactly one EmbeddedVideoIP CDC XDC.}
    }
    set_property USED_IN_synthesis false $ip_cdc_xdc
    set_property USED_IN_implementation false $ip_cdc_xdc

    # 该scoped XDC会在clk_wiz/inst/clk_in1重复创建主时钟，覆盖PS FCLK0根时钟属性。
    # OOC XDC继续用于IP自身综合；消费工程只使用PS导出的根时钟及其MMCM派生时钟。
    set clk_wiz_xdc [get_files -all -quiet *embedded_video_ip_video_out_clk_wiz_0.xdc]
    if {[llength $clk_wiz_xdc] != 1} {
        error {Zybo profile must locate exactly one scoped EmbeddedVideoIP Clock Wizard XDC.}
    }
    set_property USED_IN_synthesis false $clk_wiz_xdc
    set_property USED_IN_implementation false $clk_wiz_xdc

    set board_xdc [get_files -quiet *zybo_z7_20.xdc]
    if {[llength $board_xdc] != 1} {
        error {Zybo profile must locate exactly one board XDC.}
    }
    set_property PROCESSING_ORDER LATE $board_xdc
}
