set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set out_root [file normalize [file join $repo_root build]]
if {[info exists ::env(ZYNQ_GBA_OUT_DIR)]} { set out_root [file normalize $::env(ZYNQ_GBA_OUT_DIR)] }
file mkdir $out_root
cd $out_root
set project_file [file join $repo_root vivado/gba-zynq7020.xpr]
set xsa_file [file join $out_root zynq_gba_system_wrapper.xsa]
set project_name "gba-zynq7020"


open_project $project_file
open_run impl_1
if {[file exists $xsa_file]} { file delete -force $xsa_file }
write_hw_platform -fixed -include_bit -force -file $xsa_file
close_project
exit
