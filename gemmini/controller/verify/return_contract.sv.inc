// Environment contract from DMACommandTracker.scala:88 and :89.
always @(posedge clock) begin
  if (!reset && io_request_returned_valid) begin
    assume (io_request_returned_bits_cmd_id ? cmds_1_valid : cmds_0_valid);
    assume (io_request_returned_bits_bytes_read <=
            (io_request_returned_bits_cmd_id ? cmds_1_bytes_left : cmds_0_bytes_left));
  end
end
