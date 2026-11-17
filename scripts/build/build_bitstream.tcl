#=============================================================================
# build_bitstream.tcl — single-pass project build → bitstream → XSA export.
# Skips synthesis / implementation when inputs haven't changed.
#=============================================================================
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
if {[info exists ::env(ZYNQ_GBA_REPO_ROOT)] && $::env(ZYNQ_GBA_REPO_ROOT) ne {}} {
    set repo_root [file normalize $::env(ZYNQ_GBA_REPO_ROOT)]
}
set out_root [file normalize [file join $repo_root out vivado]]
if {[info exists ::env(ZYNQ_GBA_OUT_DIR)] && $::env(ZYNQ_GBA_OUT_DIR) ne {}} {
    set out_root [file normalize $::env(ZYNQ_GBA_OUT_DIR)]
}
file mkdir $out_root

set project_name  "Zynq-GBA_MisTer-Vivado"
set bd_name       "zynq_gba_system"
set target_part   "xc7z020clg400-1"
set synth_strategy {Vivado Synthesis Defaults}
set impl_strategy  Performance_ExplorePostRoutePhysOpt
set bd_file       [file join $repo_root src bd ${bd_name} ${bd_name}.bd]
set constr_file   [file join $repo_root src constraints zybo_z7_20.xdc]
set xsa_file      [file join $out_root zynq_gba_system_wrapper.xsa]
set project_file  [file join $out_root Zynq-GBA_MisTer-Vivado.xpr]
set cache_script  [file join $script_dir incremental_build_cache.py]
source [file join $script_dir embedded_video_ip_consumer.tcl]

if {[info exists ::env(EMBEDDED_VIDEO_IP_REPO)] &&
    ($::env(EMBEDDED_VIDEO_IP_REPO) ne "")} {
    set evip_root [file normalize $::env(EMBEDDED_VIDEO_IP_REPO)]
} else {
    set evip_root [file normalize [file join $repo_root .. EmbeddedVideoIP]]
}
set evip_version_file [file join $evip_root VERSION]
set evip_ip_repo [file join $evip_root ip_repo]
if {![file isfile $evip_version_file] || ![file isdirectory $evip_ip_repo]} {
    error "EmbeddedVideoIP dependency is missing: $evip_root"
}
set evip_fd [open $evip_version_file r]
set evip_version [string trim [read $evip_fd]]
close $evip_fd
if {$evip_version ne $evip_expected_version} {
    error "GBA dependency expects EmbeddedVideoIP $evip_expected_version; found $evip_version"
}
set evip_git_commit [string trim [exec git -C $evip_root rev-parse HEAD]]
if {$evip_git_commit ne $evip_expected_commit} {
    error "GBA dependency expects EmbeddedVideoIP commit $evip_expected_commit; found $evip_git_commit"
}
set evip_git_status [string trim [exec git -C $evip_root status --porcelain]]
if {$evip_git_status ne ""} {
    error "EmbeddedVideoIP working tree is dirty: $evip_root"
}
if {[info exists ::env(DIGILENT_VIVADO_LIBRARY)] &&
    ($::env(DIGILENT_VIVADO_LIBRARY) ne "")} {
    set digilent_ip_root [file normalize $::env(DIGILENT_VIVADO_LIBRARY)]
} elseif {[file isdirectory D:/Tools/vivado-library-master]} {
    set digilent_ip_root [file normalize D:/Tools/vivado-library-master]
} else {
    set digilent_ip_root [file normalize [file join $repo_root third_party digilent-vivado-library]]
}
if {![file isdirectory [file join $digilent_ip_root ip rgb2dvi]] ||
    ![file isdirectory [file join $digilent_ip_root if tmds_v1_0]]} {
    error "Digilent rgb2dvi dependency is missing: $digilent_ip_root"
}
set digilent_lock_file [file join $digilent_ip_root dependency-lock.json]
if {![file isfile $digilent_lock_file]} {
    error "Digilent dependency lock is missing: $digilent_lock_file"
}
set digilent_fd [open $digilent_lock_file r]
set digilent_lock_text [read $digilent_fd]
close $digilent_fd
if {![regexp {"upstream_commit"[[:space:]]*:[[:space:]]*"([0-9a-f]{40})"} $digilent_lock_text -> digilent_commit]} {
    error "Digilent dependency lock has no valid upstream_commit: $digilent_lock_file"
}
if {$digilent_commit ne $digilent_library_expected_commit} {
    error "GBA consumer expects Digilent library commit $digilent_library_expected_commit; found $digilent_commit"
}

