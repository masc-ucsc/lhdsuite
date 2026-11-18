#current_design minion_top
#
# Numbers are in the time unit of the first Liberty (set_units is accepted without effect): the bench synthesizes with
# asap7 (tech/asap7, ps).

set clk_name clk_i
# ps clock period: 1000 -> 1 GHz
set clk_period 1000
set clk_io_pct 0.2

set clk_port [get_ports $clk_name]

create_clock -name $clk_name -period $clk_period $clk_port

set non_clock_inputs [lsearch -inline -all -not -exact [all_inputs] $clk_port]

set_input_delay [expr $clk_period * $clk_io_pct] -clock $clk_name $non_clock_inputs
set_output_delay [expr $clk_period * $clk_io_pct] -clock $clk_name [all_outputs]

# Reset is not a timed path. The three asynchronous active-low resets go through prim_rst_sync (u_rst_sync_{c,d,w}), whose output is
# `scanmode ? scan_reset_n : rst_q` fanned out to every reset flop. Cut it at every source of that mux: the reset
# ports, the DFT scan-mode/scan-reset ports (static in functional mode), and the synchronizer flops.
set_false_path -from [get_ports {rst_c_ni rst_d_ni rst_w_ni dft_i.scanmode dft_i.scan_reset_n}]
set_false_path -from [get_cells {u_rst_sync_c.rst_q u_rst_sync_d.rst_q u_rst_sync_w.rst_q}]
