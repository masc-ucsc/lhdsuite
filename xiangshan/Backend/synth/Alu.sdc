#current_design Alu
#
# Numbers are in the time unit of the first Liberty (set_units is accepted without effect): the bench synthesizes with
# asap7 (tech/asap7, ps).

# A combinational block: a virtual clock times its input-to-output paths.
set clk_name vclk
# ps clock period: 1000 -> 1 GHz
set clk_period 1000
set clk_io_pct 0.2

create_clock -name $clk_name -period $clk_period

set_input_delay [expr $clk_period * $clk_io_pct] -clock $clk_name [all_inputs]
set_output_delay [expr $clk_period * $clk_io_pct] -clock $clk_name [all_outputs]
