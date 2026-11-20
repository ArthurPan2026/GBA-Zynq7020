set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
set out_root [file normalize [file join $repo_root build vivado hardware]]
if {[info exists ::env(ZYNQ_GBA_OUT_DIR)]} { set out_root [file normalize $::env(ZYNQ_GBA_OUT_DIR)] }
file mkdir $out_root
cd $out_root
set project_file [file join $out_root gba-zynq7020-hardware.xpr]

open_project $project_file
# Keep compile order current and load lint-only stubs for missing Intel primitives.
update_compile_order -fileset sources_1
read_verilog [file join $repo_root scripts lint cyclonev_hps_stubs.v]

foreach pat [list \
	*src/rtl/gba-core/rtl/SyncFifo.vhd \
	*src/rtl/gba-core/rtl/SyncRam.vhd \
	*src/rtl/gba-core/rtl/SyncRamDual.vhd \
	*src/rtl/gba-core/rtl/SyncRamDualByteEnable.vhd \
	*src/rtl/gba-core/rtl/SyncRamDualNotPow2.vhd
] {
	set f [get_files -of_objects [get_filesets sources_1] $pat]
	if {[llength $f] > 0} {
		set_property library mem $f
	}
}

update_compile_order -fileset sources_1

set linter_top [get_property top [get_filesets sources_1]]
if {$linter_top eq ""} {
	set linter_top zynq_gba_system_wrapper
}

synth_design -rtl -name rtl_1 -top $linter_top -part xc7z020clg400-1
report_methodology -file linter_report.txt
report_drc -file drc_precheck.txt

close_project
