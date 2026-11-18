#current_design Rob
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

# Reset is not a timed path. It reaches the flops straight from the port.
set_false_path -from [get_ports {reset}]
