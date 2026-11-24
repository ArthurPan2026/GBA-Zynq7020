#=============================================================================
# build_bitstream.tcl — single-pass project build → bitstream → XSA export.
# Skips synthesis / implementation when inputs haven't changed.
#=============================================================================
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
if {[info exists ::env(ZYNQ_GBA_REPO_ROOT)] && $::env(ZYNQ_GBA_REPO_ROOT) ne {}} {
    set repo_root [file normalize $::env(ZYNQ_GBA_REPO_ROOT)]
}
set out_root [file normalize [file join $repo_root build fpga-flow vivado hardware]]
if {[info exists ::env(ZYNQ_GBA_OUT_DIR)] && $::env(ZYNQ_GBA_OUT_DIR) ne {}} {
    set out_root [file normalize $::env(ZYNQ_GBA_OUT_DIR)]
}
set canonical_project_dir [file normalize [file join $repo_root vivado]]
set canonical_project_file [file join $canonical_project_dir gba-zynq7020.xpr]
set project_dir $canonical_project_dir
set project_copy_mode 0
if {[info exists ::env(ZYNQ_GBA_PROJECT_DIR)] && $::env(ZYNQ_GBA_PROJECT_DIR) ne {}} {
    set project_dir [file normalize $::env(ZYNQ_GBA_PROJECT_DIR)]
    set project_copy_mode 1
}
file mkdir $out_root
file mkdir [file dirname $project_dir]

set project_name "gba-zynq7020"
set xsa_file      [file join $out_root zynq_gba_system_wrapper.xsa]
set project_file  [file join $project_dir ${project_name}.xpr]
set cache_script  [file join $repo_root scripts flow incremental_build_cache.py]
source [file join $script_dir embedded_video_ip_consumer.tcl]
source [file join $script_dir embedded_video_ip_bd.tcl]

set evip_root [file normalize [file join $repo_root ip-repo embedded-video-ip]]
set evip_version_file [file join $evip_root VERSION]
set evip_ip_repo [file join $evip_root ip_repo]
set evip_component [file join $evip_ip_repo panfpga embedded_video_ip component.xml]
if {![file isfile $evip_version_file] || ![file isfile $evip_component]} {
    error "EmbeddedVideoIP release package is missing: $evip_root"
}
set evip_fd [open $evip_version_file r]
set evip_version [string trim [read $evip_fd]]
close $evip_fd
if {$evip_version ne $evip_expected_version} {
    error "GBA expects EmbeddedVideoIP $evip_expected_version; found $evip_version"
}
foreach interface_file {tmds.xml tmds_rtl.xml} {
    if {![file isfile [file join $evip_ip_repo if tmds_v1_0 $interface_file]]} {
        error "EmbeddedVideoIP interface file is missing: $interface_file"
    }
}

#-----------------------------------------------------------------------------
# Utilities
#-----------------------------------------------------------------------------
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

