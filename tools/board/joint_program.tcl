# Joint PL + PS deployment for Zybo Z7-20.
# Usage: xsct joint_program.tcl <bitstream> <ps7_init.tcl> <app.elf> <run_ms>
# Reset the PS system first, then reload the PL image, initialize the PS,
# and finally reset CPU0 before downloading the application.
if {$argc != 4} {
    error "usage: xsct joint_program.tcl <bitstream> <ps7_init.tcl> <app.elf> <run_ms>"
}
set bit_file [lindex $argv 0]
set ps_init_file [lindex $argv 1]
set elf_file [lindex $argv 2]
set run_ms [lindex $argv 3]
foreach input_file [list $bit_file $ps_init_file $elf_file] {
    if {![file exists $input_file]} {
        error "required input does not exist: $input_file"
    }
}
if {![string is integer -strict $run_ms] || $run_ms < 0} {
    error "run_ms must be a non-negative integer"
}

connect -url TCP:127.0.0.1:3121
puts "XSCT_TARGETS=[targets]"

targets -set -filter {name =~ "APU"}
puts "PS_SYSTEM_RESET_BEGIN"
rst -system
puts "PS_SYSTEM_RESET_DONE"
after 1000

targets -set -filter {name =~ "xc7z020"}
fpga $bit_file
puts "PL_CONFIGURED"

targets -set -filter {name =~ "APU"}
source $ps_init_file
ps7_init
ps7_post_config
puts "PS_INITIALIZED"

targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
rst -processor
dow $elf_file
puts "APP_ELF_DOWNLOADED"
con
puts "APP_RUNNING"
after $run_ms
puts "APP_RAN_${run_ms}MS"
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
puts "APP_PC=[rrd pc]"
puts "APP_CPSR=[rrd cpsr]"
exit
