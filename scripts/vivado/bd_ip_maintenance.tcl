# Build helpers operate on copies under build/vivado; source BD snapshots are read-only.
proc xci_files_in_dir {ip_dir} {
    set xcis {}
    if {![file isdirectory $ip_dir]} {
        return $xcis
    }

    foreach inst_dir [glob -nocomplain -types d -directory $ip_dir *] {
        foreach xci [glob -nocomplain -types f -directory $inst_dir *.xci] {
            lappend xcis $xci
        }
    }
    return $xcis
}

proc normalize_xci_shareddir {ip_dir} {
    if {![file isdirectory $ip_dir]} {
        return 0
    }

    set rewritten 0
    foreach xci [xci_files_in_dir $ip_dir] {
        if {[catch {set fh [open $xci r]}]} {
            continue
        }
        set content [read $fh]
        close $fh

        set original $content
        regsub -all {("SHAREDDIR"[ \t\r\n]*:[ \t\r\n]*\[[ \t\r\n]*\{[ \t\r\n]*"value"[ \t\r\n]*:[ \t\r\n]*")[^"]*("[ \t\r\n]*\}[ \t\r\n]*\],?)} $content {\1../../ipshared\2} content

        if {$content ne $original} {
            set out [open $xci w]
            puts -nonewline $out $content
            close $out
            incr rewritten
        }
    }

    return $rewritten
}