source [file join $script_dir bd_ip_maintenance.tcl]
source [file join $script_dir embedded_video_ip_bd.tcl]

#-----------------------------------------------------------------------------
# Utilities
#-----------------------------------------------------------------------------
proc add_globbed_files {pattern} {
    set files [glob -nocomplain $pattern]
    if {[llength $files] > 0} { add_files -norecurse $files }
}

proc log_step {msg} { puts "--- $msg ---" }

proc resolve_python {} {
    if {[info exists ::env(ZYNQ_GBA_PYTHON)] && $::env(ZYNQ_GBA_PYTHON) ne {} && [file executable $::env(ZYNQ_GBA_PYTHON)]} {
        return [list $::env(ZYNQ_GBA_PYTHON)]
    }
    foreach candidate {python3.15 python3 python py} {
        set executable [auto_execok $candidate]
        if {$executable ne ""} { return $executable }
    }
    error "Python 3 is required by the content-addressed build cache."
}

proc run_cache_tool {python_cmd cache_script args} {
    set had_pythonhome [info exists ::env(PYTHONHOME)]
    set had_pythonpath [info exists ::env(PYTHONPATH)]
    if {$had_pythonhome} { set saved_pythonhome $::env(PYTHONHOME) }
    if {$had_pythonpath} { set saved_pythonpath $::env(PYTHONPATH) }
    unset -nocomplain ::env(PYTHONHOME) ::env(PYTHONPATH)
    set failed [catch {
        exec {*}$python_cmd $cache_script {*}$args
    } result options]
    if {$had_pythonhome} { set ::env(PYTHONHOME) $saved_pythonhome }
    if {$had_pythonpath} { set ::env(PYTHONPATH) $saved_pythonpath }
    if {$failed} {
        return -options $options $result
    }
    return [string trim $result]
}

proc impl_gate {repo_root python_cmd cache_script} {
    set report_dir [file join $repo_root out vivado reports]
    file mkdir $report_dir
    set timing_report [file join $report_dir timing_summary.rpt]
    set drc_report [file join $report_dir drc.rpt]

    open_run impl_1
    report_timing_summary -delay_type min_max -file $timing_report
    report_drc -file $drc_report
    set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
    set critical_warnings [llength [get_drc_violations -quiet -filter {SEVERITY == "Critical Warning"}]]
    close_design

    set result [run_cache_tool $python_cmd $cache_script gate \
        --timing-report $timing_report \
        --drc-errors $drc_errors \
        --critical-warnings $critical_warnings]
    set fields [split $result "\t"]
    if {[llength $fields] != 7} {
        error "Build QoR gate returned malformed data: $result"
    }
    set gate_file [open [file join $report_dir qor_gate.tsv] w]
    puts $gate_file "passed=[lindex $fields 0]"
    puts $gate_file "wns_ns=[lindex $fields 1]"
    puts $gate_file "tns_ns=[lindex $fields 2]"
    puts $gate_file "whs_ns=[lindex $fields 3]"
    puts $gate_file "ths_ns=[lindex $fields 4]"
    puts $gate_file "drc_errors=[lindex $fields 5]"
    puts $gate_file "critical_warnings=[lindex $fields 6]"
    close $gate_file
    return $fields
}

