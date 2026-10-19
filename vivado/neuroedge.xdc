# NeuroEdge core clock: 40 MHz (50 MHz misses by 3.5 ns in ns_calib) (EEG at 250 Hz needs far less; this sets the timing target)
create_clock -period 25.000 -name clk [get_ports clk]
