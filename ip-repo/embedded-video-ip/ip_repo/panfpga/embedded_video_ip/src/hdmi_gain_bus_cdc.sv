`timescale 1ns/1ps
// AXI-domain gain updates cross as a stable bundled-data transaction.
// The source payload is held until the destination captures it and returns an
// acknowledgement; two data stages provide metastability settling margin.
module hdmi_gain_bus_cdc (
  input  logic        src_clk,
  input  logic        src_resetn,
  input  logic [16:0] src_gain_q15,
  input  logic        dst_clk,
  input  logic        dst_resetn,
  output logic [16:0] dst_gain_q15
);
  logic [16:0] src_gain_hold;
  logic request_toggle, acknowledge_toggle;
  logic dst_local_resetn;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic request_meta, request_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic acknowledge_meta, acknowledge_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic dst_reset_meta, dst_reset_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [16:0] gain_meta, gain_sync;
  logic dst_reset_prev, resend_gain;
  logic capture_pending;

  embedded_video_ip_reset_sync u_dst_reset_sync (
    .clk(dst_clk), .async_aresetn(dst_resetn),
    .sync_aresetn(dst_local_resetn)
  );

  always_ff @(posedge src_clk or negedge src_resetn) begin
    if (!src_resetn) begin
      src_gain_hold <= 17'd32768;
      request_toggle <= 1'b0;
      acknowledge_meta <= 1'b0;
      acknowledge_sync <= 1'b0;
      dst_reset_meta <= 1'b0;
      dst_reset_sync <= 1'b0;
      dst_reset_prev <= 1'b0;
      resend_gain <= 1'b1;
    end else begin
      acknowledge_meta <= acknowledge_toggle;
      acknowledge_sync <= acknowledge_meta;
      dst_reset_meta <= dst_local_resetn;
      dst_reset_sync <= dst_reset_meta;
      dst_reset_prev <= dst_reset_sync;
      if (dst_reset_sync && !dst_reset_prev)
        resend_gain <= 1'b1;
      if (dst_reset_sync && (acknowledge_sync == request_toggle) &&
          ((src_gain_q15 != src_gain_hold) || resend_gain)) begin
        src_gain_hold <= src_gain_q15;
        request_toggle <= ~request_toggle;
        resend_gain <= 1'b0;
      end
    end
  end

  always_ff @(posedge dst_clk or negedge dst_local_resetn) begin
    if (!dst_local_resetn) begin
      request_meta <= 1'b0;
      request_sync <= 1'b0;
      gain_meta <= 17'd32768;
      gain_sync <= 17'd32768;
      acknowledge_toggle <= 1'b0;
      capture_pending <= 1'b0;
      dst_gain_q15 <= 17'd32768;
    end else begin
      request_meta <= request_toggle;
      request_sync <= request_meta;
      gain_meta <= src_gain_hold;
      gain_sync <= gain_meta;
      if (capture_pending) begin
        dst_gain_q15 <= gain_sync;
        acknowledge_toggle <= request_sync;
        capture_pending <= 1'b0;
      end else if (request_sync != acknowledge_toggle) begin
        // Wait one extra local cycle after synchronized request before capture.
        capture_pending <= 1'b1;
      end
    end
  end
endmodule
