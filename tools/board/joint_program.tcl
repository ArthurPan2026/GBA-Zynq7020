# Joint PL + PS deployment for Zybo Z7-20.
# Usage: xsct joint_program.tcl <bitstream> <ps7_init.tcl> <app.elf> <run_ms> <hw_server_url>
# Reset the PS system first, then reload the PL image, initialize the PS,
# and finally reset CPU0 before downloading the application.

if {$argc != 5} {
    error "usage: xsct joint_program.tcl <bitstream> <ps7_init.tcl> <app.elf> <run_ms> <hw_server_url>"
}
set bit_file [file normalize [lindex $argv 0]]
set ps_init_file [file normalize [lindex $argv 1]]
set elf_file [file normalize [lindex $argv 2]]
set run_ms [lindex $argv 3]
set hw_server_url [lindex $argv 4]
foreach input_file [list $bit_file $ps_init_file $elf_file] {
    if {![file isfile $input_file]} {
        error "required input does not exist: $input_file"
    }
}
if {![string is integer -strict $run_ms] || $run_ms < 0} {
    error "run_ms must be a non-negative integer"
}
if {$hw_server_url eq {}} {
    error "hw_server URL must not be empty"
}

proc select_unique_target {filter label} {
    set matches [targets -filter $filter -target-properties]
    if {[llength $matches] != 1} {
        error "$label target must match exactly one JTAG target; filter={$filter} matches=$matches"
    }
    set properties [lindex $matches 0]
    set target_id [dict get $properties target_id]
    set target_name [dict get $properties name]
    targets -set $target_id
    puts "TARGET_SELECTED $label id=$target_id name=$target_name"
    return $target_id
}

connect -url $hw_server_url
puts "XSCT_TARGETS=[targets]"

select_unique_target {name == "APU"} "APU"
puts "PS_SYSTEM_RESET_BEGIN"
rst -system
puts "PS_SYSTEM_RESET_DONE"
after 1000

select_unique_target {name =~ "xc7z020*"} "XC7Z020"
fpga $bit_file
puts "PL_CONFIGURED"

select_unique_target {name == "APU"} "APU"
source $ps_init_file
ps7_init
ps7_post_config
puts "PS_INITIALIZED"

select_unique_target {name == "ARM Cortex-A9 MPCore #0"} "CPU0"
rst -processor
dow $elf_file
puts "APP_ELF_DOWNLOADED"
con
puts "APP_RUNNING"
after $run_ms
puts "APP_RAN_[format %d $run_ms]MS"
select_unique_target {name == "ARM Cortex-A9 MPCore #0"} "CPU0"
puts "APP_PC=[rrd pc]"
puts "APP_CPSR=[rrd cpsr]"
exit