proc impl_run_succeeded {run} {
    set status [string tolower [get_property STATUS $run]]
    return [expr {[string match "*route_design finished*" $status] ||
                  [string match "*write_bitstream finished*" $status] ||
                  [string match "*write_bitstream complete*" $status]}]
}

proc launch_impl_and_gate {repo_root python_cmd cache_script use_incremental} {
    set run [get_runs impl_1]
    if {$use_incremental} {
        set_property AUTO_INCREMENTAL_CHECKPOINT 0 $run
        set_property INCREMENTAL_CHECKPOINT $::incremental_dcp $run
        log_step "Implementation uses recent compatible DCP: $::incremental_dcp"
    } else {
        catch {reset_property INCREMENTAL_CHECKPOINT $run}
        catch {set_property AUTO_INCREMENTAL_CHECKPOINT 0 $run}
        log_step "Implementation uses clean placement and routing"
    }

    set launch_error [catch {
        launch_runs impl_1 -to_step write_bitstream -jobs 8
        wait_on_run impl_1
    } launch_message]
    if {!$launch_error && [impl_run_succeeded $run]} {
        set gate_error [catch {impl_gate $repo_root $python_cmd $cache_script} gate_result]
        if {!$gate_error && [lindex $gate_result 0] eq "1"} {
            return $gate_result
        }
        if {$gate_error} {
            log_step "Implementation QoR/DRC check could not be read: $gate_result"
        } else {
            log_step "Implementation QoR/DRC gate failed: $gate_result"
        }
    } elseif {$launch_error} {
        log_step "Implementation run failed: $launch_message"
    } else {
        log_step "Implementation run did not finish successfully: [get_property STATUS $run]"
    }

    if {$use_incremental} {
        log_step "Retry implementation from a clean placement and routing run"
        catch {reset_property INCREMENTAL_CHECKPOINT $run}
        catch {set_property AUTO_INCREMENTAL_CHECKPOINT 0 $run}
        reset_run impl_1
        set launch_error [catch {
            launch_runs impl_1 -to_step write_bitstream -jobs 8
            wait_on_run impl_1
        } launch_message]
        if {!$launch_error && [impl_run_succeeded $run]} {
            set gate_error [catch {impl_gate $repo_root $python_cmd $cache_script} gate_result]
            if {!$gate_error && [lindex $gate_result 0] eq "1"} {
                return $gate_result
            }
            if {$gate_error} {
                error "Clean implementation QoR/DRC check failed: $gate_result"
            }
            error "Clean implementation QoR/DRC gate failed: $gate_result"
        }
        error "Clean implementation retry failed: $launch_message"
    }
    error "Clean implementation failed the status or QoR/DRC gate."
}

#-----------------------------------------------------------------------------
# Stage 1 — Project
#-----------------------------------------------------------------------------
log_step "Stage 1: project"

