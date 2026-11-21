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

proc impl_gate {repo_root python_cmd cache_script} {
    global out_root
    set report_dir [file join $out_root reports]
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
set bd_synth_netlist [file join $project_dir gba-zynq7020.gen sources_1 bd zynq_gba_system synth zynq_gba_system.v]
if {![file isfile $bd_synth_netlist]} {
    log_step "Generate missing Block Design output products"
    generate_target all $bd
    export_ip_user_files -of_objects $bd -no_script -sync -force
} else {
    log_step "Reuse generated Block Design output products"
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