proc verify_1080p60_mmcm_topology {} {
    set mmcm_cells [get_cells -quiet -hier -filter {REF_NAME == MMCME2_ADV && NAME =~ *serializer_mmcm}]
    if {[llength $mmcm_cells] != 1} {
        error "1080p60 experiment expected one serializer_mmcm MMCME2_ADV, found [llength $mmcm_cells]"
    }
    set mmcm_name [get_property NAME [lindex $mmcm_cells 0]]
    set bufio_cells [get_cells -quiet -hier -filter {REF_NAME == BUFIO && NAME =~ *video_output/clocks/u_tmds_bufio}]
    set bufr_cells [get_cells -quiet -hier -filter {REF_NAME == BUFR && NAME =~ *video_output/clocks/u_serdes_bufr}]
    if {[llength $bufio_cells] != 1 || [llength $bufr_cells] != 1} {
        error "1080p60 experiment expected one named BUFIO and BUFR clock path"
    }
    set bufio_name [get_property NAME [lindex $bufio_cells 0]]
    set bufr_name [get_property NAME [lindex $bufr_cells 0]]
    set bufio_sources [all_fanin -flat -startpoints_only -to [get_pins "$bufio_name/I"]]
    set bufr_sources [all_fanin -flat -startpoints_only -to [get_pins "$bufr_name/I"]]
    if {[lsearch -exact $bufio_sources "$mmcm_name/CLKOUT0"] < 0 ||
        [lsearch -exact $bufr_sources "$mmcm_name/CLKOUT1"] < 0} {
        error "1080p60 experiment expected serializer_mmcm CLKOUT0->BUFIO and CLKOUT1->BUFR"
    }
    set serdes_cells [get_cells -quiet -hier -filter {REF_NAME == OSERDESE2}]
    if {[llength $serdes_cells] != 8} {
        error "1080p60 experiment expected eight OSERDESE2 cells, found [llength $serdes_cells]"
    }
    foreach serdes $serdes_cells {
        set clk_fanin [all_fanin -flat -startpoints_only -to [get_pins "$serdes/CLK"]]
        set clkdiv_fanin [all_fanin -flat -startpoints_only -to [get_pins "$serdes/CLKDIV"]]
        if {[lsearch -exact $clk_fanin "$bufio_name/O"] < 0 ||
            [lsearch -exact $clkdiv_fanin "$bufr_name/O"] < 0} {
            error "OSERDESE2 $serdes is not driven through the verified BUFIO/BUFR outputs"
        }
    }
    foreach mode {480 720 1080p30 1080p60} {
        set mode_clocks [get_clocks -quiet "evip_${mode}_*"]
        if {[llength $mode_clocks] != 4} {
            error "1080p60 experiment expected four constrained clocks for mode $mode, found [llength $mode_clocks]"
        }
    }
    set profile_clock_names {}
    foreach mode {480 720 1080p30 1080p60} {
        set mode_clocks [get_clocks -quiet "evip_${mode}_*"]
        if {[llength $mode_clocks] != 4} {
            error "1080p60 experiment expected four constrained clocks for mode $mode, found [llength $mode_clocks]"
        }
        foreach clock $mode_clocks { lappend profile_clock_names [get_property NAME $clock] }
    }
    set allowed_auto_clocks {
        mmcm_feedback mmcm_feedback_1 raw_serial raw_serial_1 raw_pixel raw_pixel_1
        logic_pixel_raw logic_pixel_raw_1 monitor_raw monitor_raw_1
        serdes_pixel_clk serdes_pixel_clk_1
    }
    foreach {pin_pattern suffix} {
        *video_output/clocks/u_tmds_bufio/O serial
        *video_output/clocks/u_serdes_bufr/O serdes
        *video_output/clocks/logic_pixel_buffer/O pixel
        *video_output/clocks/serial_monitor_buffer/O monitor
    } {
        set profile_pin [get_pins -quiet -hier -filter "NAME =~ $pin_pattern"]
        set profile_clocks [get_clocks -quiet -of_objects $profile_pin]
        if {[llength $profile_pin] != 1} {
            error "Expected one clock output pin for $pin_pattern"
        }
        foreach mode {480 720 1080p30 1080p60} {
            set expected_clock "evip_${mode}_${suffix}"
            if {[lsearch -exact $profile_clocks $expected_clock] < 0} {
                error "Clock output $pin_pattern is missing $expected_clock"
            }
        }
        foreach clock $profile_clocks {
            if {[lsearch -exact $profile_clock_names $clock] < 0 &&
                [lsearch -exact $allowed_auto_clocks $clock] < 0} {
                error "Unexpected clock alias on $pin_pattern: $clock"
            }
        }
    }
    log_step "Verified MMCM->BUFIO/BUFR->8 OSERDESE2 topology and all runtime/auto clock aliases"
}