set python_cmd [resolve_python]
set incremental_dcp {}
if {[info exists ::env(ZYNQ_GBA_INCREMENTAL_DCP)] &&
    $::env(ZYNQ_GBA_INCREMENTAL_DCP) ne {} &&
    [file isfile $::env(ZYNQ_GBA_INCREMENTAL_DCP)]} {
    set incremental_dcp [file normalize $::env(ZYNQ_GBA_INCREMENTAL_DCP)]
    log_step "Implementation may reuse verified DCP: $incremental_dcp"
} else {
    log_step "Implementation starts without an incremental DCP"
}
set need_full_rebuild 1
if {[info exists ::env(ZYNQ_GBA_REBUILD_PROJECT)] &&
    $::env(ZYNQ_GBA_REBUILD_PROJECT) eq 0 && [file isfile $project_file]} {
    set need_full_rebuild 0
}
if {$need_full_rebuild} {
    log_step "Flow requested a full project refresh"
}
if {$need_full_rebuild} {
    log_step "Stage 1a: full project rebuild"

    create_project -force $project_name $out_root -part $target_part
    set_property board_part digilentinc.com:zybo-z7-20:part0:1.2 [current_project]
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]
    set_property default_lib xil_defaultlib [current_project]
    set_property source_mgmt_mode All [current_project]
    set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY} [current_project]
    set_property strategy $synth_strategy [get_runs synth_1]
    set_property strategy $impl_strategy [get_runs impl_1]
    set_msg_config -id {BD 41-926} -suppress

    set ip_repos [list $evip_ip_repo $digilent_ip_root]
    set_property ip_repo_paths $ip_repos [current_project]
    update_ip_catalog

    # BD snapshot + deploy

    set local_bd_dir     [file join $out_root Zynq-GBA_MisTer-Vivado.srcs sources_1 bd $bd_name]
    set local_bd_file    [file join $local_bd_dir ${bd_name}.bd]
    set local_gen_bd_dir [file join $out_root Zynq-GBA_MisTer-Vivado.gen sources_1 bd $bd_name]
    set src_ip_dir       [file join $repo_root src bd $bd_name ip]
    set src_shared_dir   [file join $repo_root src bd $bd_name ipshared]

    if {[file exists $local_bd_dir]} { file delete -force $local_bd_dir }
    file mkdir $local_bd_dir
    file mkdir $local_gen_bd_dir
    file copy -force $bd_file $local_bd_file
    if {[file isdirectory $src_ip_dir]} {
        file copy -force $src_ip_dir [file join $local_bd_dir ip]
    }
    if {[file isdirectory $src_shared_dir]} {
        file copy -force $src_shared_dir [file join $local_gen_bd_dir ipshared]
    }
    normalize_xci_shareddir [file join $local_bd_dir ip]

    # Add sources
    add_files -norecurse $local_bd_file
    add_globbed_files [file join $repo_root src rtl top *.v]
    add_globbed_files [file join $repo_root src rtl common *.v]
    add_globbed_files [file join $repo_root src rtl common *.sv]
    add_globbed_files [file join $repo_root src rtl common *.vh]
    add_globbed_files [file join $repo_root src rtl common *.mem]
    add_globbed_files [file join $repo_root src rtl core gba_mister rtl *.v]
    add_globbed_files [file join $repo_root src rtl core gba_mister rtl *.sv]
    add_globbed_files [file join $repo_root src rtl core gba_mister rtl *.vhd]
    add_globbed_files [file join $repo_root src rtl core gba_mister rtl *.mem]
    add_files -fileset constrs_1 -norecurse $constr_file

    foreach relpath [list \
        src/rtl/core/gba_mister/rtl/SyncFifo.vhd \
        src/rtl/core/gba_mister/rtl/SyncRam.vhd \
        src/rtl/core/gba_mister/rtl/SyncRamDual.vhd \
        src/rtl/core/gba_mister/rtl/SyncRamDualByteEnable.vhd \
        src/rtl/core/gba_mister/rtl/SyncRamDualNotPow2.vhd \
    ] {
        set f [get_files -quiet [file join $repo_root $relpath]]
        if {[llength $f] > 0} { set_property library mem $f }
    }

    # --- BD assembly (proven logic from rebuild_project.tcl, unchanged) ---
    open_bd_design $local_bd_file

    foreach legacy_port_name [list audio_l audio_r ch1_req ch2_req ch3_req ch4_req] {
        set legacy_port [get_bd_ports -quiet $legacy_port_name]
        if {[llength $legacy_port] > 0} {
            set legacy_net [get_bd_nets -quiet -of_objects $legacy_port]
            if {[llength $legacy_net] > 0} { disconnect_bd_net $legacy_net $legacy_port }
            delete_bd_objs $legacy_port
        }
    }

    if {[llength [get_bd_cells -quiet fb_cap_bram_ctrl]] == 0} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 fb_cap_bram_ctrl
    }
    set_property -dict [list CONFIG.DATA_WIDTH {32} CONFIG.SINGLE_PORT_BRAM {1}] \
        [get_bd_cells fb_cap_bram_ctrl]
    foreach pin_path [list axi_ctrl_ic/M02_AXI fb_cap_bram_ctrl/S_AXI \
                           fb_cap_bram_ctrl/BRAM_PORTA gba_pl_top_0/fb_cap_bram] {
        set pin [get_bd_intf_pins -quiet $pin_path]
        if {[llength $pin] > 0} {
            set net [get_bd_intf_nets -quiet -of_objects $pin]
            if {[llength $net] > 0} { disconnect_bd_intf_net $net $pin }
        }
    }
    foreach net_name [list axi_ctrl_ic_M02_AXI fb_cap_bram_ctrl_BRAM_PORTA \
                           axi_ctrl_ic_M02_AXI1 fb_cap_bram_ctrl_BRAM_PORTA1] {
        set net [get_bd_intf_nets -quiet $net_name]
        if {[llength $net] > 0} { delete_bd_objs $net }
    }
    connect_bd_intf_net -intf_net [get_bd_intf_nets -quiet axi_ctrl_ic_M02_AXI] \
        [get_bd_intf_pins axi_ctrl_ic/M02_AXI] [get_bd_intf_pins fb_cap_bram_ctrl/S_AXI]
    connect_bd_intf_net -intf_net [get_bd_intf_nets -quiet fb_cap_bram_ctrl_BRAM_PORTA] \
        [get_bd_intf_pins fb_cap_bram_ctrl/BRAM_PORTA] [get_bd_intf_pins gba_pl_top_0/fb_cap_bram]
    foreach pin_path [list axi_ctrl_ic/M02_ACLK axi_ctrl_ic/M02_ARESETN \
                           fb_cap_bram_ctrl/s_axi_aclk fb_cap_bram_ctrl/s_axi_aresetn] {
        set pin [get_bd_pins -quiet $pin_path]
        if {[llength $pin] > 0} {
            set net [get_bd_nets -quiet -of_objects $pin]
            if {[llength $net] > 0} { disconnect_bd_net $net $pin }
        }
    }
    connect_bd_net [get_bd_pins ps_core/FCLK_CLK0] [get_bd_pins axi_ctrl_ic/M02_ACLK]
    connect_bd_net [get_bd_pins rst_50M/peripheral_aresetn] [get_bd_pins axi_ctrl_ic/M02_ARESETN]
    connect_bd_net [get_bd_pins ps_core/FCLK_CLK0] [get_bd_pins fb_cap_bram_ctrl/s_axi_aclk]
    connect_bd_net [get_bd_pins rst_50M/peripheral_aresetn] [get_bd_pins fb_cap_bram_ctrl/s_axi_aresetn]
    set fb_cap_mem_seg [get_bd_addr_segs -quiet fb_cap_bram_ctrl/S_AXI/Mem0]
    set fb_cap_ps_seg  [get_bd_addr_segs -quiet -filter {NAME == "SEG_fb_cap_bram_ctrl_Mem0"}]
    if {[llength $fb_cap_mem_seg] > 0} {
        if {[llength $fb_cap_ps_seg] == 0} {
            create_bd_addr_seg -range 256K -offset 0x44000000 \
                [get_bd_addr_spaces ps_core/Data] $fb_cap_mem_seg SEG_fb_cap_bram_ctrl_Mem0
        } else {
            set_property offset 0x44000000 $fb_cap_ps_seg
            set_property range 256K $fb_cap_ps_seg
        }
    }

    set ps_core_cell [get_bd_cells -quiet ps_core]
    if {[llength $ps_core_cell] > 0} {
        set_property -dict [list \
            CONFIG.PCW_EN_USB0 {1} CONFIG.PCW_USB0_PERIPHERAL_ENABLE {1} \
            CONFIG.PCW_USB0_USB0_IO {MIO 28 .. 39} \
            CONFIG.PCW_USB0_RESET_ENABLE {1} CONFIG.PCW_USB0_RESET_IO {MIO 46} \
            CONFIG.PCW_USB_RESET_POLARITY {Active Low} CONFIG.PCW_USB_RESET_SELECT {Share reset pin} \
            CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {0} CONFIG.PCW_EN_ENET0 {0} \
            CONFIG.PCW_EN_I2C0 {1} CONFIG.PCW_EN_EMIO_I2C0 {1} CONFIG.PCW_I2C0_I2C0_IO {EMIO} \
            CONFIG.PCW_EN_I2C1 {1} CONFIG.PCW_EN_EMIO_I2C1 {1} CONFIG.PCW_I2C1_I2C1_IO {EMIO} \
            CONFIG.PCW_EN_GPIO {1} CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
            CONFIG.PCW_GPIO_MIO_GPIO_IO {MIO} CONFIG.PCW_EN_EMIO_GPIO {1} \
            CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {1} CONFIG.PCW_GPIO_EMIO_GPIO_IO {EMIO} \
            CONFIG.PCW_IRQ_F2P_INTR {1} \
        ] $ps_core_cell
        set_property CONFIG.PCW_MIO_50_PULLUP {disabled} $ps_core_cell
        set_property CONFIG.PCW_MIO_51_PULLUP {disabled} $ps_core_cell
    }

    if {[llength [get_bd_ports -quiet hdmi_tx_hpd]] == 0} { create_bd_port -dir I hdmi_tx_hpd }
    foreach intf_name [list AUDIO_IIC HDMI_DDC_IIC] {
        if {[llength [get_bd_intf_ports -quiet $intf_name]] == 0} {
            create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 $intf_name
        }
    }
    set ps_iic0_pin  [get_bd_intf_pins  -quiet ps_core/IIC_0]
    set ps_iic1_pin  [get_bd_intf_pins  -quiet ps_core/IIC_1]
    set audio_iic_if [get_bd_intf_ports -quiet AUDIO_IIC]
    set hdmi_ddc_if  [get_bd_intf_ports -quiet HDMI_DDC_IIC]
    if {[llength $ps_iic0_pin] > 0 && [llength $audio_iic_if] > 0} {
        foreach intf_obj [list $ps_iic0_pin $audio_iic_if] {
            set net [get_bd_intf_nets -quiet -of_objects $intf_obj]
            if {[llength $net] > 0} { disconnect_bd_intf_net $net $intf_obj }
        }
        connect_bd_intf_net $ps_iic0_pin $audio_iic_if
    }
    if {[llength $ps_iic1_pin] > 0 && [llength $hdmi_ddc_if] > 0} {
        foreach intf_obj [list $ps_iic1_pin $hdmi_ddc_if] {
            set net [get_bd_intf_nets -quiet -of_objects $intf_obj]
            if {[llength $net] > 0} { disconnect_bd_intf_net $net $intf_obj }
        }
        connect_bd_intf_net $ps_iic1_pin $hdmi_ddc_if
    }

    if {[llength [get_bd_cells -quiet hdmi_hpd_gpio_concat]] == 0} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 hdmi_hpd_gpio_concat }
    if {[llength [get_bd_cells -quiet hdmi_hpd_gpio_zero]] == 0} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 hdmi_hpd_gpio_zero }
    set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {1} CONFIG.IN1_WIDTH {63}] \
        [get_bd_cells hdmi_hpd_gpio_concat]
    set_property -dict [list CONFIG.CONST_WIDTH {63} CONFIG.CONST_VAL {0}] \
        [get_bd_cells hdmi_hpd_gpio_zero]
    foreach pin_path [list ps_core/GPIO_I hdmi_hpd_gpio_concat/In0 \
                           hdmi_hpd_gpio_concat/In1 hdmi_hpd_gpio_concat/dout \
                           hdmi_hpd_gpio_zero/dout] {
        set pin [get_bd_pins -quiet $pin_path]
        if {[llength $pin] > 0} {
            set net [get_bd_nets -quiet -of_objects $pin]
            if {[llength $net] > 0} { disconnect_bd_net $net $pin }
        }
    }
    set hpd_port [get_bd_ports -quiet hdmi_tx_hpd]
    if {[llength $hpd_port] > 0} {
        set hpd_net [get_bd_nets -quiet -of_objects $hpd_port]
        if {[llength $hpd_net] > 0} { disconnect_bd_net $hpd_net $hpd_port }
    }
    if {[llength [get_bd_pins -quiet ps_core/GPIO_I]] > 0 && [llength $hpd_port] > 0} {
        foreach fixed_net_name [list hdmi_tx_hpd_net hdmi_hpd_gpio_zero_net hdmi_hpd_gpio_gpioi_net] {
            set fixed_net [get_bd_nets -quiet $fixed_net_name]
            if {[llength $fixed_net] > 0} { delete_bd_objs $fixed_net }
        }
        connect_bd_net -net hdmi_tx_hpd_net $hpd_port [get_bd_pins hdmi_hpd_gpio_concat/In0]
        connect_bd_net -net hdmi_hpd_gpio_zero_net \
            [get_bd_pins hdmi_hpd_gpio_zero/dout] [get_bd_pins hdmi_hpd_gpio_concat/In1]
        connect_bd_net -net hdmi_hpd_gpio_gpioi_net \
            [get_bd_pins hdmi_hpd_gpio_concat/dout] [get_bd_pins ps_core/GPIO_I]
    }

    foreach intf_net [get_bd_intf_nets -quiet] {
        set intf_pins  [get_bd_intf_pins  -quiet -of_objects $intf_net]
        set intf_ports [get_bd_intf_ports -quiet -of_objects $intf_net]
        if {[llength $intf_pins] == 0 && [llength $intf_ports] == 0} { delete_bd_objs $intf_net }
    }
    foreach net [get_bd_nets -quiet {hdmi_tx_hpd* hdmi_hpd_gpio_concat_dout* hdmi_hpd_gpio_zero_dout*}] {
        set pins  [get_bd_pins  -quiet -of_objects $net]
        set ports [get_bd_ports -quiet -of_objects $net]
        if {([llength $pins] + [llength $ports]) < 2} { delete_bd_objs $net }
    }

    # 单一复合IP负责视频输出和HDMI发送；GBA只连接视频/PCM与系统时钟。
    evip_bd_configure_composite

    if {[llength [get_bd_cells -quiet pl_irq_concat]] == 0} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 pl_irq_concat }
    set_property -dict [list CONFIG.NUM_PORTS {2}] [get_bd_cells pl_irq_concat]
    foreach pin_path [list pl_irq_concat/In0 pl_irq_concat/In1 ps_core/IRQ_F2P] {
        set pin [get_bd_pins -quiet $pin_path]
        if {[llength $pin] > 0} {
            set net [get_bd_nets -quiet -of_objects $pin]
            if {[llength $net] > 0} { disconnect_bd_net $net $pin }
        }
    }
    connect_bd_net [get_bd_pins gba_pl_top_0/irq] [get_bd_pins pl_irq_concat/In0]
    connect_bd_net [get_bd_pins hdmi_vdma/mm2s_introut] [get_bd_pins pl_irq_concat/In1]
    connect_bd_net [get_bd_pins pl_irq_concat/dout] [get_bd_pins ps_core/IRQ_F2P]

    validate_bd_design
    save_bd_design
    normalize_xci_shareddir [file join $local_bd_dir ip]
    set bd_obj [get_files $local_bd_file]
    reset_target all $bd_obj
    generate_target all $bd_obj
    export_ip_user_files -of_objects $bd_obj -no_script -sync -force
    evip_bd_apply_z7_clock_constraints
    save_bd_design
    set hdmi_clk_legacy_xdc [get_files -quiet *zynq_gba_system_hdmi_clk_gen_0.xdc]
    if {[llength $hdmi_clk_legacy_xdc] > 0} {
        set_property used_in_synthesis false $hdmi_clk_legacy_xdc
        set_property used_in_implementation false $hdmi_clk_legacy_xdc
    }
    make_wrapper -files [get_files $local_bd_file] -top -import -force
    close_bd_design [current_bd_design]
    set_property top ${bd_name}_wrapper [get_filesets sources_1]
    set_property top ${bd_name}_wrapper [get_filesets sim_1]
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1

} else {
    log_step "Stage 1b: project unchanged — open existing"
    open_project $project_file
    set_param general.maxThreads 8
    set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY} [current_project]
    update_compile_order -fileset sources_1
}

