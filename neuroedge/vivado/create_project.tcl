# =============================================================================
# Create a Vivado 2016 project for NeuroEdge (for browsing the design,
# schematics and running synthesis from the GUI).
#
# Vivado start page -> Tcl Console at the bottom, then:
#     cd C:/path/to/neuroedge/vivado
#     source create_project.tcl
# The project is created in vivado/neuroedge/.
# =============================================================================
set root [file normalize [file join [file dirname [info script]] ..]]
set inc  [file join $root rtl params]

create_project neuroedge [file join $root vivado neuroedge] -part xc7z020clg484-1 -force

add_files -norecurse [glob [file join $root rtl *.v]]
add_files -norecurse [glob [file join $inc *.vh]]
set_property file_type {Verilog Header} [get_files *.vh]
set_property include_dirs $inc [get_filesets sources_1]
set_property top neuroedge_top [get_filesets sources_1]
add_files -fileset constrs_1 -norecurse [file join $root vivado neuroedge.xdc]

# measure the core on its own (no I/O pins)
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]

puts "Project created. Flow Navigator -> Run Synthesis (simulation: use sim/run_xsim.bat)."
