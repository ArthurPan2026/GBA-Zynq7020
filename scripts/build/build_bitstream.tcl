# Canonical full Vivado build. Generated projects, reports, bitstreams and XSA stay under out/vivado.
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
if {[info exists ::env(ZYNQ_GBA_REPO_ROOT)]} {
    set repo_root [file normalize $::env(ZYNQ_GBA_REPO_ROOT)]
}
set out_root [file normalize [file join $repo_root out vivado]]
if {[info exists ::env(ZYNQ_GBA_OUT_DIR)]} {
    set out_root [file normalize $::env(ZYNQ_GBA_OUT_DIR)]
}
set project_name "Zynq-GBA_MisTer-Vivado"
set project_file [file join $out_root ${project_name}.xpr]
set bit_file [file join $out_root ${project_name}.runs impl_1 zynq_gba_system_wrapper.bit]
set xsa_file [file join $out_root zynq_gba_system_wrapper.xsa]

proc flow_available_cpu_count {} {
    if {[info exists ::env(NUMBER_OF_PROCESSORS)] && [string is integer -strict $::env(NUMBER_OF_PROCESSORS)] && $::env(NUMBER_OF_PROCESSORS) > 0} {
        return $::env(NUMBER_OF_PROCESSORS)
    }
    if {![catch {exec nproc} detected] && [string is integer -strict [string trim $detected]] && [string trim $detected] > 0} {
        return [string trim $detected]
    }
    return 8
}

proc flow_select_jobs {} {
    set available [flow_available_cpu_count]
    set current_max [get_param general.maxThreads]
    if {![string is integer -strict $current_max] || $current_max < 1} { set current_max $available }
    set requested [expr {min(8, $available)}]
    if {[info exists ::env(ZYNQ_GBA_JOBS)]} {
        set candidate $::env(ZYNQ_GBA_JOBS)
        if {![string is integer -strict $candidate] || $candidate < 1 || $candidate > 8} {
            error "ZYNQ_GBA_JOBS must be an integer from 1 through 8; got '$candidate'"
        }
        set requested $candidate
    }
    return [expr {min($requested, $current_max)}]
}

proc require_run_success {run_name} {
    set run [get_runs -quiet $run_name]
    if {[llength $run] == 0} {
        error "Vivado run not found: $run_name"
    }
    set status [string tolower [get_property STATUS $run]]
    if {![string match "*finished*" $status] && ![string match "*complete*" $status]} {
        error "Vivado run $run_name failed or is incomplete: $status"
    }
}

try {
    # This opens and leaves the generated project active for the following stages.
    source [file join $script_dir rebuild_project.tcl]
    set jobs [flow_select_jobs]
    set_param general.maxThreads $jobs
    set settings [open [file join $out_root flow_build_settings.txt] w]
    puts $settings "requested=$jobs"
    puts $settings "maxThreads=[get_param general.maxThreads]"
    close $settings
    set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY} [current_project]
    update_compile_order -fileset sources_1
    reset_run synth_1
    reset_run impl_1
    puts "--- Stage 1: synthesis ---"
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    require_run_success synth_1
    puts "--- Stage 2: implementation and bitstream ---"
    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_on_run impl_1
    require_run_success impl_1
    puts "--- Stage 3: export XSA ---"
    open_run impl_1
    write_hw_platform -fixed -include_bit -force -file $xsa_file
    if {![file isfile $bit_file]} {
        error "Expected bitstream was not produced: $bit_file"
    }
    if {![file isfile $xsa_file]} {
        error "Expected XSA was not produced: $xsa_file"
    }
    puts "--- Build complete: $bit_file and $xsa_file ---"
} finally {
    # The orchestrator owns cleanup; rebuilding a project alone leaves it open for inspection.
    if {[llength [get_projects -quiet]] > 0} {
        close_project
    }
}