if {[info exists ::env(EMBEDDED_VIDEO_IP_BD_ONLY)] &&
    ($::env(EMBEDDED_VIDEO_IP_BD_ONLY) eq "1")} {
    close_project
    puts "GBA_EMBEDDED_VIDEO_IP_BD_PASS"
    exit
}

#-----------------------------------------------------------------------------
# Stage 2 — Synthesis (incremental when possible)
#-----------------------------------------------------------------------------
log_step "Stage 2: synthesis"

set_param general.maxThreads 8
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY} [current_project]

# Only reset runs if this is a full rebuild
if {$need_full_rebuild} {
    reset_run synth_1
    reset_run impl_1
}

# Check if synthesis output is already valid
set synth_complete 0
set synth_run [get_runs -quiet synth_1]
if {[llength $synth_run] > 0} {
    set synth_status [get_property STATUS $synth_run]
    set synth_status_lower [string tolower $synth_status]
    if {[string match "*xst completed*" $synth_status_lower] ||
        [string match "*synthesis finished*" $synth_status_lower] ||
        [string match "*synth_design complete*" $synth_status_lower]} {
        log_step "Stage 2: synthesis already complete — skip"
        set synth_complete 1
    }
}

if {!$synth_complete} {
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    set synth_status [string tolower [get_property STATUS [get_runs synth_1]]]
    if {![string match "*synthesis finished*" $synth_status] &&
        ![string match "*synth_design complete*" $synth_status]} {
        error "Synthesis did not complete successfully: $synth_status"
    }
}

