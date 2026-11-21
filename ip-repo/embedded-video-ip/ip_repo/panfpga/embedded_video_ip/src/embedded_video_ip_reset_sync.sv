`timescale 1ns/1ps
// 异步置位、同步释放的复位同步器。
module embedded_video_ip_reset_sync (
  input  logic clk,
  input  logic async_aresetn,
  output logic sync_aresetn
);
  (* ASYNC_REG = "TRUE" *) logic [1:0] release_pipe;
  always_ff @(posedge clk or negedge async_aresetn) begin
    if (!async_aresetn)
      release_pipe <= 2'b00;
    else
      release_pipe <= {release_pipe[0], 1'b1};
  end
  assign sync_aresetn = release_pipe[1];
endmodule
