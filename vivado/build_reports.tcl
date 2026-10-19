# =============================================================================
# Synthesise, place and route the NeuroEdge core for the Zynq-7020 (ZedBoard
# part) and write the reports the paper needs. Out-of-context build: the core
# is measured on its own, without I/O pins.
#
# Run from the Vivado 2016 Tcl Shell (Start menu):
#     cd C:/path/to/neuroedge/vivado
#     source build_reports.tcl
# or from cmd:  vivado -mode batch -source build_reports.tcl
#
# Writes results/vivado_utilization.txt, vivado_timing.txt, vivado_power.txt
# =============================================================================
set root    [file normalize [file join [file dirname [info script]] ..]]
set part    xc7z020clg484-1
set out     [file join $root results]
file mkdir $out

read_verilog [glob [file join $root rtl *.v]]
read_xdc [file join $root vivado neuroedge.xdc]

synth_design -top neuroedge_top -part $part -mode out_of_context \
             -include_dirs [file join $root rtl params]
opt_design
place_design
route_design

report_utilization    -file [file join $out vivado_utilization.txt]
report_timing_summary -file [file join $out vivado_timing.txt]
report_power          -file [file join $out vivado_power.txt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "================================================================"
puts " NeuroEdge on $part"
puts " Worst setup slack at 40 MHz: $wns ns  (positive = timing met)"
puts " Reports written to $out"
puts "================================================================"