#-----------------------------------------------------------------------------
# Stage 3 — Implementation (incremental when possible)
#-----------------------------------------------------------------------------
log_step "Stage 3: implementation"

set impl_complete 0
set impl_qor_result {}
set impl_run [get_runs -quiet impl_1]
if {[llength $impl_run] > 0} {
    if {[impl_run_succeeded $impl_run]} {
        log_step "Stage 3: implementation already complete — skip"
        set impl_complete 1
    }
}

if {!$impl_complete} {
    set impl_qor_result [launch_impl_and_gate \
        $repo_root $python_cmd $cache_script [expr {$incremental_dcp ne ""}]]
} else {
    set impl_qor_result [impl_gate $repo_root $python_cmd $cache_script]
    if {[lindex $impl_qor_result 0] ne "1"} {
        error "Existing implementation failed the QoR/DRC gate: $impl_qor_result"
    }
}

#-----------------------------------------------------------------------------
# Stage 4 — Export XSA
#-----------------------------------------------------------------------------
log_step "Stage 4: export XSA"

open_run impl_1
if {[file exists $xsa_file]} { file delete -force $xsa_file }
write_hw_platform -fixed -include_bit -force -file $xsa_file
log_step "done — $xsa_file"
set routed_dcp [file join $out_root Zynq-GBA_MisTer-Vivado.runs impl_1 zynq_gba_system_wrapper_routed.dcp]
set bitstream_file [file join $out_root Zynq-GBA_MisTer-Vivado.runs impl_1 zynq_gba_system_wrapper.bit]
puts "GBA_BUILD_BITSTREAM=$bitstream_file"
puts "GBA_BUILD_XSA=$xsa_file"
puts "GBA_BUILD_ROUTED_DCP=$routed_dcp"
puts "GBA_BUILD_TIMING_REPORT=[file join $out_root reports timing_summary.rpt]"
puts "GBA_BUILD_DRC_REPORT=[file join $out_root reports drc.rpt]"
close_project
exit
