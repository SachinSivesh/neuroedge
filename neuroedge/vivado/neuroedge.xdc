# NeuroEdge core clock: 50 MHz (EEG at 250 Hz needs far less; this sets the timing target)
create_clock -period 20.000 -name clk [get_ports clk]
