//------------------------------------------------------------------------------
// @file SyncRamDualByteEnable_core.sv
// @module-contract
// 职责: 带字节使能 RAM；带字节写使能的双口同步 RAM 实现，用于 Vivado RAM 推断。
// 上游: memorymux/GPU/APU 等存储实例。
// 下游: Vivado BRAM 推断。
// 时钟域: clk100/clk_core/clk_100/s_axi_aclk 等，具体以端口命名为准。
// 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
// 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
// 设计注意点: 封装可综合双口 RAM，并支持按字节写入；本注释只解释设计意图，不改变 RTL/XDC 功能。
//------------------------------------------------------------------------------
module SyncRamDualByteEnable_core #(
  parameter int BYTE_WIDTH = 8,
  parameter int ADDR_WIDTH = 6,
  parameter int BYTES = 4,
  parameter [8*11-1:0] MEMORY_PRIMITIVE = {48'b0, 8'h62, 8'h6c, 8'h6f, 8'h63, 8'h6b},
  parameter [8*11-1:0] WRITE_MODE = {8'h77, 8'h72, 8'h69, 8'h74, 8'h65, 8'h5f, 8'h66, 8'h69, 8'h72, 8'h73, 8'h74}
) (
  input  wire                           clk,
  input  wire [ADDR_WIDTH-1:0]         addr_a,
  input  wire [BYTES*BYTE_WIDTH-1:0]   datain_a,
  output wire [BYTES*BYTE_WIDTH-1:0]   dataout_a,
  input  wire                           we_a,
  input  wire [BYTES-1:0]              be_a,
  input  wire [ADDR_WIDTH-1:0]         addr_b,
  input  wire [BYTES*BYTE_WIDTH-1:0]   datain_b,
  output wire [BYTES*BYTE_WIDTH-1:0]   dataout_b,
  input  wire                           we_b,
  input  wire [BYTES-1:0]              be_b
);

  localparam int DATA_WIDTH  = BYTES * BYTE_WIDTH;
  localparam int MEMORY_SIZE = DATA_WIDTH * (1 << ADDR_WIDTH);
  // The VHDL wrapper packs its public text generics as fixed-width byte strings.
  localparam [8*11-1:0] PRIMITIVE_BEHAVIORAL =
      {8'b0, 8'h62, 8'h65, 8'h68, 8'h61, 8'h76, 8'h69, 8'h6f, 8'h72, 8'h61, 8'h6c};

  wire [BYTES-1:0] wea = we_a ? be_a : {BYTES{1'b0}};
  wire [BYTES-1:0] web = we_b ? be_b : {BYTES{1'b0}};

  function automatic [DATA_WIDTH-1:0] merge_bytes(
    input [DATA_WIDTH-1:0] old_data,
    input [DATA_WIDTH-1:0] new_data,
    input [BYTES-1:0]      byte_enable
  );
    integer lane;
    begin
      merge_bytes = old_data;
      for (lane = 0; lane < BYTES; lane = lane + 1) begin
        if (byte_enable[lane])
          merge_bytes[lane*BYTE_WIDTH +: BYTE_WIDTH] =
              new_data[lane*BYTE_WIDTH +: BYTE_WIDTH];
      end
    end
  endfunction

  // Resource and collision policy are instance parameters. Select
  // MEMORY_PRIMITIVE="behavioral" where the guest-visible contract requires
  // deterministic same-address dual-port collisions (port B wins overlapping
  // bytes); other instances keep their existing XPM mapping and WRITE_MODE.
  generate
    if (MEMORY_PRIMITIVE != PRIMITIVE_BEHAVIORAL) begin : GEN_XPM
  // 资源说明：
  // 这里把 32-bit(4x8) + byte-enable 显式映射到 XPM TDP BRAM。
  // 相比“4 个独立 8-bit RAM + 外部拼接”，这种打包方式能明显减少：
  // 1) 分散 LUTRAM 数量；2) 字节拼接/拆分 mux 逻辑；3) 复制实例带来的控制扇出。
  // 对本工程 GPU/OAM/Palette 这类高频小 RAM 场景，通常能换回大量 LUT 余量。
  // Industry practice for Vivado: use XPM memory macros for deterministic BRAM inference.
  xpm_memory_tdpram #(
    .ADDR_WIDTH_A            (ADDR_WIDTH),
    .ADDR_WIDTH_B            (ADDR_WIDTH),
    .AUTO_SLEEP_TIME         (0),
    .BYTE_WRITE_WIDTH_A      (BYTE_WIDTH),
    .BYTE_WRITE_WIDTH_B      (BYTE_WIDTH),
    .CASCADE_HEIGHT          (0),
    .CLOCKING_MODE           ("common_clock"),
    .ECC_MODE                ("no_ecc"),
    .MEMORY_INIT_FILE        ("none"),
    .MEMORY_INIT_PARAM       (""),
    .MEMORY_OPTIMIZATION     ("true"),
    .MEMORY_PRIMITIVE        (MEMORY_PRIMITIVE),
    .RAM_DECOMP              ("power"),
    .MEMORY_SIZE             (MEMORY_SIZE),
    .MESSAGE_CONTROL         (0),
    .READ_DATA_WIDTH_A       (DATA_WIDTH),
    .READ_DATA_WIDTH_B       (DATA_WIDTH),
    .READ_LATENCY_A          (1),
    .READ_LATENCY_B          (1),
    .READ_RESET_VALUE_A      ("0"),
    .READ_RESET_VALUE_B      ("0"),
    .RST_MODE_A              ("SYNC"),
    .RST_MODE_B              ("SYNC"),
    .SIM_ASSERT_CHK          (0),
    .USE_EMBEDDED_CONSTRAINT (0),
    .USE_MEM_INIT            (1),
    .WAKEUP_TIME             ("disable_sleep"),
    .WRITE_DATA_WIDTH_A      (DATA_WIDTH),
    .WRITE_DATA_WIDTH_B      (DATA_WIDTH),
    .WRITE_MODE_A            (WRITE_MODE),
    .WRITE_MODE_B            (WRITE_MODE)
  ) i_tdpram (
    .addra          (addr_a),
    .addrb          (addr_b),
    .clka           (clk),
    .clkb           (clk),
    .dina           (datain_a),
    .dinb           (datain_b),
    .douta          (dataout_a),
    .doutb          (dataout_b),
    .ena            (1'b1),
    .enb            (1'b1),
    .injectdbiterra (1'b0),
    .injectdbiterrb (1'b0),
    .injectsbiterra (1'b0),
    .injectsbiterrb (1'b0),
    .regcea         (1'b1),
    .regceb         (1'b1),
    .rsta           (1'b0),
    .rstb           (1'b0),
    .sleep          (1'b0),
    .wea            (wea),
    .web            (web),
    .dbiterra       (),
    .dbiterrb       (),
    .sbiterra       (),
    .sbiterrb       ()
  );
    end else begin : GEN_BEHAVIORAL
      reg [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH)-1];
      reg [DATA_WIDTH-1:0] douta_reg;
      reg [DATA_WIDTH-1:0] doutb_reg;
      reg [DATA_WIDTH-1:0] old_a;
      reg [DATA_WIDTH-1:0] old_b;
      reg [DATA_WIDTH-1:0] write_a;
      reg [DATA_WIDTH-1:0] write_b;
      assign dataout_a = douta_reg;
      assign dataout_b = doutb_reg;

      always @(posedge clk) begin
        old_a = mem[addr_a];
        old_b = mem[addr_b];
        write_a = merge_bytes(old_a, datain_a, wea);
        write_b = merge_bytes(old_b, datain_b, web);

        if ((|wea) && (|web) && (addr_a == addr_b)) begin
          mem[addr_a] <= merge_bytes(write_a, datain_b, web);
        end else begin
          if (|wea) mem[addr_a] <= write_a;
          if (|web) mem[addr_b] <= write_b;
        end

        if ((|wea) && (WRITE_MODE == "write_first"))
          douta_reg <= write_a;
        else if (!((|wea) && (WRITE_MODE == "no_change")))
          douta_reg <= old_a;

        if ((|web) && (WRITE_MODE == "write_first"))
          doutb_reg <= write_b;
        else if (!((|web) && (WRITE_MODE == "no_change")))
          doutb_reg <= old_b;
      end
    end
  endgenerate

endmodule