proc impl_gate {repo_root python_cmd cache_script {phase ""}} {
    global out_root project_dir project_name
    set report_dir [file join $out_root reports]
    if {$phase ne ""} {
        set report_dir [file join $report_dir $phase]
    }
    file mkdir $report_dir
    set timing_report [file join $report_dir timing_summary.rpt]
    set drc_report [file join $report_dir drc.rpt]
    set bus_skew_report [file join $report_dir bus_skew.rpt]
    set experiment_1080p60 [expr {[info exists ::env(ZYNQ_GBA_EXPERIMENT_1080P60)] &&
                                  $::env(ZYNQ_GBA_EXPERIMENT_1080P60) eq "1"}]

    if {$phase eq "pre-route"} {
        set checkpoint [file join $project_dir "$project_name.runs" impl_1 zynq_gba_system_wrapper_physopt.dcp]
        if {![file isfile $checkpoint]} {
            error "post-physopt checkpoint is missing: $checkpoint"
        }
        open_checkpoint $checkpoint
    } elseif {$phase eq "post-route"} {
        set checkpoint [file join $project_dir "$project_name.runs" impl_1 zynq_gba_system_wrapper_postroute_physopt.dcp]
        if {![file isfile $checkpoint]} {
            set checkpoint [file join $project_dir "$project_name.runs" impl_1 zynq_gba_system_wrapper_routed.dcp]
        }
        if {![file isfile $checkpoint]} {
            error "post-route checkpoint is missing: $checkpoint"
        }
        open_checkpoint $checkpoint
    } else {
        open_run impl_1
    }
    if {$experiment_1080p60} {
        verify_1080p60_mmcm_topology
    }

    report_timing_summary -delay_type min_max -file $timing_report
    set pulse_report [file join $report_dir pulse_width.rpt]
    report_pulse_width -all_violators -limit 100000 -file $pulse_report
    report_bus_skew -warn_on_violation -file $bus_skew_report
    report_drc -file $drc_report
    set drc_error_violations [get_drc_violations -quiet -filter {SEVERITY == Error}]
    set drc_errors_actual [llength $drc_error_violations]
    set drc_errors_gate $drc_errors_actual
    set allowed_topology_errors 0
    if {$phase eq "pre-route" && $experiment_1080p60} {
        set drc_errors_gate 0
        foreach violation $drc_error_violations {
            if {[get_property CHECK $violation] eq "REQP-1975"} {
                incr allowed_topology_errors
            } else {
                incr drc_errors_gate
            }
        }
    }
    set critical_warnings [llength [get_drc_violations -quiet -filter {SEVERITY == "Critical Warning"}]]
    close_design

    set gate_args [list --timing-report $timing_report --pulse-report $pulse_report \
        --bus-skew-report $bus_skew_report \
        --drc-errors $drc_errors_gate --critical-warnings $critical_warnings]
    if {$experiment_1080p60} {
        lappend gate_args --experiment-1080p60
    }
    if {$phase eq "pre-route"} {
        lappend gate_args --pre-route
    }
    set result [run_cache_tool $python_cmd $cache_script gate {*}$gate_args]
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
    puts $gate_file "drc_errors_gate=[lindex $fields 5]"
    puts $gate_file "drc_errors_actual=$drc_errors_actual"
    puts $gate_file "pre_route_allowed_reqp1975=$allowed_topology_errors"
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

proc impl_physopt_succeeded {run} {
    set status [string tolower [get_property STATUS $run]]
    return [expr {[string match "*phys_opt_design complete*" $status] ||
                  [string match "*phys opt design complete*" $status] ||
                  [string match "*physopt design complete*" $status] ||
                  [string match "*not started route_design*" $status]}]
}
proc impl_postroute_physopt_succeeded {run} {
    set status [string tolower [get_property STATUS $run]]
    return [expr {[string match "*phys_opt_design (post-route) complete*" $status] ||
                  [string match "*post_route_phys_opt_design complete*" $status] ||
                  [string match "*post route phys opt design complete*" $status] ||
                  [string match "*not started write_bitstream*" $status]}]
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

    # Placement timing is diagnostic. Give timing-driven routing a chance to
    # repair setup, hold, and skew; only the final post-route gate releases a bitstream.
    set experiment_1080p60 [expr {[info exists ::env(ZYNQ_GBA_EXPERIMENT_1080P60)] &&
                                  $::env(ZYNQ_GBA_EXPERIMENT_1080P60) eq "1"}]
    if {$experiment_1080p60} {
        log_step "1080p60 experiment: place and physically optimize before route gate"
        set physopt_error [catch {
            launch_runs impl_1 -to_step phys_opt_design -jobs 8
            wait_on_run impl_1
        } physopt_message]
        if {$physopt_error} {
            error "1080p60 post-place physopt failed: $physopt_message"
        }
        if {![impl_physopt_succeeded $run]} {
            error "1080p60 post-place run did not complete physopt: [get_property STATUS $run]"
        }
        set pre_route_error [catch {
            impl_gate $repo_root $python_cmd $cache_script pre-route
        } pre_route_result]
        if {$pre_route_error} {
            error "1080p60 pre-route QoR gate could not be evaluated: $pre_route_result"
        }
        if {[lindex $pre_route_result 0] ne "1"} {
            error "1080p60 pre-route structural/DRC gate failed; routing was skipped: $pre_route_result"
        }
        log_step "1080p60 pre-route structural gate passed; attempting route and post-route phys_opt"
        set postroute_error [catch {
            launch_runs impl_1 -to_step {phys_opt_design (Post-Route)} -jobs 8
            wait_on_run impl_1
        } postroute_message]
        if {$postroute_error} {
            error "1080p60 route/post-route physopt failed: $postroute_message"
        }
        if {![impl_postroute_physopt_succeeded $run]} {
            error "1080p60 run did not complete post-route phys_opt_design: [get_property STATUS $run]"
        }
        set postroute_gate_error [catch {
            impl_gate $repo_root $python_cmd $cache_script post-route
        } postroute_result]
        if {$postroute_gate_error} {
            error "1080p60 post-route QoR gate could not be evaluated: $postroute_result"
        }
        if {[lindex $postroute_result 0] ne "1"} {
            error "1080p60 post-route QoR/DRC gate failed; bitstream was skipped: $postroute_result"
        }
        log_step "1080p60 post-route setup/hold/DRC gate passed; generating bitstream"
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
# Stage 1 — Open the version-controlled Vivado project
#-----------------------------------------------------------------------------
log_step "Stage 1: open tracked Vivado project"

if {![file isfile $canonical_project_file]} {
    error "Canonical Vivado project is missing: $canonical_project_file"
}
if {$project_copy_mode} {
    set output_root [file normalize $out_root]
    set project_dir [file normalize $project_dir]
    if {$project_dir eq $output_root || ![string match "${output_root}/*" $project_dir]} {
        error "Flow project workspace must be inside the build output directory: $project_dir"
    }
    if {[file exists $project_dir]} {
        file delete -force $project_dir
    }
    file mkdir [file dirname $project_dir]
    open_project -read_only $canonical_project_file
    save_project_as -exclude_run_results -force $project_name $project_dir
    close_project
}
if {![file isfile $project_file]} {
    error "Vivado working project is missing: $project_file"
}
set python_cmd [resolve_python]
open_project $project_file
if {$project_copy_mode} {
    foreach run_name {synth_1 impl_1} {
        set run [get_runs $run_name]
        catch {reset_property INCREMENTAL_CHECKPOINT $run}
        catch {set_property AUTO_INCREMENTAL_CHECKPOINT 0 $run}
        reset_run $run_name
    }
}
set_param general.maxThreads 8
set bd [get_files -quiet [file join $project_dir gba-zynq7020.srcs sources_1 bd zynq_gba_system zynq_gba_system.bd]]
if {[llength $bd] != 1} {
    set bd [get_files -quiet *zynq_gba_system.bd]
}
if {[llength $bd] != 1} {
    error "Tracked project must contain exactly one zynq_gba_system.bd"
}
# The project copy can carry stale ipshared HDL from the tracked Block Design.
# Refresh the catalog and generated products from the current local IP package.
set_property ip_repo_paths [list $evip_ip_repo] [current_project]
update_ip_catalog
open_bd_design $bd
set embedded_video_ip_bd_cell [get_bd_cells -quiet hdmi_video_pipeline]
if {[llength $embedded_video_ip_bd_cell] != 1} {
    error "Tracked Block Design must contain exactly one hdmi_video_pipeline IP cell"
}
log_step "Upgrade the embedded-video IP instance to the current repository revision"
upgrade_bd_cells $embedded_video_ip_bd_cell
evip_bd_configure_composite
validate_bd_design
set pipeline [get_bd_cells hdmi_video_pipeline]
foreach {parameter expected} [list MAX_INPUT_WIDTH $evip_max_input_width MAX_INPUT_HEIGHT $evip_max_input_height MAX_SCALER_INPUT_WIDTH $evip_max_scaler_width MAX_SCALER_INPUT_HEIGHT $evip_max_scaler_height] {
    set actual [get_property CONFIG.$parameter $pipeline]
    if {$actual ne $expected} {
        error "EmbeddedVideoIP $parameter: expected $expected, got $actual"
    }
}
save_bd_design
log_step "Applied current EmbeddedVideoIP consumer parameters to the Block Design"
log_step "Refresh Block Design output products from current IP sources"
reset_target all $bd
generate_target all $bd
export_ip_user_files -of_objects $bd -no_script -sync -force
evip_bd_apply_z7_clock_constraints
set hdmi_clk_legacy_xdc [get_files -quiet *zynq_gba_system_hdmi_clk_gen_0.xdc]
if {[llength $hdmi_clk_legacy_xdc] > 0} {
    set_property used_in_synthesis false $hdmi_clk_legacy_xdc
    set_property used_in_implementation false $hdmi_clk_legacy_xdc
}
update_compile_order -fileset sources_1
set need_full_rebuild 0

set incremental_dcp {}
if {!$project_copy_mode && [info exists ::env(ZYNQ_GBA_INCREMENTAL_DCP)] &&
    $::env(ZYNQ_GBA_INCREMENTAL_DCP) ne {} &&
    [file isfile $::env(ZYNQ_GBA_INCREMENTAL_DCP)]} {
    set incremental_dcp [file normalize $::env(ZYNQ_GBA_INCREMENTAL_DCP)]
    set incremental_cache_dir [file join $out_root flow incremental_dcp]
    file mkdir $incremental_cache_dir
    set retained_dcp [file join $incremental_cache_dir last_good_routed.dcp]
    if {[file normalize $incremental_dcp] ne [file normalize $retained_dcp]} {
        file copy -force $incremental_dcp $retained_dcp
    }
    set incremental_dcp [file normalize $retained_dcp]
    log_step "Implementation may reuse verified DCP: $incremental_dcp"
} else {
    log_step "Implementation starts without an incremental DCP"
}

#-----------------------------------------------------------------------------
# Stage 2 — Synthesis (incremental when possible)
#-----------------------------------------------------------------------------
log_step "Stage 2: synthesis"

set_param general.maxThreads 8
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY} [current_project]
# Replicate high-fanout reset/control drivers before timing-driven placement.
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveFanoutOpt [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

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
    if {[string match "*out-of-date*" $synth_status_lower] ||
        [string match "*needs reset*" $synth_status_lower]} {
        log_step "Synthesis inputs changed; reset synthesis and implementation runs"
        reset_run synth_1
        reset_run impl_1
        set synth_run [get_runs synth_1]
        set synth_status [get_property STATUS $synth_run]
        set synth_status_lower [string tolower $synth_status]
    }
    if {[string match "*xst completed*" $synth_status_lower] ||
        [string match "*synthesis finished*" $synth_status_lower] ||
        [string match "*synth_design complete*" $synth_status_lower]} {
        log_step "Stage 2: synthesis already complete — skip"
        set synth_complete 1
    }
}

if {!$synth_complete} {
    if {[info exists ::env(ZYNQ_GBA_EXPERIMENT_1080P60)] &&
        $::env(ZYNQ_GBA_EXPERIMENT_1080P60) eq "1"} {
        set synth_run [get_runs synth_1]
        set_property AUTO_INCREMENTAL_CHECKPOINT 0 $synth_run
        catch {reset_property INCREMENTAL_CHECKPOINT $synth_run}
        if {[get_property AUTO_INCREMENTAL_CHECKPOINT $synth_run]} {
            error "Unable to disable incremental synthesis for the 1080p60 experiment"
        }
        reset_run synth_1
        log_step "1080p60 experiment synthesis has no incremental checkpoint"
    }
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
    set impl_status_lower [string tolower [get_property STATUS $impl_run]]
    if {[string match "*out-of-date*" $impl_status_lower] ||
        [string match "*needs reset*" $impl_status_lower]} {
        log_step "Implementation inputs changed; reset implementation run"
        reset_run impl_1
        set impl_run [get_runs impl_1]
    }
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
set routed_dcp [file join $project_dir gba-zynq7020.runs impl_1 zynq_gba_system_wrapper_routed.dcp]
set bitstream_file [file join $project_dir gba-zynq7020.runs impl_1 zynq_gba_system_wrapper.bit]
puts "GBA_BUILD_BITSTREAM=$bitstream_file"
puts "GBA_BUILD_XSA=$xsa_file"
puts "GBA_BUILD_ROUTED_DCP=$routed_dcp"
puts "GBA_BUILD_TIMING_REPORT=[file join $out_root reports timing_summary.rpt]"
puts "GBA_BUILD_DRC_REPORT=[file join $out_root reports drc.rpt]"
close_project
exit
