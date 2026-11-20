set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set out_root [file normalize [file join $repo_root build vivado hardware]]
if {[info exists ::env(ZYNQ_GBA_OUT_DIR)]} { set out_root [file normalize $::env(ZYNQ_GBA_OUT_DIR)] }
file mkdir $out_root
cd $out_root
set project_file [file join $out_root gba-zynq7020-hardware.xpr]
set ip_user_dir [file join $out_root gba-zynq7020-hardware.ip_user_files]

file mkdir $ip_user_dir

open_project $project_file
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY} [current_project]
update_compile_order -fileset sources_1
set_property top zynq_gba_top [current_fileset]

# Use an empty constraint set for top-only RTL checks to avoid wrapper pin
# constraints triggering false critical warnings on zynq_gba_top.
if {[llength [get_filesets -quiet constrs_syntax]] == 0} {
    create_fileset -constrset constrs_syntax
}

synth_design -rtl -top zynq_gba_top -part xc7z020clg400-1 -constrset constrs_syntax
close_project
