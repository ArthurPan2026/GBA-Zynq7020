//------------------------------------------------------------------------------
// @file cdc_toggle_mailbox.sv
// @module-contract
// Purpose: reusable one-entry bundled-data CDC mailbox with back-pressure.
// Source holds a payload on an accepted src_valid/src_ready handshake. The
// request toggle crosses into the destination domain; dst_payload remains
// stable while dst_valid is asserted. The source is ready again only after the
// destination accepts dst_valid/dst_ready and the returned ack toggle crosses
// back. While src_valid is held, src_payload must stay stable until src_ready.
// With src_valid low, the producer may coalesce/update its next snapshot.
// Reset both clock domains from the same system reset epoch.
//------------------------------------------------------------------------------
module cdc_toggle_mailbox #(
  parameter int WIDTH = 32
) (
  input  logic             src_clk,
  input  logic             src_rst_n,
  input  logic             src_valid,
  input  logic [WIDTH-1:0] src_payload,
  output logic             src_ready,
  output logic             src_busy,
  output logic             src_req_toggle,
  output logic             src_ack_toggle,
  output logic [WIDTH-1:0] src_ack_payload,

  input  logic             dst_clk,
  input  logic             dst_rst_n,
  output logic             dst_valid,
  output logic [WIDTH-1:0] dst_payload,
  input  logic             dst_ready
);
  logic [WIDTH-1:0] payload_hold;
  logic             dst_ack_toggle;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ack_sync;
  (* ASYNC_REG = "TRUE" *) logic [2:0] req_sync;

  assign src_busy        = (src_req_toggle != ack_sync[1]);
  assign src_ready       = !src_busy;
  assign src_ack_toggle  = ack_sync[1];
  assign src_ack_payload = payload_hold;

  always_ff @(posedge src_clk) begin
    if (!src_rst_n) begin
      payload_hold <= '0;
      src_req_toggle <= 1'b0;
      ack_sync <= '0;
    end else begin
      ack_sync <= {ack_sync[0], dst_ack_toggle};
      if (src_valid && src_ready) begin
        payload_hold <= src_payload;
        src_req_toggle <= ~src_req_toggle;
      end
    end
  end

  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) begin
      req_sync <= '0;
      dst_ack_toggle <= 1'b0;
      dst_valid <= 1'b0;
      dst_payload <= '0;
    end else begin
      req_sync <= {req_sync[1:0], src_req_toggle};
      if (!dst_valid && (req_sync[2] != dst_ack_toggle)) begin
        // The source payload has been stable for the full request-toggle CDC
        // latency and remains held until the matching ack returns.
        dst_payload <= payload_hold;
        dst_valid <= 1'b1;
      end else if (dst_valid && dst_ready) begin
        dst_ack_toggle <= req_sync[2];
        dst_valid <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  property p_src_payload_held_while_busy;
    @(posedge src_clk) disable iff (!src_rst_n)
      src_busy |=> $stable(payload_hold);
  endproperty
  assert property (p_src_payload_held_while_busy);

  property p_dst_payload_stable_under_backpressure;
    @(posedge dst_clk) disable iff (!dst_rst_n)
      dst_valid && !dst_ready |=> dst_valid && $stable(dst_payload);
  endproperty
  assert property (p_dst_payload_stable_under_backpressure);
`endif
endmodule
