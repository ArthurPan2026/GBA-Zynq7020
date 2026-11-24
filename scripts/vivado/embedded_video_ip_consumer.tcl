# Resolve the package identity from the verified canonical release lock.
# Keep application geometry and source policy in this consumer repository.
set evip_lock_file [file normalize [file join [file dirname [info script]] ../../ip-repo/embedded-video-ip-DEPENDENCY-LOCK.json]]
if {![file isfile $evip_lock_file]} {
    error "EmbeddedVideoIP dependency lock is missing: $evip_lock_file"
}
set evip_lock_fd [open $evip_lock_file r]
set evip_lock_text [read $evip_lock_fd]
close $evip_lock_fd
if {![regexp {"version"\s*:\s*"([^"]+)"} $evip_lock_text -> evip_expected_version]} {
    error "EmbeddedVideoIP dependency lock has no version"
}
if {![regexp {"vlnv"\s*:\s*"([^"]+)"} $evip_lock_text -> evip_vlnv]} {
    error "EmbeddedVideoIP dependency lock has no VLNV"
}
set evip_modes_file [file join [file dirname [info script]] ../../src/ps/app/src/Video/Inc/video_modes.def]
set evip_modes_fd [open $evip_modes_file r]
set evip_max_input_width 0
set evip_max_input_height 0
while {[gets $evip_modes_fd evip_mode_line] >= 0} {
    if {[regexp {^GBA_VIDEO_MODE\([A-Z0-9]+, ([0-9]+), ([0-9]+), [0-9]+, [0-9]+, [0-9]+\)$} $evip_mode_line -> w h]} {
        set evip_max_input_width [expr {max($evip_max_input_width, $w)}]
        set evip_max_input_height [expr {max($evip_max_input_height, $h)}]
    } elseif {[string match {GBA_VIDEO_MODE*} $evip_mode_line]} {
        error "Invalid video mode: $evip_mode_line"
    }
}
close $evip_modes_fd
if {$evip_max_input_width == 0 || $evip_max_input_height == 0} {
    error "No video modes in $evip_modes_file"
}
set evip_enable_bram_source 0
set evip_enable_hls_source 0
set evip_enable_vdma_source 1
set evip_source_select_mode 1
set evip_fixed_source 2
set evip_format_select_mode 1
set evip_fixed_format 2
set evip_max_scaler_width 1280
set evip_max_scaler_height 720
# PS produces output-sized frames for both the native UI and GBA viewport.
set evip_enable_scaler 0
set evip_line_buffer_implementation 1
set evip_enable_hdmi_audio 1
set evip_control_offset 0x43010000
