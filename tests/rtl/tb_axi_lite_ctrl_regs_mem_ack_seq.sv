`timescale 1ns/1ps

module tb_axi_lite_ctrl_regs_mem_ack_seq;
  localparam logic [11:0] REG_MEM_CMD = 12'h210;
  localparam logic [11:0] REG_MEM_CMD_SEQ = 12'h214;
  localparam logic [11:0] REG_MEM_CMD_REQ_TOGGLE = 12'h218;
  localparam logic [11:0] REG_MEM_CMD_ACK_SEQ = 12'h21C;
  localparam logic [31:0] CMD_RESUME = 32'h00000004;
  localparam logic [31:0] CMD_SEQUENCE = 32'h00000003;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [11:0] s_axi_awaddr = 12'd0;
  logic s_axi_awvalid = 1'b0;
  wire s_axi_awready;
  logic [31:0] s_axi_wdata = 32'd0;
  logic [3:0] s_axi_wstrb = 4'hF;
  logic s_axi_wvalid = 1'b0;
  wire s_axi_wready;
  wire [1:0] s_axi_bresp;
  wire s_axi_bvalid;
  logic s_axi_bready = 1'b0;

  logic [11:0] s_axi_araddr = 12'd0;
  logic s_axi_arvalid = 1'b0;
  wire s_axi_arready;
  wire [31:0] s_axi_rdata;
  wire [1:0] s_axi_rresp;
  wire s_axi_rvalid;
  logic s_axi_rready = 1'b0;

  wire mem_cmd_src_valid;
  wire [63:0] mem_cmd_src_payload;
  logic mem_cmd_src_ready = 1'b1;
  logic mem_cmd_src_req_toggle = 1'b0;
  logic mem_cmd_src_ack_toggle = 1'b0;
  logic [63:0] mem_cmd_src_ack_payload = 64'd0;

  logic [63:0] pending_payload = 64'd0;
  logic mailbox_pending = 1'b0;
  integer ack_delay = 0;
  logic [31:0] ack_seq_readback;
  logic test_done = 1'b0;

  axi_lite_ctrl_regs dut (
    .clk(clk),
    .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .mem_cmd_src_valid(mem_cmd_src_valid),
    .mem_cmd_src_payload(mem_cmd_src_payload),
    .mem_cmd_src_ready(mem_cmd_src_ready),
    .mem_cmd_src_req_toggle(mem_cmd_src_req_toggle),
    .mem_cmd_src_ack_toggle(mem_cmd_src_ack_toggle),
    .mem_cmd_src_ack_payload(mem_cmd_src_ack_payload),
    .bios_wr_src_ack_toggle(1'b0)
  );

  // Model the mailbox echo response with the same {sequence, command} payload.
  always @(posedge clk) begin
    if (!rst_n) begin
      pending_payload <= 64'd0;
      mailbox_pending <= 1'b0;
      ack_delay <= 0;
      mem_cmd_src_req_toggle <= 1'b0;
      mem_cmd_src_ack_toggle <= 1'b0;
      mem_cmd_src_ack_payload <= 64'd0;
    end else begin
      if (mem_cmd_src_valid && mem_cmd_src_ready) begin
        if (mailbox_pending) $fatal(1, "TEST_FAIL: mailbox accepted a second command");
        pending_payload <= mem_cmd_src_payload;
        mem_cmd_src_req_toggle <= ~mem_cmd_src_req_toggle;
        mailbox_pending <= 1'b1;
        ack_delay <= 3;
      end else if (mailbox_pending) begin
        if (ack_delay == 0) begin
          mem_cmd_src_ack_payload <= pending_payload;
          mem_cmd_src_ack_toggle <= mem_cmd_src_req_toggle;
          mailbox_pending <= 1'b0;
        end else begin
          ack_delay <= ack_delay - 1;
        end
      end
    end
  end

  task automatic axi_write(input logic [11:0] address,
                           input logic [31:0] value);
    begin
      @(negedge clk);
      s_axi_awaddr = address;
      s_axi_awvalid = 1'b1;
      wait (s_axi_awready);
      @(posedge clk);
      @(negedge clk);
      s_axi_awvalid = 1'b0;
      s_axi_wdata = value;
      s_axi_wvalid = 1'b1;
      wait (s_axi_wready);
      @(posedge clk);
      @(negedge clk);
      s_axi_wvalid = 1'b0;
      s_axi_bready = 1'b1;
      wait (s_axi_bvalid);
      @(posedge clk);
      @(negedge clk);
      s_axi_bready = 1'b0;
    end
  endtask

  task automatic axi_read(input logic [11:0] address,
                          output logic [31:0] value);
    begin
      @(negedge clk);
      s_axi_araddr = address;
      s_axi_arvalid = 1'b1;
      wait (s_axi_arready);
      @(posedge clk);
      @(negedge clk);
      s_axi_arvalid = 1'b0;
      s_axi_rready = 1'b1;
      wait (s_axi_rvalid);
      value = s_axi_rdata;
      @(posedge clk);
      @(negedge clk);
      s_axi_rready = 1'b0;
    end
  endtask

  initial begin
    #100us;
    if (!test_done) $fatal(1, "TEST_FAIL watchdog timeout: tb_axi_lite_ctrl_regs_mem_ack_seq");
  end

  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // RESUME is command 4 with sequence 3; ACK_SEQ must return the sequence.
    axi_write(REG_MEM_CMD, CMD_RESUME);
    axi_write(REG_MEM_CMD_SEQ, CMD_SEQUENCE);
    axi_write(REG_MEM_CMD_REQ_TOGGLE, 32'd1);

    wait (!mailbox_pending);
    repeat (2) @(negedge clk);
    if (pending_payload !== {CMD_SEQUENCE, CMD_RESUME})
      $fatal(1, "TEST_FAIL: mailbox payload order changed: %016x", pending_payload);

    axi_read(REG_MEM_CMD_ACK_SEQ, ack_seq_readback);
    if (ack_seq_readback !== CMD_SEQUENCE)
      $fatal(1, "TEST_FAIL: ACK_SEQ=%0d, expected sequence=%0d (command=%0d)",
             ack_seq_readback, CMD_SEQUENCE, CMD_RESUME);

    test_done = 1'b1;
    $display("TEST_PASS: tb_axi_lite_ctrl_regs_mem_ack_seq");
    $finish;
  end
endmodule

