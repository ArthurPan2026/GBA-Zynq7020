module tb_ddram_mux_burst_boundary;
  logic [27:1] addr;
  logic [7:0] burst;
  logic [7:0] got;
  logic [7:0] expected;
  integer line;
  integer kind;
  integer total;
  integer beats;

  // The pure helper is called hierarchically. Other ports are intentionally
  // unconnected because this test exercises only the burst-boundary function.
  ddram_mux dut (.DDRAM_CLK(1'b0), .rst_n(1'b1));

  initial begin
    total = 0;
    for (line = 0; line < 512; line = line + 1) begin
      addr = '0;
      addr[11:3] = line[8:0];
      for (kind = 0; kind < 3; kind = kind + 1) begin
        case (kind)
          0: burst = 8'd1;
          1: burst = 8'd2;
          default: burst = 8'd4;
        endcase
        beats = 512 - line;
        expected = (beats < burst) ? beats[7:0] : burst;
        got = dut.clamp_burst_4k(addr, burst);
        if (got !== expected) begin
          $fatal(1, "TEST_FAIL: line=%0d burst=%0d got=%0d expected=%0d",
                 line, burst, got, expected);
        end
        if (got == 0 || got > burst || (line + got) > 512) begin
          $fatal(1, "TEST_FAIL: page crossing line=%0d burst=%0d got=%0d",
                 line, burst, got);
        end
        total = total + 1;
      end
    end

    $display("TEST_PASS: tb_ddram_mux_burst_boundary checks=%0d", total);
    $finish;
  end
endmodule
