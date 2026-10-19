# =============================================================================
# NeuroEdge helper commands for the Vivado Tcl Console (loaded by
# create_project.tcl; with the project open you can also run
#     source E:/BCI-Project/neuroedge/vivado/ne_commands.tcl ).
#
#   ne_test tb_iir     run one testbench in the batch simulator, print PASS/FAIL
#   ne_test_all        run all five, print a summary
#   ne_wave tb_top     open one testbench in the GUI simulator (waveforms);
#                      close it yourself with File > Close Simulation
#   ne_reports         synthesis + implementation + utilization/timing/power
#
# ne_test does not use the GUI simulator: Vivado 2016 can hang when a script
# opens and closes several GUI simulations in a row.
# =============================================================================
set ::ne_root [file normalize [file join [file dirname [info script]] ..]]

proc ne_xv {tool} {
    # Vivado's own tools, from the running Vivado install (XILINX_VIVADO is set by Vivado)
    return [file join $::env(XILINX_VIVADO) bin $tool.bat]
}

proc ne_test {tb} {
    set sim [file join $::ne_root sim]
    set log [file join $sim log_$tb.txt]
    puts "Running $tb in the batch simulator (tb_top takes a few minutes)..."
    update
    set rtl {}
    foreach f {iir_bandpass event_encoder event_cov drift_monitor backend ns_calib neuroedge_top} {
        lappend rtl ../rtl/$f.v
    }
    set old [pwd]
    cd $sim
    set out ""
    set steps [list \
        [list [ne_xv xvlog] -m64 --relax -i ../rtl/params {*}$rtl ../tb/$tb.v] \
        [list [ne_xv xelab] -m64 --relax --debug typical $tb -s ${tb}_sim] \
        [list [ne_xv xsim] ${tb}_sim -R]]
    foreach step $steps {
        set rc [catch {exec {*}$step 2>@1} res]
        append out "\n>>> [file tail [lindex $step 0]]\n$res\n"
        if {$rc && [string match "*ERROR*" $res]} { break }
    }
    cd $old
    set fh [open $log w]; puts $fh $out; close $fh
    set verdict "no PASS/FAIL line -- open $log"
    foreach line [split $out "\n"] {
        set l [string trim $line]
        if {[string match "PASS*" $l] || [string match "FAIL*" $l]} { set verdict $l }
    }
    if {![string match "PASS*" $verdict] && [string match "*ERROR:*" $out]} {
        set verdict "ERROR -- open $log"
    }
    puts "################ $tb: $verdict"
    return $verdict
}

proc ne_test_all {} {
    set out {}
    foreach tb {tb_iir tb_encoder tb_event_cov tb_ns tb_top} {
        lappend out "$tb: [ne_test $tb]"
    }
    puts "\n========== NeuroEdge testbench summary =========="
    foreach line $out { puts $line }
    puts "================================================="
}

proc ne_wave {tb} {
    set_property top $tb [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    puts "Waveforms open for $tb. Close with File > Close Simulation before running another."
}

proc ne_reports {} {
    set out [file join $::ne_root results]
    file mkdir $out
    reset_run synth_1
    launch_runs impl_1 -jobs 4
    wait_on_run impl_1
    open_run impl_1
    report_utilization    -file [file join $out vivado_utilization.txt]
    report_timing_summary -file [file join $out vivado_timing.txt]
    report_power          -file [file join $out vivado_power.txt]
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "\n================================================================"
    puts " Worst setup slack at 40 MHz: $wns ns  (positive = timing met)"
    puts " Reports written to $out"
    puts "================================================================"
}

puts "NeuroEdge commands loaded: ne_test_all, ne_test <tb>, ne_wave <tb>, ne_reports"
