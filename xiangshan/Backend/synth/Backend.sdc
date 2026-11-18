#current_design Backend
#
# Numbers are in the time unit of the first Liberty (set_units is accepted without effect): the bench synthesizes with
# asap7 (tech/asap7, ps).

set clk_name clock
# ps clock period: 1000 -> 1 GHz
set clk_period 1000
set clk_io_pct 0.2

set clk_port [get_ports $clk_name]

create_clock -name $clk_name -period $clk_period $clk_port

set non_clock_inputs [lsearch -inline -all -not -exact [all_inputs] $clk_port]

set_input_delay [expr $clk_period * $clk_io_pct] -clock $clk_name $non_clock_inputs
set_output_delay [expr $clk_period * $clk_io_pct] -clock $clk_name [all_outputs]

# Reset is not a timed path. The reset goes through ResetGen (resetGen, inner_resetGen*), a pipe_reset shift register whose output is
# `scan_mode ? !lgc_rst_n : pipe_reset[2]` (the DFT reset when dft.mode) fanned out to the reset flops. Cut it at
# every source: the reset port, the io_dft_reset ports (static in functional mode), and the pipe_reset flops.
set_false_path -from [get_ports -quiet {reset io_dft_reset*}]
set_false_path -from [get_cells -quiet {*resetGen*.pipe_reset*}]
