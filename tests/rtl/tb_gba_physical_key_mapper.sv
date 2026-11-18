`timescale 1ns/1ps
module tb_gba_physical_key_mapper;
  reg clk_core = 1'b0;
  reg rst_core_n = 1'b0;
  reg [3:0] btns = 4'b0000;
  reg [3:0] sws = 4'b0000;
  wire [9:0] physical_keys;

  gba_physical_key_mapper #(.DEBOUNCE_CYCLES(4)) dut (
    .clk_core(clk_core), .rst_core_n(rst_core_n),
    .btns(btns), .sws(sws), .physical_keys(physical_keys)
  );

  always #5 clk_core = ~clk_core;

  task automatic check_keys(input [3:0] buttons,
                            input [3:0] switches,
                            input [9:0] expected,
                            input [255:0] label);
    begin
      @(negedge clk_core);
      btns = buttons;
      sws = switches;
      repeat (8) @(posedge clk_core);
      #1;
      if (physical_keys !== expected)
        $fatal(1, "%0s: expected=%03h actual=%03h", label, expected, physical_keys);
    end
  endtask

  task automatic check_short_bounce;
    begin
      @(negedge clk_core);
      btns = 4'b0001;
      repeat (2) @(posedge clk_core);
      @(negedge clk_core);
      btns = 4'b0000;
      repeat (8) @(posedge clk_core);
      #1;
      if (physical_keys !== 10'h000)
        $fatal(1, "2-cycle BTN0 bounce must be rejected: %03h", physical_keys);
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_core);
    #1 rst_core_n = 1'b1;

    check_keys(4'b0000, 4'b0000, 10'h000, "released inputs");
    check_short_bounce();
    check_keys(4'b0001, 4'b0000, 10'h010, "stable BTN0 is Right");
    check_keys(4'b1000, 4'b0000, 10'h020, "BTN3 is Left");
    check_keys(4'b0010, 4'b0000, 10'h080, "BTN1 is Down");
    check_keys(4'b0100, 4'b0000, 10'h040, "BTN2 is Up");
    check_keys(4'b0000, 4'b1111, 10'h00F, "SW0..SW3 are A/B/Select/Start");
    check_keys(4'b1001, 4'b1000, 10'h038, "SW3 does not remap BTN0/BTN3 or assert phantom Select");
    check_keys(4'b0000, 4'b0000, 10'h000, "released inputs clear");

    $display("TEST_PASS: tb_gba_physical_key_mapper");
    $finish;
  end
endmodule
