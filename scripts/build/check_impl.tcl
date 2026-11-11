set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set out_root [file normalize [file join $repo_root out vivado]]
if {[info exists ::env(ZYNQ_GBA_OUT_DIR)]} { set out_root [file normalize $::env(ZYNQ_GBA_OUT_DIR)] }
file mkdir $out_root
cd $out_root
set project_file [file join $out_root Zynq-GBA_MisTer-Vivado.xpr]
set project_name "Zynq-GBA_MisTer-Vivado"


open_project $project_file
set bd [get_files -all *zynq_gba_system.bd]
reset_target all $bd
generate_target all $bd
export_ip_user_files -of_objects $bd -no_script -sync -force
set_param general.maxThreads 8
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY} [current_project]
update_compile_order -fileset sources_1
reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
close_project
