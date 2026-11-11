//------------------------------------------------------------------------------
// @file zynq_gba_top.v
// @module-contract
// 职责: PL 集成顶层；Zynq PS/PL 集成顶层，汇聚 AXI 控制、DDR 访问、GBA 核心、帧缓存、音频和中断接口。
// 上游: PS AXI 控制寄存器、板级 GPIO、PS DDR AXI HP 口。
// 下游: gba_config_mgr、axi_lite_ctrl_regs、ddram_mux、ddr_axi_backend、GBA core、帧缓存和音频发送器。
// 时钟域: clk100/clk_core/clk_100/s_axi_aclk 等，具体以端口命名为准。
// 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
// 关键协议: 内部 DDRAM 请求/ready、读数据有效、突发长度和预取命中共同决定一次访问何时完成。
// 设计注意点: 把 PS 软件配置翻译成 core 输入，把 core 的 ROM/存档/帧/音频/调试数据送往 DDR、BRAM、I2S 和 IRQ；本注释只解释设计意图，不改变 RTL/XDC 功能。
//------------------------------------------------------------------------------
`include "../common/ps_pl_contract_generated.vh"

module zynq_gba_top #(
  parameter [31:0] G_DDR_BASE = 32'h1000_0000,
  parameter         G_ENABLE_DEBUG = 1'b0
) (
  // Clock and Reset Interfaces
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_100 CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXI, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
  input         clk_100,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input         rst_n,

  // AXI4-Lite slave (PS -> PL control)
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 50000000" *)
  input         s_axi_aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input         s_axi_aresetn,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
  input [11:0]  s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
  input [2:0]   s_axi_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
  input         s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
  output        s_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
  input [31:0]  s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
  input [3:0]   s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
  input         s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
  output        s_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
  output [1:0]  s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
  output        s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
  input         s_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
  input [11:0]  s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
  input [2:0]   s_axi_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
  input         s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
  output        s_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
  output [31:0] s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
  output [1:0]  s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
  output        s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
  input         s_axi_rready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 fb_cap_bram CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME fb_cap_bram, MASTER_TYPE BRAM_CTRL, MEM_SIZE 262144, MEM_WIDTH 32, MEM_ECC NONE, READ_WRITE_MODE READ_WRITE" *)
  input         fb_cap_bram_clk,
  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 fb_cap_bram RST" *)
  input         fb_cap_bram_rst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 fb_cap_bram EN" *)
  input         fb_cap_bram_en,
  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 fb_cap_bram WE" *)
  input [3:0]   fb_cap_bram_we,
  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 fb_cap_bram ADDR" *)
  input [17:0]  fb_cap_bram_addr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 fb_cap_bram DIN" *)
  input [31:0]  fb_cap_bram_din,
  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 fb_cap_bram DOUT" *)
  output [31:0] fb_cap_bram_dout,

  // AXI4 master to PS DDR
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
  output [31:0]  M_AXI_AWADDR,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
  output [7:0]   M_AXI_AWLEN,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
  output [2:0]   M_AXI_AWSIZE,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
  output [1:0]   M_AXI_AWBURST,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
  output         M_AXI_AWVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
  input          M_AXI_AWREADY,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
  output [63:0]  M_AXI_WDATA,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
  output [7:0]   M_AXI_WSTRB,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
  output         M_AXI_WLAST,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
  output         M_AXI_WVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
  input          M_AXI_WREADY,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
  input [1:0]    M_AXI_BRESP,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
  input          M_AXI_BVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
  output         M_AXI_BREADY,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
  output [31:0]  M_AXI_ARADDR,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
  output [7:0]   M_AXI_ARLEN,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
  output [2:0]   M_AXI_ARSIZE,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
  output [1:0]   M_AXI_ARBURST,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
  output         M_AXI_ARVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
  input          M_AXI_ARREADY,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
  input [63:0]   M_AXI_RDATA,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
  input [1:0]    M_AXI_RRESP,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
  input          M_AXI_RLAST,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
  input          M_AXI_RVALID,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
  output         M_AXI_RREADY,

  // Audio Codec Interface (I2S)
  output        ac_bclk,
  output        ac_mclk,
  output        ac_muten,
  output        ac_pbdat,
  output        ac_pblrc,

  // Board Physical I/O
  input  [3:0]  btns,
  input  [3:0]  sws,
  output [3:0]  leds,

  // PL-to-PS Interrupt
  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
  (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
  output        irq
);

  // ==========================================================================
  // --- 内部布线与中间信号 (Interconnects) ---
  // ==========================================================================
  
  // 1. 系统配置信号 (Synchronized)
  wire [31:0] w_core_cfg_ctrl;
  wire [9:0]  w_core_cfg_keys;
  wire [9:0]  w_core_physical_keys;
  wire [24:0] w_core_cfg_max_pak_addr;
  wire [15:0] w_core_cfg_cycle_precalc;
  wire [31:0] w_core_cfg_rtc_timestamp;
  wire [31:0] w_core_cfg_rtc_timestamp_saved;
  wire [5:0]  w_core_feature_ctrl;
  wire [2:0]  w_core_savestate_slot;
  wire [31:0] w_core_cheat_flags;
  wire [31:0] w_core_cheat_addr;
  wire [31:0] w_core_cheat_compare;
  wire [31:0] w_core_cheat_replace;
  wire [2:0]  w_core_sensor_solar;
  wire signed [7:0] w_core_sensor_tilt_x;
  wire signed [7:0] w_core_sensor_tilt_y;
  wire [41:0] w_core_rtc_savedtime;
  wire        w_core_rtc_save_loaded;
  wire        w_core_pulse_save_state;
  wire        w_core_pulse_load_state;
  wire        w_core_pulse_cheat_push;
  wire        w_core_pulse_cheat_clear;
  wire        w_core_pulse_rtc_new;
  wire        w_core_rewind_active;
  wire        w_core_rom_ddr_safe;

  // 2. AXI 寄存器到系统控制器的接口
  wire [31:0] w_axi_cfg_ctrl;
  wire [9:0]  w_axi_cfg_keys;
  wire [24:0] w_axi_cfg_max_pak_addr;
  wire [15:0] w_axi_cfg_cycle_precalc;
  wire [31:0] w_axi_cfg_rtc_timestamp;
  wire [31:0] w_axi_cfg_rtc_timestamp_saved;
  wire [1:0]  w_axi_display_frame_idx;
  wire        w_axi_cfg_commit_toggle;
  wire        w_axi_cfg_sw_reset;
  wire [11:0] w_axi_bios_wr_addr;
  wire [31:0] w_axi_bios_wr_data;
  wire        w_axi_bios_wr_req_toggle;
  wire        bios_wr_src_valid, bios_wr_src_ready, bios_wr_src_busy;
  wire [43:0] bios_wr_src_payload, bios_wr_src_ack_payload;
  wire        bios_wr_src_req_toggle, bios_wr_src_ack_toggle;
  wire        bios_wr_dst_valid, bios_wr_dst_ready;
  wire [43:0] bios_wr_dst_payload;
  wire [5:0]  w_axi_feature_ctrl;
  wire        w_axi_feature_action_save_toggle;
  wire        w_axi_feature_action_load_toggle;
  wire        w_axi_feature_action_cheat_push_toggle;
  wire        w_axi_feature_action_cheat_clear_toggle;
  wire        w_axi_feature_action_rtc_new_toggle;
  wire [2:0]  w_axi_savestate_slot;
  wire [31:0] w_axi_cheat_flags;
  wire [31:0] w_axi_cheat_addr;
  wire [31:0] w_axi_cheat_compare;
  wire [31:0] w_axi_cheat_replace;
  wire [23:0] w_axi_sensor_input;
  wire [31:0] w_axi_rtc_in_savedtime_lo;
  wire [31:0] w_axi_rtc_in_savedtime_hi;

  // Request/response bundles use reusable one-entry CDC mailboxes. Each owner
  // holds its payload until the destination acknowledges the operation.
  wire        mem_cmd_src_valid, mem_cmd_src_ready, mem_cmd_src_busy;
  wire [63:0] mem_cmd_src_payload, mem_cmd_src_ack_payload;
  wire        mem_cmd_src_req_toggle, mem_cmd_src_ack_toggle;
  wire        mem_cmd_dst_valid, mem_cmd_dst_ready;
  wire [63:0] mem_cmd_dst_payload;
  wire        frame_snap_src_valid, frame_snap_src_ready, frame_snap_src_busy;
  wire [31:0] frame_snap_src_payload, frame_snap_src_ack_payload;
  wire        frame_snap_src_req_toggle, frame_snap_src_ack_toggle;
  wire        frame_snap_dst_valid, frame_snap_dst_ready;
  wire [31:0] frame_snap_dst_payload;
  wire        save_snap_src_valid, save_snap_src_ready, save_snap_src_busy;
  wire [31:0] save_snap_src_payload, save_snap_src_ack_payload;
  wire        save_snap_src_req_toggle, save_snap_src_ack_toggle;
  wire        save_snap_dst_valid, save_snap_dst_ready;
  wire [31:0] save_snap_dst_payload;
  wire        save_ack_src_valid, save_ack_src_ready, save_ack_src_busy;
  wire [65:0] save_ack_src_payload, save_ack_src_ack_payload;
  wire        save_ack_src_req_toggle, save_ack_src_ack_toggle;
  wire        save_ack_dst_valid, save_ack_dst_ready;
  wire [65:0] save_ack_dst_payload;

  wire [4:0]  mem_status_core;
  wire [3:0]  mem_error_core;
  wire [27:0] mem_error_addr_core;
  wire [31:0] rom_epoch_core;

  wire [31:0] frame_status_core;
  wire [31:0] frame_bank0_gen_core;
  wire [31:0] frame_bank1_gen_core;
  reg [31:0] frame_snap_status_core;
  reg [31:0] frame_snap_seq_core;
  reg [31:0] frame_snap_bank0_gen_core;
  reg [31:0] frame_snap_bank1_gen_core;
  reg [31:0] frame_snap_rom_epoch_core;

  reg [31:0] save_sram_gen_core;
  reg [31:0] save_flash_gen_core;
  reg [31:0] save_eeprom_gen_core;
  reg        save_sram_dirty_core;
  reg        save_flash_dirty_core;
  reg        save_eeprom_dirty_core;
  reg [2:0]  save_sram_busy_count_core;
  reg [2:0]  save_flash_busy_count_core;
  reg [2:0]  save_eeprom_busy_count_core;
  reg [1:0]  save_kind_fifo [0:3];
  reg [1:0]  save_kind_fifo_wr_ptr;
  reg [1:0]  save_kind_fifo_rd_ptr;
  reg [2:0]  save_kind_fifo_count;
  integer save_fifo_index;
  reg [31:0] save_snap_counters_core;
  reg [31:0] save_snap_status_core;
  reg [31:0] save_snap_sram_gen_core;
  reg [31:0] save_snap_flash_gen_core;
  reg [31:0] save_snap_eeprom_gen_core;
  localparam integer DEBUG_SNAPSHOT_WORDS = 84;
  localparam integer DEBUG_SNAPSHOT_WIDTH = DEBUG_SNAPSHOT_WORDS * 32;
  wire [DEBUG_SNAPSHOT_WIDTH-1:0] debug_snapshot_source_payload;
  reg debug_snapshot_pending_core;
  wire debug_snapshot_src_valid;
  wire debug_snapshot_src_ready;
  wire debug_snapshot_src_busy;
  wire debug_snapshot_src_req_toggle;
  wire debug_snapshot_src_ack_toggle;
  wire [DEBUG_SNAPSHOT_WIDTH-1:0] debug_snapshot_src_ack_payload;
  wire debug_snapshot_dst_valid;
  wire [DEBUG_SNAPSHOT_WIDTH-1:0] debug_snapshot_dst_payload;
  wire debug_snapshot_dst_ready;
  reg [68:0] mem_diag_seen_core;
  reg [9:0] physical_keys_seen_core;
  wire physical_keys_changed = (w_core_physical_keys != physical_keys_seen_core);
  wire [68:0] mem_diag_current = {mem_status_core, mem_error_core,
                                  mem_error_addr_core, rom_epoch_core};
  wire mem_diag_changed = (mem_diag_current != mem_diag_seen_core);
  wire [4:0] mem_status_axi_snapshot;
  wire [3:0] mem_error_axi_snapshot;
  wire [27:0] mem_error_addr_axi_snapshot;
  wire [31:0] rom_epoch_axi_snapshot;
  wire [13:0] debug_snapshot_cycles_missing;
  wire [15:0] debug_snapshot_cycles_vsync;
  wire [1:0] debug_snapshot_frame_idx;
  wire [9:0] debug_snapshot_physical_keys;
  wire [31:0] debug_snapshot_save_status;
  wire [31:0] save_snap_status_live =
      (save_sram_dirty_core ? `PS_PL_SAVE_STATUS_DIRTY_SRAM : 32'd0) |
      (save_flash_dirty_core ? `PS_PL_SAVE_STATUS_DIRTY_FLASH : 32'd0) |
      (save_eeprom_dirty_core ? `PS_PL_SAVE_STATUS_DIRTY_EEPROM : 32'd0) |
      ((save_sram_busy_count_core != 0) ? `PS_PL_SAVE_STATUS_BUSY_SRAM : 32'd0) |
      ((save_flash_busy_count_core != 0) ? `PS_PL_SAVE_STATUS_BUSY_FLASH : 32'd0) |
      ((save_eeprom_busy_count_core != 0) ? `PS_PL_SAVE_STATUS_BUSY_EEPROM : 32'd0);
  wire save_write_event_core = ddram_accept_new && save_out_ena && !save_out_rnw;
  wire [1:0] save_write_kind_core = unused_save_sram ? `PS_PL_SAVE_KIND_SRAM :
                                    unused_save_flash ? `PS_PL_SAVE_KIND_FLASH :
                                    unused_save_eeprom ? `PS_PL_SAVE_KIND_EEPROM : 2'd3;
  wire save_write_kind_supported_core = unused_save_sram || unused_save_flash || unused_save_eeprom;
  wire save_write_done_event_core = ch4_write_done;
  wire save_write_pop_valid_core = save_write_done_event_core && (save_kind_fifo_count != 0);
  wire [1:0] save_write_retired_kind_core = save_kind_fifo[save_kind_fifo_rd_ptr];
  wire save_write_push_valid_core = save_write_event_core && (save_kind_fifo_count < 3'd4);

  // 3. 内存系统信号 (DDRAM Mux & Backend)
  wire        ddram_busy;
  wire [7:0]  ddram_burstcnt;
  wire [28:0] ddram_addr;
  wire [63:0] ddram_dout;
  wire        ddram_dout_ready;
  wire        ddram_rd;
  wire [63:0] ddram_din;
  wire [7:0]  ddram_be;
  wire        ddram_we;
  wire        ddram_done;
  wire        ddram_fatal_fault;
  wire        ch4_write_done;
  wire        ddram_accept_new;

  wire [27:1] ch1_addr, ch2_addr, ch4_addr;
  wire [25:1] ch3_addr;
  wire [63:0] ch1_dout, ch1_din, ch2_din, ch4_dout, ch4_din;
  wire [31:0] ch2_dout;
  wire [15:0] ch3_din, ch3_dout_unused;
  wire        ch1_ready, ch2_ready, ch3_ready_unused, ch4_ready;
  wire        ch1_req, ch2_req, ch3_req, ch4_req;
  wire        ch1_rnw, ch2_rnw, ch3_rnw, ch4_rnw;
  wire [7:0]  ch4_be;

  // 4. GBA 核心内存请求接口
  wire        sdram_read_ena, sdram_read_done;
  wire [24:0] sdram_read_addr;
  wire [31:0] sdram_read_data, sdram_second_dword;

  wire [31:0] bus_out_din, bus_out_dout;
  wire [25:0] bus_out_adr;
  wire        bus_out_rnw, bus_out_ena, bus_out_done;

  wire [63:0] save_out_din, save_out_dout;
  wire [25:0] save_out_adr;
  wire        save_out_rnw, save_out_ena, save_out_active, save_out_done;
  wire [7:0]  save_out_be;

  // 5. 视频与帧缓冲信号
  wire        fb_frame_pulse;
  wire [1:0]  display_frame_idx_core;
  wire [1:0]  w_core_display_frame_idx;
  wire [31:0] unused_core_fb_base;
  wire [25:0] unused_core_fb_addr;
  wire [63:0] unused_core_fb_data;
  wire        unused_core_fb_req;
  wire        core_fb_done;
  wire        core_fb_newframe;
  wire [15:0] core_pixel_addr;
  wire [17:0] core_pixel_data;
  wire        core_pixel_we;
  wire [31:0] fbcap_frame_seq;
  wire        fbcap_frame_buf_idx;
  wire [31:0] core_debug_internal;

  // 6. 状态与统计
  wire [31:0] cycles_missing, cycles_vsync_speed;
  wire [31:0] sys_err_vec_w;
  wire        sys_err_pulse_w;
  wire        w_core_cfg_sw_reset;
  wire        irq_vsync_pulse_axi;
  wire        irq_error_pulse_axi;
  wire        sys_rom_loading_axi;
  wire [31:0] debug_cpu_pc_axi;
  wire [31:0] debug_cpu_mixed_axi;
  wire [31:0] debug_cpu_r0_axi;
  wire [31:0] debug_cpu_r1_axi;
  wire [31:0] debug_cpu_r2_axi;
  wire [31:0] debug_cpu_r4_axi;
  wire [31:0] debug_cpu_cpuset_axi;
  wire [31:0] ddr_atom_word0_axi;
  wire [31:0] ddr_atom_word1_axi;
  wire [31:0] ddr_atom_next0_axi;
  wire [31:0] ddr_atom_next1_axi;
  wire [31:0] ddr_atom_stat_axi;
  wire [31:0] debug_irq_axi;
  wire [31:0] debug_irq_ext_axi;
  wire [31:0] debug_dma_axi;
  wire [31:0] debug_mem_axi;
  wire [31:0] debug_vram_regs0_axi;
  wire [31:0] debug_vram_regs1_axi;
  wire [31:0] debug_vram_regs2_axi;
  wire [31:0] debug_vram_regs3_axi;
  wire [31:0] debug_vram_regs4_axi;
  wire [31:0] debug_vram_hits_axi;
  wire [31:0] debug_vram_ring0_axi;
  wire [31:0] debug_vram_ring1_axi;
  wire [31:0] debug_vram_ring2_axi;
  wire [31:0] debug_vram_ring3_axi;
  wire [31:0] debug_vram_dist0_axi;
  wire [31:0] debug_vram_dist1_axi;
  wire [31:0] debug_dma_tr0_axi;
  wire [31:0] debug_dma_tr1_axi;
  wire [31:0] debug_dma_tr2_axi;
  wire [31:0] debug_dma_tr3_axi;
  wire [31:0] debug_dma_tr4_axi;
  wire [31:0] debug_dma_tr5_axi;
  wire [31:0] debug_dma_tr6_axi;
  wire [31:0] debug_dma_tr7_axi;
  wire [31:0] debug_dma_tr8_axi;
  wire [31:0] debug_wait0_axi;
  wire [31:0] debug_wait1_axi;
  wire [31:0] debug_wait2_axi;
  wire [31:0] debug_wait3_axi;
  wire [31:0] dbg_chain_flags_axi;
  wire [31:0] dbg_chain_counts0_axi;
  wire [31:0] dbg_chain_counts1_axi;
  wire [31:0] dbg_ch1_first_addr_axi;
  wire [31:0] dbg_ch1_first_meta_axi;
  wire [31:0] dbg_ch1_last_addr_axi;
  wire [31:0] dbg_ch1_last_meta_axi;
  wire [31:0] dbg_ddr_first_addr_axi;
  wire [31:0] dbg_ddr_first_meta_axi;
  wire [31:0] dbg_ddr_last_addr_axi;
  wire [31:0] dbg_ddr_last_meta_axi;
  wire [31:0] dbg_axi_ar_first_addr_axi;
  wire [31:0] dbg_axi_ar_first_meta_axi;
  wire [31:0] dbg_axi_ar_last_addr_axi;
  wire [31:0] dbg_axi_ar_last_meta_axi;
  wire [31:0] dbg_axi_r_first_addr_axi;
  wire [31:0] dbg_axi_r_first_meta_axi;
  wire [31:0] dbg_axi_r_last_addr_axi;
  wire [31:0] dbg_axi_r_last_meta_axi;
  wire [31:0] dbg_done_first_addr_axi;
  wire [31:0] dbg_done_first_meta_axi;
  wire [31:0] dbg_done_last_addr_axi;
  wire [31:0] dbg_done_last_meta_axi;
  wire [31:0] save_status_axi;
  wire        feature_savestate_busy_axi;
  wire        feature_load_done_pulse_axi;
  wire        feature_rewind_active_axi;
  wire        feature_rumble_out_axi;
  wire        feature_cheats_active_axi;
  wire        feature_rtc_inuse_axi;
  wire [2:0]  feature_slot_echo_axi;
  wire [2:0]  feature_solar_echo_axi;
  wire [31:0] feature_rtc_out_timestamp_axi;
  wire [31:0] feature_rtc_out_savedtime_lo_axi;
  wire [31:0] feature_rtc_out_savedtime_hi_axi;

  (* ASYNC_REG = "TRUE" *) reg        w_core_cfg_sw_reset_meta, w_core_cfg_sw_reset_sync;
  reg [31:0]                          fbcap_frame_seq_axi_sync;
  reg                                 fbcap_frame_buf_idx_axi_sync;
  reg [31:0]                          fbcap_shadow_seq_core;
  reg                                 fbcap_shadow_buf_core;
  reg                                 fbcap_shadow_req_tgl_core;
  reg                                 fbcap_shadow_ack_tgl_axi;
  (* ASYNC_REG = "TRUE" *) reg [2:0]  fbcap_shadow_req_sync_axi;
  (* ASYNC_REG = "TRUE" *) reg [2:0]  fbcap_shadow_ack_sync_core;
  // Held-payload CDC sampling stages: core shadow values stay stable until
  // the AXI acknowledgement returns, so both AXI stages sample one image.
  (* ASYNC_REG = "TRUE" *) reg [31:0] fbcap_shadow_seq_axi_s1;
  (* ASYNC_REG = "TRUE" *) reg [31:0] fbcap_shadow_seq_axi_s2;
  (* ASYNC_REG = "TRUE" *) reg        fbcap_shadow_buf_axi_s1;
  (* ASYNC_REG = "TRUE" *) reg        fbcap_shadow_buf_axi_s2;
  reg [1:0]                           fbcap_shadow_sample_cnt;
  reg                                 feature_load_done_toggle_core;
  (* ASYNC_REG = "TRUE" *) reg [2:0]  feature_load_done_toggle_axi_sync;
  reg                                 bios_wr_ack_seen_axi;
  reg [31:0]                          bios_wr_ack_seq_axi;
  wire [11:0]                         bios_wr_addr_core = bios_wr_dst_payload[43:32];
  wire [31:0]                         bios_wr_data_core = bios_wr_dst_payload[31:0];
  wire                                bios_wr_core = bios_wr_dst_valid;

  wire [15:0] unused_core_vcount;
  reg                                  fb_frame_pulse_toggle;
  reg                                  sys_err_pulse_toggle;
  (* ASYNC_REG = "TRUE" *) reg [2:0]  fb_frame_pulse_toggle_axi_sync;
  (* ASYNC_REG = "TRUE" *) reg [2:0]  sys_err_pulse_toggle_axi_sync;
  reg [31:0]                          dbg_chain_flags_core;
  reg [31:0]                          dbg_chain_counts0_core;
  reg [31:0]                          dbg_chain_counts1_core;
  reg [31:0]                          dbg_ch1_first_addr_core;
  reg [31:0]                          dbg_ch1_first_meta_core;
  reg [31:0]                          dbg_ch1_last_addr_core;
  reg [31:0]                          dbg_ch1_last_meta_core;
  reg [31:0]                          dbg_ddr_first_addr_core;
  reg [31:0]                          dbg_ddr_first_meta_core;
  reg [31:0]                          dbg_ddr_last_addr_core;
  reg [31:0]                          dbg_ddr_last_meta_core;
  reg [31:0]                          dbg_axi_ar_first_addr_core;
  reg [31:0]                          dbg_axi_ar_first_meta_core;
  reg [31:0]                          dbg_axi_ar_last_addr_core;
  reg [31:0]                          dbg_axi_ar_last_meta_core;
  reg [31:0]                          dbg_axi_r_first_addr_core;
  reg [31:0]                          dbg_axi_r_first_meta_core;
  reg [31:0]                          dbg_axi_r_last_addr_core;
  reg [31:0]                          dbg_axi_r_last_meta_core;
  reg [31:0]                          dbg_done_first_addr_core;
  reg [31:0]                          dbg_done_first_meta_core;
  reg [31:0]                          dbg_done_last_addr_core;
  reg [31:0]                          dbg_done_last_meta_core;
  reg [31:0]                          ddr_atom_word0_core;
  reg [31:0]                          ddr_atom_word1_core;
  reg [31:0]                          ddr_atom_next0_core;
  reg [31:0]                          ddr_atom_next1_core;
  reg [31:0]                          ddr_atom_stat_core;
  reg                                 ddr_atom_pending_core;
  reg [31:0]                          dbg_pending_line_addr;
  reg [1:0]                           dbg_pending_lane;
  reg [31:0]                          dbg_pending_axi_ar_addr;
  reg [1:0]                           dbg_last_axi_rresp;
  reg                                 dbg_last_axi_rlast;
  reg [7:0]                           save_sram_count_core;
  reg [7:0]                           save_flash_count_core;
  reg [7:0]                           save_eeprom_count_core;

  // 7. 明确收口上游核心当前未接入的可选功能，避免综合依赖隐式默认值
  localparam [1:0] GBA_UNDERCLOCK_OFF       = 2'b00;

  wire [31:0] unused_bus_read_data;
  wire [31:0] core_rtc_timestamp_out;
  wire [41:0] core_rtc_savedtime_out;
  wire        core_rtc_inuse;
  wire        core_cheats_active;
  wire        unused_save_eeprom;
  wire        unused_save_sram;
  wire        unused_save_flash;
  wire        core_load_done;
  wire        core_rumble;
  wire [31:0] unused_debug_cpu_pc;
  wire [31:0] unused_debug_cpu_mixed;
  wire [31:0] unused_debug_cpu_r0;
  wire [31:0] unused_debug_cpu_r1;
  wire [31:0] unused_debug_cpu_r2;
  wire [31:0] unused_debug_cpu_r4;
  wire [31:0] unused_debug_cpu_cpuset;
  wire [31:0] unused_debug_irq;
  wire [31:0] unused_debug_irq_ext;
  wire [31:0] unused_debug_dma;
  wire [31:0] unused_debug_mem;
  wire [31:0] unused_debug_vram_regs0;
  wire [31:0] unused_debug_vram_regs1;
  wire [31:0] unused_debug_vram_regs2;
  wire [31:0] unused_debug_vram_regs3;
  wire [31:0] unused_debug_vram_regs4;
  wire [31:0] unused_debug_vram_hits;
  wire [31:0] unused_debug_vram_ring0;
  wire [31:0] unused_debug_vram_ring1;
  wire [31:0] unused_debug_vram_ring2;
  wire [31:0] unused_debug_vram_ring3;
  wire [31:0] unused_debug_vram_dist0;
  wire [31:0] unused_debug_vram_dist1;
  wire [31:0] unused_debug_dma_tr0;
  wire [31:0] unused_debug_dma_tr1;
  wire [31:0] unused_debug_dma_tr2;
  wire [31:0] unused_debug_dma_tr3;
  wire [31:0] unused_debug_dma_tr4;
  wire [31:0] unused_debug_dma_tr5;
  wire [31:0] unused_debug_dma_tr6;
  wire [31:0] unused_debug_dma_tr7;
  wire [31:0] unused_debug_dma_tr8;
  wire [31:0] unused_debug_wait0;
  wire [31:0] unused_debug_wait1;
  wire [31:0] unused_debug_wait2;
  wire [31:0] unused_debug_wait3;
  wire [15:0] core_audio_l;
  wire [15:0] core_audio_r;
  wire        audio_sample_ce;
  wire [15:0] audio_out_l;
  wire [15:0] audio_out_r;

  assign debug_snapshot_source_payload = {
    dbg_done_last_meta_core,
    dbg_done_last_addr_core,
    dbg_done_first_meta_core,
    dbg_done_first_addr_core,
    dbg_axi_r_last_meta_core,
    dbg_axi_r_last_addr_core,
    dbg_axi_r_first_meta_core,
    dbg_axi_r_first_addr_core,
    dbg_axi_ar_last_meta_core,
    dbg_axi_ar_last_addr_core,
    dbg_axi_ar_first_meta_core,
    dbg_axi_ar_first_addr_core,
    dbg_ddr_last_meta_core,
    dbg_ddr_last_addr_core,
    dbg_ddr_first_meta_core,
    dbg_ddr_first_addr_core,
    dbg_ch1_last_meta_core,
    dbg_ch1_last_addr_core,
    dbg_ch1_first_meta_core,
    dbg_ch1_first_addr_core,
    dbg_chain_counts1_core,
    dbg_chain_counts0_core,
    dbg_chain_flags_core,
    unused_debug_wait3,
    unused_debug_wait2,
    unused_debug_wait1,
    unused_debug_wait0,
    unused_debug_dma_tr8,
    unused_debug_dma_tr7,
    unused_debug_dma_tr6,
    unused_debug_dma_tr5,
    unused_debug_dma_tr4,
    unused_debug_dma_tr3,
    unused_debug_dma_tr2,
    unused_debug_dma_tr1,
    unused_debug_dma_tr0,
    unused_debug_vram_dist1,
    unused_debug_vram_dist0,
    unused_debug_vram_ring3,
    unused_debug_vram_ring2,
    unused_debug_vram_ring1,
    unused_debug_vram_ring0,
    unused_debug_vram_hits,
    unused_debug_vram_regs4,
    unused_debug_vram_regs3,
    unused_debug_vram_regs2,
    unused_debug_vram_regs1,
    unused_debug_vram_regs0,
    unused_debug_mem,
    unused_debug_dma,
    unused_debug_irq_ext,
    unused_debug_irq,
    ddr_atom_stat_core,
    ddr_atom_next1_core,
    ddr_atom_next0_core,
    ddr_atom_word1_core,
    ddr_atom_word0_core,
    unused_debug_cpu_cpuset,
    unused_debug_cpu_r4,
    unused_debug_cpu_r2,
    unused_debug_cpu_r1,
    unused_debug_cpu_r0,
    unused_debug_cpu_mixed,
    unused_debug_cpu_pc,
    {21'd0, w_core_rtc_save_loaded, core_rtc_savedtime_out[41:32]},
    core_rtc_savedtime_out[31:0],
    core_rtc_timestamp_out,
    {29'd0, w_core_sensor_solar},
    {29'd0, w_core_savestate_slot},
    {31'd0, core_rtc_inuse},
    {31'd0, core_cheats_active},
    {31'd0, core_rumble},
    {31'd0, w_core_rewind_active},
    {31'd0, save_out_active},
    {8'd0, save_eeprom_count_core, save_flash_count_core, save_sram_count_core},
    {31'd0, w_core_cfg_ctrl[8]},
    {22'd0, w_core_physical_keys},
    {30'd0, display_frame_idx_core},
    {16'd0, cycles_vsync_speed[15:0]},
    {18'd0, cycles_missing[13:0]},
    rom_epoch_core,
    {4'd0, mem_error_addr_core},
    {28'd0, mem_error_core},
    {27'd0, mem_status_core}
  };
  assign debug_snapshot_src_valid = debug_snapshot_pending_core && debug_snapshot_src_ready;
  assign debug_snapshot_dst_ready = debug_snapshot_dst_valid;

  assign mem_status_axi_snapshot = debug_snapshot_dst_payload[4:0];
  assign mem_error_axi_snapshot = debug_snapshot_dst_payload[35:32];
  assign mem_error_addr_axi_snapshot = debug_snapshot_dst_payload[91:64];
  assign rom_epoch_axi_snapshot = debug_snapshot_dst_payload[96 +: 32];
  assign debug_snapshot_cycles_missing = debug_snapshot_dst_payload[141:128];
  assign debug_snapshot_cycles_vsync = debug_snapshot_dst_payload[175:160];
  assign debug_snapshot_frame_idx = debug_snapshot_dst_payload[193:192];
  assign debug_snapshot_physical_keys = debug_snapshot_dst_payload[233:224];
  assign sys_rom_loading_axi = debug_snapshot_dst_payload[256];
  assign save_status_axi = debug_snapshot_dst_payload[288 +: 32];
  assign feature_savestate_busy_axi = debug_snapshot_dst_payload[320];
  assign feature_rewind_active_axi = debug_snapshot_dst_payload[352];
  assign feature_rumble_out_axi = debug_snapshot_dst_payload[384];
  assign feature_cheats_active_axi = debug_snapshot_dst_payload[416];
  assign feature_rtc_inuse_axi = debug_snapshot_dst_payload[448];
  assign feature_slot_echo_axi = debug_snapshot_dst_payload[482:480];
  assign feature_solar_echo_axi = debug_snapshot_dst_payload[514:512];
  assign feature_rtc_out_timestamp_axi = debug_snapshot_dst_payload[544 +: 32];
  assign feature_rtc_out_savedtime_lo_axi = debug_snapshot_dst_payload[576 +: 32];
  assign feature_rtc_out_savedtime_hi_axi = debug_snapshot_dst_payload[608 +: 32];
  assign debug_cpu_pc_axi = debug_snapshot_dst_payload[640 +: 32];
  assign debug_cpu_mixed_axi = debug_snapshot_dst_payload[672 +: 32];
  assign debug_cpu_r0_axi = debug_snapshot_dst_payload[704 +: 32];
  assign debug_cpu_r1_axi = debug_snapshot_dst_payload[736 +: 32];
  assign debug_cpu_r2_axi = debug_snapshot_dst_payload[768 +: 32];
  assign debug_cpu_r4_axi = debug_snapshot_dst_payload[800 +: 32];
  assign debug_cpu_cpuset_axi = debug_snapshot_dst_payload[832 +: 32];
  assign ddr_atom_word0_axi = debug_snapshot_dst_payload[864 +: 32];
  assign ddr_atom_word1_axi = debug_snapshot_dst_payload[896 +: 32];
  assign ddr_atom_next0_axi = debug_snapshot_dst_payload[928 +: 32];
  assign ddr_atom_next1_axi = debug_snapshot_dst_payload[960 +: 32];
  assign ddr_atom_stat_axi = debug_snapshot_dst_payload[992 +: 32];
  assign debug_irq_axi = debug_snapshot_dst_payload[1024 +: 32];
  assign debug_irq_ext_axi = debug_snapshot_dst_payload[1056 +: 32];
  assign debug_dma_axi = debug_snapshot_dst_payload[1088 +: 32];
  assign debug_mem_axi = debug_snapshot_dst_payload[1120 +: 32];
  assign debug_vram_regs0_axi = debug_snapshot_dst_payload[1152 +: 32];
  assign debug_vram_regs1_axi = debug_snapshot_dst_payload[1184 +: 32];
  assign debug_vram_regs2_axi = debug_snapshot_dst_payload[1216 +: 32];
  assign debug_vram_regs3_axi = debug_snapshot_dst_payload[1248 +: 32];
  assign debug_vram_regs4_axi = debug_snapshot_dst_payload[1280 +: 32];
  assign debug_vram_hits_axi = debug_snapshot_dst_payload[1312 +: 32];
  assign debug_vram_ring0_axi = debug_snapshot_dst_payload[1344 +: 32];
  assign debug_vram_ring1_axi = debug_snapshot_dst_payload[1376 +: 32];
  assign debug_vram_ring2_axi = debug_snapshot_dst_payload[1408 +: 32];
  assign debug_vram_ring3_axi = debug_snapshot_dst_payload[1440 +: 32];
  assign debug_vram_dist0_axi = debug_snapshot_dst_payload[1472 +: 32];
  assign debug_vram_dist1_axi = debug_snapshot_dst_payload[1504 +: 32];
  assign debug_dma_tr0_axi = debug_snapshot_dst_payload[1536 +: 32];
  assign debug_dma_tr1_axi = debug_snapshot_dst_payload[1568 +: 32];
  assign debug_dma_tr2_axi = debug_snapshot_dst_payload[1600 +: 32];
  assign debug_dma_tr3_axi = debug_snapshot_dst_payload[1632 +: 32];
  assign debug_dma_tr4_axi = debug_snapshot_dst_payload[1664 +: 32];
  assign debug_dma_tr5_axi = debug_snapshot_dst_payload[1696 +: 32];
  assign debug_dma_tr6_axi = debug_snapshot_dst_payload[1728 +: 32];
  assign debug_dma_tr7_axi = debug_snapshot_dst_payload[1760 +: 32];
  assign debug_dma_tr8_axi = debug_snapshot_dst_payload[1792 +: 32];
  assign debug_wait0_axi = debug_snapshot_dst_payload[1824 +: 32];
  assign debug_wait1_axi = debug_snapshot_dst_payload[1856 +: 32];
  assign debug_wait2_axi = debug_snapshot_dst_payload[1888 +: 32];
  assign debug_wait3_axi = debug_snapshot_dst_payload[1920 +: 32];
  assign dbg_chain_flags_axi = debug_snapshot_dst_payload[1952 +: 32];
  assign dbg_chain_counts0_axi = debug_snapshot_dst_payload[1984 +: 32];
  assign dbg_chain_counts1_axi = debug_snapshot_dst_payload[2016 +: 32];
  assign dbg_ch1_first_addr_axi = debug_snapshot_dst_payload[2048 +: 32];
  assign dbg_ch1_first_meta_axi = debug_snapshot_dst_payload[2080 +: 32];
  assign dbg_ch1_last_addr_axi = debug_snapshot_dst_payload[2112 +: 32];
  assign dbg_ch1_last_meta_axi = debug_snapshot_dst_payload[2144 +: 32];
  assign dbg_ddr_first_addr_axi = debug_snapshot_dst_payload[2176 +: 32];
  assign dbg_ddr_first_meta_axi = debug_snapshot_dst_payload[2208 +: 32];
  assign dbg_ddr_last_addr_axi = debug_snapshot_dst_payload[2240 +: 32];
  assign dbg_ddr_last_meta_axi = debug_snapshot_dst_payload[2272 +: 32];
  assign dbg_axi_ar_first_addr_axi = debug_snapshot_dst_payload[2304 +: 32];
  assign dbg_axi_ar_first_meta_axi = debug_snapshot_dst_payload[2336 +: 32];
  assign dbg_axi_ar_last_addr_axi = debug_snapshot_dst_payload[2368 +: 32];
  assign dbg_axi_ar_last_meta_axi = debug_snapshot_dst_payload[2400 +: 32];
  assign dbg_axi_r_first_addr_axi = debug_snapshot_dst_payload[2432 +: 32];
  assign dbg_axi_r_first_meta_axi = debug_snapshot_dst_payload[2464 +: 32];
  assign dbg_axi_r_last_addr_axi = debug_snapshot_dst_payload[2496 +: 32];
  assign dbg_axi_r_last_meta_axi = debug_snapshot_dst_payload[2528 +: 32];
  assign dbg_done_first_addr_axi = debug_snapshot_dst_payload[2560 +: 32];
  assign dbg_done_first_meta_axi = debug_snapshot_dst_payload[2592 +: 32];
  assign dbg_done_last_addr_axi = debug_snapshot_dst_payload[2624 +: 32];
  assign dbg_done_last_meta_axi = debug_snapshot_dst_payload[2656 +: 32];

  assign w_core_cfg_sw_reset = w_core_cfg_sw_reset_sync;
  assign w_core_rom_ddr_safe = w_core_cfg_ctrl[14];
  assign display_frame_idx_core = w_core_display_frame_idx;
  assign irq_vsync_pulse_axi = fb_frame_pulse_toggle_axi_sync[2] ^ fb_frame_pulse_toggle_axi_sync[1];
  assign irq_error_pulse_axi = sys_err_pulse_toggle_axi_sync[2] ^ sys_err_pulse_toggle_axi_sync[1];
  assign audio_out_l = core_audio_l;
  assign audio_out_r = core_audio_r;
  // Keep the PS-side frame IRQ aligned with the core's original largeimg frame
  // boundary. Using pixel_addr==0 fires at the first pixel of a new frame and
  // can arrive before FB_CAP_SEQ has advanced, so the PS blit path misses the
  // completed frame.
  assign core_fb_newframe = unused_core_fb_req && (unused_core_fb_addr[19:0] == 20'd0);
  assign w_core_rewind_active = w_core_feature_ctrl[0] & w_core_feature_ctrl[5];
  assign feature_load_done_pulse_axi = feature_load_done_toggle_axi_sync[2] ^ feature_load_done_toggle_axi_sync[1];

  // @process-purpose: 封装PL 集成顶层中重复使用的纯组合换算规则，避免地址/位域规则散落在调用点。
  // @process-mechanism: 输入 value 等于 8'hFF 时保持饱和值，否则加 1；该函数供顶层调试/计数路径复用，避免计数器溢出回绕。
  // @process-result: 结果是调用点或后级逻辑得到无状态的组合返回/选择值，不引入额外寄存器、握手或跨时钟域副作用。
  function [7:0] sat_inc8;
    input [7:0] value;
    begin
      sat_inc8 = (value == 8'hFF) ? value : (value + 8'd1);
    end
  endfunction

  // @process-purpose: 在 clk_100 时钟域处理 PL 集成顶层的请求、事件或计数条件，并把结果锁存为下游可采样的控制/状态信号。
  // @process-mechanism: AXI软件复位单bit经两级同步；frame/error中断事件经toggle同步；显示帧索引随配置bundle原子邮箱提交。
  // @process-result: 结果是 core 域的软件复位、帧序号和错误脉冲被整理成跨域同步状态，供 AXI 状态寄存器稳定读取。
  always @(posedge clk_100) begin
    if (!rst_n) begin
      w_core_cfg_sw_reset_meta <= 1'b0;
      w_core_cfg_sw_reset_sync <= 1'b0;
      fb_frame_pulse_toggle    <= 1'b0;
      sys_err_pulse_toggle     <= 1'b0;
      dbg_chain_flags_core     <= 32'd0;
      dbg_chain_counts0_core   <= 32'd0;
      dbg_chain_counts1_core   <= 32'd0;
      dbg_ch1_first_addr_core  <= 32'd0;
      dbg_ch1_first_meta_core  <= 32'd0;
      dbg_ch1_last_addr_core   <= 32'd0;
      dbg_ch1_last_meta_core   <= 32'd0;
      dbg_ddr_first_addr_core  <= 32'd0;
      dbg_ddr_first_meta_core  <= 32'd0;
      dbg_ddr_last_addr_core   <= 32'd0;
      dbg_ddr_last_meta_core   <= 32'd0;
      dbg_axi_ar_first_addr_core <= 32'd0;
      dbg_axi_ar_first_meta_core <= 32'd0;
      dbg_axi_ar_last_addr_core <= 32'd0;
      dbg_axi_ar_last_meta_core <= 32'd0;
      dbg_axi_r_first_addr_core <= 32'd0;
      dbg_axi_r_first_meta_core <= 32'd0;
      dbg_axi_r_last_addr_core <= 32'd0;
      dbg_axi_r_last_meta_core <= 32'd0;
      dbg_done_first_addr_core <= 32'd0;
      dbg_done_first_meta_core <= 32'd0;
      dbg_done_last_addr_core <= 32'd0;
      dbg_done_last_meta_core <= 32'd0;
      ddr_atom_word0_core      <= 32'd0;
      ddr_atom_word1_core      <= 32'd0;
      ddr_atom_next0_core      <= 32'd0;
      ddr_atom_next1_core      <= 32'd0;
      ddr_atom_stat_core       <= 32'd0;
      ddr_atom_pending_core    <= 1'b0;
      dbg_pending_line_addr   <= 32'd0;
      dbg_pending_lane        <= 2'd0;
      dbg_pending_axi_ar_addr <= 32'd0;
      dbg_last_axi_rresp      <= 2'd0;
      dbg_last_axi_rlast      <= 1'b0;
      save_sram_count_core    <= 8'd0;
      save_flash_count_core   <= 8'd0;
      save_eeprom_count_core  <= 8'd0;
      feature_load_done_toggle_core <= 1'b0;
    end else begin
      w_core_cfg_sw_reset_meta <= w_axi_cfg_sw_reset;
      w_core_cfg_sw_reset_sync <= w_core_cfg_sw_reset_meta;

      if (fb_frame_pulse) begin
        fb_frame_pulse_toggle <= ~fb_frame_pulse_toggle;
      end

      if (sys_err_pulse_w) begin
        sys_err_pulse_toggle <= ~sys_err_pulse_toggle;
      end

      if (w_core_cfg_sw_reset) begin
        dbg_chain_flags_core     <= 32'd0;
        dbg_chain_counts0_core   <= 32'd0;
        dbg_chain_counts1_core   <= 32'd0;
        dbg_ch1_first_addr_core  <= 32'd0;
        dbg_ch1_first_meta_core  <= 32'd0;
        dbg_ch1_last_addr_core   <= 32'd0;
        dbg_ch1_last_meta_core   <= 32'd0;
        dbg_ddr_first_addr_core  <= 32'd0;
        dbg_ddr_first_meta_core  <= 32'd0;
        dbg_ddr_last_addr_core   <= 32'd0;
        dbg_ddr_last_meta_core   <= 32'd0;
        dbg_axi_ar_first_addr_core <= 32'd0;
        dbg_axi_ar_first_meta_core <= 32'd0;
        dbg_axi_ar_last_addr_core <= 32'd0;
        dbg_axi_ar_last_meta_core <= 32'd0;
        dbg_axi_r_first_addr_core <= 32'd0;
        dbg_axi_r_first_meta_core <= 32'd0;
        dbg_axi_r_last_addr_core <= 32'd0;
        dbg_axi_r_last_meta_core <= 32'd0;
        dbg_done_first_addr_core <= 32'd0;
        dbg_done_first_meta_core <= 32'd0;
        dbg_done_last_addr_core <= 32'd0;
        dbg_done_last_meta_core <= 32'd0;
        ddr_atom_word0_core      <= 32'd0;
        ddr_atom_word1_core      <= 32'd0;
        ddr_atom_next0_core      <= 32'd0;
        ddr_atom_next1_core      <= 32'd0;
        ddr_atom_stat_core       <= 32'd0;
        ddr_atom_pending_core    <= 1'b0;
        dbg_pending_line_addr   <= 32'd0;
        dbg_pending_lane        <= 2'd0;
        dbg_pending_axi_ar_addr <= 32'd0;
        dbg_last_axi_rresp      <= 2'd0;
        dbg_last_axi_rlast      <= 1'b0;
        save_sram_count_core    <= 8'd0;
        save_flash_count_core   <= 8'd0;
        save_eeprom_count_core  <= 8'd0;
      end else begin
        if (unused_save_sram) begin
          save_sram_count_core <= save_sram_count_core + 8'd1;
        end

        if (unused_save_flash) begin
          save_flash_count_core <= save_flash_count_core + 8'd1;
        end

        if (unused_save_eeprom) begin
          save_eeprom_count_core <= save_eeprom_count_core + 8'd1;
        end

        if (ch1_req) begin
          dbg_pending_line_addr <= {4'b0011, ch1_addr[27:3], 3'b000};
          dbg_pending_lane <= ch1_addr[2:1];
          if (!dbg_chain_flags_core[0]) begin
            dbg_ch1_first_addr_core <= {4'b0011, ch1_addr[27:3], 3'b000};
            dbg_ch1_first_meta_core <= {19'd0, display_frame_idx_core, ddram_busy, ch1_addr[2:1], dbg_chain_counts0_core[7:0]};
            dbg_chain_flags_core[0] <= 1'b1;
          end
          dbg_ch1_last_addr_core <= {4'b0011, ch1_addr[27:3], 3'b000};
          dbg_ch1_last_meta_core <= {19'd0, display_frame_idx_core, ddram_busy, ch1_addr[2:1], dbg_chain_counts0_core[7:0]};
          dbg_chain_counts0_core[7:0] <= sat_inc8(dbg_chain_counts0_core[7:0]);
        end

        if (ddram_rd || ddram_we) begin
          dbg_pending_line_addr <= {ddram_addr, 3'b000};
          if (!dbg_chain_flags_core[1]) begin
            dbg_ddr_first_addr_core <= {ddram_addr, 3'b000};
            dbg_ddr_first_meta_core <= {13'd0, ddram_busy, ddram_we, ddram_rd, ddram_burstcnt, dbg_chain_counts0_core[15:8]};
            dbg_chain_flags_core[1] <= 1'b1;
          end
          dbg_ddr_last_addr_core <= {ddram_addr, 3'b000};
          dbg_ddr_last_meta_core <= {13'd0, ddram_busy, ddram_we, ddram_rd, ddram_burstcnt, dbg_chain_counts0_core[15:8]};
          dbg_chain_counts0_core[15:8] <= sat_inc8(dbg_chain_counts0_core[15:8]);
        end

        if (M_AXI_ARVALID && M_AXI_ARREADY) begin
          dbg_pending_axi_ar_addr <= M_AXI_ARADDR;
          if (!dbg_chain_flags_core[2]) begin
            dbg_axi_ar_first_addr_core <= M_AXI_ARADDR;
            dbg_axi_ar_first_meta_core <= {10'd0, M_AXI_ARREADY, M_AXI_ARBURST, M_AXI_ARSIZE, M_AXI_ARLEN, dbg_chain_counts0_core[23:16]};
            dbg_chain_flags_core[2] <= 1'b1;
          end
          dbg_axi_ar_last_addr_core <= M_AXI_ARADDR;
          dbg_axi_ar_last_meta_core <= {10'd0, M_AXI_ARREADY, M_AXI_ARBURST, M_AXI_ARSIZE, M_AXI_ARLEN, dbg_chain_counts0_core[23:16]};
          dbg_chain_counts0_core[23:16] <= sat_inc8(dbg_chain_counts0_core[23:16]);
        end

        if (M_AXI_RVALID && M_AXI_RREADY) begin
          dbg_last_axi_rresp <= M_AXI_RRESP;
          dbg_last_axi_rlast <= M_AXI_RLAST;
          if (!dbg_chain_flags_core[3]) begin
            dbg_axi_r_first_addr_core <= dbg_pending_axi_ar_addr;
            dbg_axi_r_first_meta_core <= {21'd0, M_AXI_RLAST, M_AXI_RRESP, dbg_chain_counts0_core[31:24]};
            dbg_chain_flags_core[3] <= 1'b1;
          end
          dbg_axi_r_last_addr_core <= dbg_pending_axi_ar_addr;
          dbg_axi_r_last_meta_core <= {21'd0, M_AXI_RLAST, M_AXI_RRESP, dbg_chain_counts0_core[31:24]};
          dbg_chain_counts0_core[31:24] <= sat_inc8(dbg_chain_counts0_core[31:24]);
          if (M_AXI_RRESP != 2'b00) begin
            dbg_chain_flags_core[7] <= 1'b1;
          end
        end

        if (ddram_dout_ready) begin
          dbg_chain_flags_core[4] <= 1'b1;
          dbg_chain_counts1_core[7:0] <= sat_inc8(dbg_chain_counts1_core[7:0]);
        end

        if (sdram_read_done) begin
          if (!dbg_chain_flags_core[5]) begin
            dbg_done_first_addr_core <= dbg_pending_line_addr;
            dbg_done_first_meta_core <= {17'd0, dbg_last_axi_rlast, dbg_last_axi_rresp, display_frame_idx_core, dbg_pending_lane, dbg_chain_counts1_core[15:8]};
            dbg_chain_flags_core[5] <= 1'b1;
          end
          dbg_done_last_addr_core <= dbg_pending_line_addr;
          dbg_done_last_meta_core <= {17'd0, dbg_last_axi_rlast, dbg_last_axi_rresp, display_frame_idx_core, dbg_pending_lane, dbg_chain_counts1_core[15:8]};
          dbg_chain_counts1_core[15:8] <= sat_inc8(dbg_chain_counts1_core[15:8]);
        end

        // DDR 64-bit 返回“同拍原子性”自证：
        // 在 sdram_read_done 拍锁存 {first, second}，
        // 下一拍再采样一次并对比，检查是否出现漂移。
        if (ddr_atom_pending_core) begin
          ddr_atom_next0_core <= sdram_read_data;
          ddr_atom_next1_core <= sdram_second_dword;
          ddr_atom_pending_core <= 1'b0;
          ddr_atom_stat_core[3] <= 1'b0;
          ddr_atom_stat_core[0] <= (sdram_read_data != ddr_atom_word0_core);
          ddr_atom_stat_core[1] <= (sdram_second_dword != ddr_atom_word1_core);
          ddr_atom_stat_core[2] <= (sdram_read_data != ddr_atom_word0_core) ||
                                   (sdram_second_dword != ddr_atom_word1_core);
          ddr_atom_stat_core[15:8] <= sat_inc8(ddr_atom_stat_core[15:8]);
          if (sdram_read_data != ddr_atom_word0_core) begin
            ddr_atom_stat_core[23:16] <= sat_inc8(ddr_atom_stat_core[23:16]);
          end
          if (sdram_second_dword != ddr_atom_word1_core) begin
            ddr_atom_stat_core[31:24] <= sat_inc8(ddr_atom_stat_core[31:24]);
          end
        end
        if (sdram_read_done) begin
          ddr_atom_word0_core <= sdram_read_data;
          ddr_atom_word1_core <= sdram_second_dword;
          ddr_atom_pending_core <= 1'b1;
          ddr_atom_stat_core[3] <= 1'b1;
        end

        if (sys_err_pulse_w) begin
          dbg_chain_flags_core[6] <= 1'b1;
          dbg_chain_counts1_core[23:16] <= sat_inc8(dbg_chain_counts1_core[23:16]);
        end

        // flags[21:8] = core_debug_internal sticky flags
        // bit8=gbaon, 9=reset, 10=new_cycles_valid, 11=gba_step,
        // 12=sleep_ss, 13=sleep_cheat, 14=sleep_rewind, 15=loading_ss,
        // 16=settle, 17=pix_we_int, 18=cpu_done, 19=dma_on,
        // 20=GBA_on_raw, 21=lockspeed
        dbg_chain_flags_core[21:8] <= dbg_chain_flags_core[21:8] | core_debug_internal[13:0];

        // counts1[27:24] = ddram_we 4-bit saturating counter
        if (ddram_we) begin
          if (dbg_chain_counts1_core[27:24] != 4'hF)
            dbg_chain_counts1_core[27:24] <= dbg_chain_counts1_core[27:24] + 4'd1;
        end

        // counts1[31:28] = core_pixel_we 4-bit saturating counter
        if (core_pixel_we) begin
          if (dbg_chain_counts1_core[31:28] != 4'hF)
            dbg_chain_counts1_core[31:28] <= dbg_chain_counts1_core[31:28] + 4'd1;
        end

        if (core_load_done) begin
          feature_load_done_toggle_core <= ~feature_load_done_toggle_core;
        end
      end
    end
  end

  // Multi-bit FB capture status CDC: snapshot in core clock domain, transfer
  // to AXI domain with toggle handshake.
  always @(posedge clk_100) begin
    if (!rst_n) begin
      fbcap_shadow_seq_core <= 32'd0;
      fbcap_shadow_buf_core <= 1'b0;
      fbcap_shadow_req_tgl_core <= 1'b0;
      fbcap_shadow_ack_sync_core <= 3'b000;
    end else begin
      fbcap_shadow_ack_sync_core <= {fbcap_shadow_ack_sync_core[1:0], fbcap_shadow_ack_tgl_axi};
      if ((fbcap_frame_seq != fbcap_shadow_seq_core) &&
          (fbcap_shadow_req_tgl_core == fbcap_shadow_ack_sync_core[2])) begin
        fbcap_shadow_seq_core <= fbcap_frame_seq;
        fbcap_shadow_buf_core <= fbcap_frame_buf_idx;
        fbcap_shadow_req_tgl_core <= ~fbcap_shadow_req_tgl_core;
      end
    end
  end

  // @process-purpose: 在 s_axi_aclk 时钟域处理 PL 集成顶层的请求、事件或计数条件，并把结果锁存为下游可采样的控制/状态信号。
  // @process-mechanism: AXI侧只同步toggle和单bit事件；多位诊断/状态由frame/error/save事件触发的hold-until-ack快照邮箱整体采样。
  // @process-result: 结果是 AXI 状态寄存器读到的是经过同步的 core 域计数、错误和调试信息，而不是异步毛刺。
  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      fbcap_frame_seq_axi_sync <= 32'd0;
      fbcap_frame_buf_idx_axi_sync <= 1'b0;
      fbcap_shadow_ack_tgl_axi <= 1'b0;
      fbcap_shadow_req_sync_axi <= 3'b000;
      fbcap_shadow_seq_axi_s1 <= 32'd0;
      fbcap_shadow_seq_axi_s2 <= 32'd0;
      fbcap_shadow_buf_axi_s1 <= 1'b0;
      fbcap_shadow_buf_axi_s2 <= 1'b0;
      fbcap_shadow_sample_cnt <= 2'd0;
      feature_load_done_toggle_axi_sync <= 3'b000;
      bios_wr_ack_seen_axi <= 1'b0;
      bios_wr_ack_seq_axi <= 32'd0;
      fb_frame_pulse_toggle_axi_sync <= 3'b000;
      sys_err_pulse_toggle_axi_sync  <= 3'b000;
    end else begin
      fbcap_shadow_req_sync_axi <= {fbcap_shadow_req_sync_axi[1:0], fbcap_shadow_req_tgl_core};
      if (fbcap_shadow_req_sync_axi[2] ^ fbcap_shadow_req_sync_axi[1]) begin
        // Need three destination cycles before commit:
        // 1) sample s1, 2) propagate to s2, 3) commit old s2 (NBA order).
        fbcap_shadow_sample_cnt <= 2'd3;
      end else if (fbcap_shadow_sample_cnt != 2'd0) begin
        fbcap_shadow_seq_axi_s1 <= fbcap_shadow_seq_core;
        fbcap_shadow_seq_axi_s2 <= fbcap_shadow_seq_axi_s1;
        fbcap_shadow_buf_axi_s1 <= fbcap_shadow_buf_core;
        fbcap_shadow_buf_axi_s2 <= fbcap_shadow_buf_axi_s1;
        fbcap_shadow_sample_cnt <= fbcap_shadow_sample_cnt - 2'd1;
        if (fbcap_shadow_sample_cnt == 2'd1) begin
          fbcap_frame_seq_axi_sync <= fbcap_shadow_seq_axi_s2;
          fbcap_frame_buf_idx_axi_sync <= fbcap_shadow_buf_axi_s2;
          fbcap_shadow_ack_tgl_axi <= ~fbcap_shadow_ack_tgl_axi;
        end
      end
      feature_load_done_toggle_axi_sync <= {feature_load_done_toggle_axi_sync[1:0], feature_load_done_toggle_core};
      if (bios_wr_src_ack_toggle != bios_wr_ack_seen_axi) begin
        bios_wr_ack_seen_axi <= bios_wr_src_ack_toggle;
        bios_wr_ack_seq_axi <= bios_wr_ack_seq_axi + 32'd1;
      end
      fb_frame_pulse_toggle_axi_sync <= {fb_frame_pulse_toggle_axi_sync[1:0], fb_frame_pulse_toggle};
      sys_err_pulse_toggle_axi_sync  <= {sys_err_pulse_toggle_axi_sync[1:0], sys_err_pulse_toggle};
    end
  end

  assign bios_wr_dst_ready = bios_wr_dst_valid;


  // ==========================================================================
  // --- 第一层：系统控制单元 (System Control Layer) ---
  // ==========================================================================
  // 责任：处理 PS 通信、CDC 同步以及核心配置管理
  
  assign frame_snap_dst_ready = frame_snap_dst_valid;
  assign save_snap_dst_ready = save_snap_dst_valid;
  assign save_ack_dst_ready = save_ack_dst_valid;

  cdc_toggle_mailbox #(.WIDTH(DEBUG_SNAPSHOT_WIDTH)) u_debug_snapshot_mailbox (
    .src_clk(clk_100), .src_rst_n(rst_n),
    .src_valid(debug_snapshot_src_valid),
    .src_payload(debug_snapshot_source_payload),
    .src_ready(debug_snapshot_src_ready), .src_busy(debug_snapshot_src_busy),
    .src_req_toggle(debug_snapshot_src_req_toggle),
    .src_ack_toggle(debug_snapshot_src_ack_toggle),
    .src_ack_payload(debug_snapshot_src_ack_payload),
    .dst_clk(s_axi_aclk), .dst_rst_n(s_axi_aresetn),
    .dst_valid(debug_snapshot_dst_valid),
    .dst_payload(debug_snapshot_dst_payload),
    .dst_ready(debug_snapshot_dst_ready)
  );

  cdc_toggle_mailbox #(.WIDTH(44)) u_bios_wr_mailbox (
    .src_clk(s_axi_aclk), .src_rst_n(s_axi_aresetn),
    .src_valid(bios_wr_src_valid), .src_payload(bios_wr_src_payload),
    .src_ready(bios_wr_src_ready), .src_busy(bios_wr_src_busy),
    .src_req_toggle(bios_wr_src_req_toggle), .src_ack_toggle(bios_wr_src_ack_toggle),
    .src_ack_payload(bios_wr_src_ack_payload),
    .dst_clk(clk_100), .dst_rst_n(rst_n),
    .dst_valid(bios_wr_dst_valid), .dst_payload(bios_wr_dst_payload),
    .dst_ready(bios_wr_dst_ready)
  );

  cdc_toggle_mailbox #(.WIDTH(64)) u_mem_cmd_mailbox (
    .src_clk          (s_axi_aclk),
    .src_rst_n        (s_axi_aresetn),
    .src_valid        (mem_cmd_src_valid),
    .src_payload      (mem_cmd_src_payload),
    .src_ready        (mem_cmd_src_ready),
    .src_busy         (mem_cmd_src_busy),
    .src_req_toggle   (mem_cmd_src_req_toggle),
    .src_ack_toggle   (mem_cmd_src_ack_toggle),
    .src_ack_payload  (mem_cmd_src_ack_payload),
    .dst_clk          (clk_100),
    .dst_rst_n        (rst_n),
    .dst_valid        (mem_cmd_dst_valid),
    .dst_payload      (mem_cmd_dst_payload),
    .dst_ready        (mem_cmd_dst_ready)
  );

  cdc_toggle_mailbox #(.WIDTH(32)) u_frame_snap_mailbox (
    .src_clk          (s_axi_aclk),
    .src_rst_n        (s_axi_aresetn),
    .src_valid        (frame_snap_src_valid),
    .src_payload      (frame_snap_src_payload),
    .src_ready        (frame_snap_src_ready),
    .src_busy         (frame_snap_src_busy),
    .src_req_toggle   (frame_snap_src_req_toggle),
    .src_ack_toggle   (frame_snap_src_ack_toggle),
    .src_ack_payload  (frame_snap_src_ack_payload),
    .dst_clk          (clk_100),
    .dst_rst_n        (rst_n),
    .dst_valid        (frame_snap_dst_valid),
    .dst_payload      (frame_snap_dst_payload),
    .dst_ready        (frame_snap_dst_ready)
  );

  cdc_toggle_mailbox #(.WIDTH(32)) u_save_snap_mailbox (
    .src_clk          (s_axi_aclk),
    .src_rst_n        (s_axi_aresetn),
    .src_valid        (save_snap_src_valid),
    .src_payload      (save_snap_src_payload),
    .src_ready        (save_snap_src_ready),
    .src_busy         (save_snap_src_busy),
    .src_req_toggle   (save_snap_src_req_toggle),
    .src_ack_toggle   (save_snap_src_ack_toggle),
    .src_ack_payload  (save_snap_src_ack_payload),
    .dst_clk          (clk_100),
    .dst_rst_n        (rst_n),
    .dst_valid        (save_snap_dst_valid),
    .dst_payload      (save_snap_dst_payload),
    .dst_ready        (save_snap_dst_ready)
  );

  cdc_toggle_mailbox #(.WIDTH(66)) u_save_ack_mailbox (
    .src_clk          (s_axi_aclk),
    .src_rst_n        (s_axi_aresetn),
    .src_valid        (save_ack_src_valid),
    .src_payload      (save_ack_src_payload),
    .src_ready        (save_ack_src_ready),
    .src_busy         (save_ack_src_busy),
    .src_req_toggle   (save_ack_src_req_toggle),
    .src_ack_toggle   (save_ack_src_ack_toggle),
    .src_ack_payload  (save_ack_src_ack_payload),
    .dst_clk          (clk_100),
    .dst_rst_n        (rst_n),
    .dst_valid        (save_ack_dst_valid),
    .dst_payload      (save_ack_dst_payload),
    .dst_ready        (save_ack_dst_ready)
  );

  // @instance-role: u_axi_regs 连接 PS 侧 AXI4-Lite 寄存器窗口与 core/调试/特性控制信号，是软件配置进入 PL 的入口。
  axi_lite_ctrl_regs u_axi_regs (
    .clk                 (s_axi_aclk),
    .rst_n               (s_axi_aresetn),
    .s_axi_awaddr        (s_axi_awaddr),
    .s_axi_awvalid       (s_axi_awvalid),
    .s_axi_awready       (s_axi_awready),
    .s_axi_wdata         (s_axi_wdata),
    .s_axi_wstrb         (s_axi_wstrb),
    .s_axi_wvalid        (s_axi_wvalid),
    .s_axi_wready        (s_axi_wready),
    .s_axi_bresp         (s_axi_bresp),
    .s_axi_bvalid        (s_axi_bvalid),
    .s_axi_bready        (s_axi_bready),
    .s_axi_araddr        (s_axi_araddr),
    .s_axi_arvalid       (s_axi_arvalid),
    .s_axi_arready       (s_axi_arready),
    .s_axi_rdata         (s_axi_rdata),
    .s_axi_rresp         (s_axi_rresp),
    .s_axi_rvalid        (s_axi_rvalid),
    .s_axi_rready        (s_axi_rready),
    .stat_cycles_missing (debug_snapshot_cycles_missing),
    .stat_cycles_vsync_speed(debug_snapshot_cycles_vsync),
    .stat_fb_frame_idx   (debug_snapshot_frame_idx),
    .stat_physical_keys  (debug_snapshot_physical_keys),
    .stat_debug_cpu_pc   (debug_cpu_pc_axi),
    .stat_debug_cpu_mixed(debug_cpu_mixed_axi),
    .stat_debug_cpu_r0   (debug_cpu_r0_axi),
    .stat_debug_cpu_r1   (debug_cpu_r1_axi),
    .stat_debug_cpu_r2   (debug_cpu_r2_axi),
    .stat_debug_cpu_r4   (debug_cpu_r4_axi),
    .stat_debug_cpu_cpuset(debug_cpu_cpuset_axi),
    .stat_ddr_atom_word0 (ddr_atom_word0_axi),
    .stat_ddr_atom_word1 (ddr_atom_word1_axi),
    .stat_ddr_atom_next0 (ddr_atom_next0_axi),
    .stat_ddr_atom_next1 (ddr_atom_next1_axi),
    .stat_ddr_atom_stat  (ddr_atom_stat_axi),
    .stat_debug_irq      (debug_irq_axi),
    .stat_debug_irq_ext  (debug_irq_ext_axi),
    .stat_debug_dma      (debug_dma_axi),
    .stat_debug_mem      (debug_mem_axi),
    .stat_debug_vram_regs0(debug_vram_regs0_axi),
    .stat_debug_vram_regs1(debug_vram_regs1_axi),
    .stat_debug_vram_regs2(debug_vram_regs2_axi),
    .stat_debug_vram_regs3(debug_vram_regs3_axi),
    .stat_debug_vram_regs4(debug_vram_regs4_axi),
    .stat_debug_vram_hits(debug_vram_hits_axi),
    .stat_debug_vram_ring0(debug_vram_ring0_axi),
    .stat_debug_vram_ring1(debug_vram_ring1_axi),
    .stat_debug_vram_ring2(debug_vram_ring2_axi),
    .stat_debug_vram_ring3(debug_vram_ring3_axi),
    .stat_debug_vram_dist0(debug_vram_dist0_axi),
    .stat_debug_vram_dist1(debug_vram_dist1_axi),
    .stat_debug_dma_tr0   (debug_dma_tr0_axi),
    .stat_debug_dma_tr1   (debug_dma_tr1_axi),
    .stat_debug_dma_tr2   (debug_dma_tr2_axi),
    .stat_debug_dma_tr3   (debug_dma_tr3_axi),
    .stat_debug_dma_tr4   (debug_dma_tr4_axi),
    .stat_debug_dma_tr5   (debug_dma_tr5_axi),
    .stat_debug_dma_tr6   (debug_dma_tr6_axi),
    .stat_debug_dma_tr7   (debug_dma_tr7_axi),
    .stat_debug_dma_tr8   (debug_dma_tr8_axi),
    .stat_debug_wait0     (debug_wait0_axi),
    .stat_debug_wait1     (debug_wait1_axi),
    .stat_debug_wait2     (debug_wait2_axi),
    .stat_debug_wait3     (debug_wait3_axi),
    .stat_dbg_chain_flags(dbg_chain_flags_axi),
    .stat_dbg_chain_counts0(dbg_chain_counts0_axi),
    .stat_dbg_chain_counts1(dbg_chain_counts1_axi),
    .stat_dbg_ch1_first_addr(dbg_ch1_first_addr_axi),
    .stat_dbg_ch1_first_meta(dbg_ch1_first_meta_axi),
    .stat_dbg_ch1_last_addr(dbg_ch1_last_addr_axi),
    .stat_dbg_ch1_last_meta(dbg_ch1_last_meta_axi),
    .stat_dbg_ddr_first_addr(dbg_ddr_first_addr_axi),
    .stat_dbg_ddr_first_meta(dbg_ddr_first_meta_axi),
    .stat_dbg_ddr_last_addr(dbg_ddr_last_addr_axi),
    .stat_dbg_ddr_last_meta(dbg_ddr_last_meta_axi),
    .stat_dbg_axi_ar_first_addr(dbg_axi_ar_first_addr_axi),
    .stat_dbg_axi_ar_first_meta(dbg_axi_ar_first_meta_axi),
    .stat_dbg_axi_ar_last_addr(dbg_axi_ar_last_addr_axi),
    .stat_dbg_axi_ar_last_meta(dbg_axi_ar_last_meta_axi),
    .stat_dbg_axi_r_first_addr(dbg_axi_r_first_addr_axi),
    .stat_dbg_axi_r_first_meta(dbg_axi_r_first_meta_axi),
    .stat_dbg_axi_r_last_addr(dbg_axi_r_last_addr_axi),
    .stat_dbg_axi_r_last_meta(dbg_axi_r_last_meta_axi),
    .stat_dbg_done_first_addr(dbg_done_first_addr_axi),
    .stat_dbg_done_first_meta(dbg_done_first_meta_axi),
    .stat_dbg_done_last_addr(dbg_done_last_addr_axi),
    .stat_dbg_done_last_meta(dbg_done_last_meta_axi),
    .sys_rom_loading     (sys_rom_loading_axi), // 使用控制寄存器位 8 标识加载状态
    .sys_error_in        ({mem_error_axi_snapshot, mem_error_addr_axi_snapshot}),
    .irq_vsync_pulse     (irq_vsync_pulse_axi),
    .irq_error_pulse     (irq_error_pulse_axi),
    .irq_out             (irq),
    .stat_feature_savestate_busy(feature_savestate_busy_axi),
    .stat_feature_load_done_pulse(feature_load_done_pulse_axi),
    .stat_feature_rewind_active(feature_rewind_active_axi),
    .stat_feature_rumble_out(feature_rumble_out_axi),
    .stat_feature_cheats_active(feature_cheats_active_axi),
    .stat_feature_rtc_inuse(feature_rtc_inuse_axi),
    .stat_feature_slot_echo(feature_slot_echo_axi),
    .stat_feature_solar_echo(feature_solar_echo_axi),
    .stat_rtc_out_timestamp(feature_rtc_out_timestamp_axi),
    .stat_rtc_out_savedtime_lo(feature_rtc_out_savedtime_lo_axi),
    .stat_rtc_out_savedtime_hi(feature_rtc_out_savedtime_hi_axi),
    .cfg_ctrl            (w_axi_cfg_ctrl),
    .cfg_keys            (w_axi_cfg_keys),
    .cfg_max_pak_addr    (w_axi_cfg_max_pak_addr),
    .cfg_cycle_precalc   (w_axi_cfg_cycle_precalc),
    .cfg_rtc_timestamp   (w_axi_cfg_rtc_timestamp),
    .cfg_rtc_timestamp_saved(w_axi_cfg_rtc_timestamp_saved),
    .cfg_display_frame_idx(w_axi_display_frame_idx),
    .cfg_sw_reset        (w_axi_cfg_sw_reset),
    .cfg_commit_toggle   (w_axi_cfg_commit_toggle),
    .stat_fbcap_frame_seq(fbcap_frame_seq_axi_sync),
    .stat_fbcap_frame_buf_idx(fbcap_frame_buf_idx_axi_sync),
    .stat_save_status    (save_status_axi),
    .cfg_bios_wr_addr    (w_axi_bios_wr_addr),
    .cfg_bios_wr_data    (w_axi_bios_wr_data),
    .cfg_bios_wr_req_toggle(w_axi_bios_wr_req_toggle),
    .stat_bios_wr_ack_seq(bios_wr_ack_seq_axi),
    .bios_wr_src_valid(bios_wr_src_valid),
    .bios_wr_src_payload(bios_wr_src_payload),
    .bios_wr_src_ready(bios_wr_src_ready),
    .bios_wr_src_req_toggle(bios_wr_src_req_toggle),
    .bios_wr_src_ack_toggle(bios_wr_src_ack_toggle),
    .bios_wr_src_ack_payload(bios_wr_src_ack_payload),
    .stat_mem_status     (mem_status_axi_snapshot),
    .stat_mem_error      (mem_error_axi_snapshot),
    .stat_mem_error_addr (mem_error_addr_axi_snapshot),
    .stat_rom_epoch      (rom_epoch_axi_snapshot),
    .cfg_mem_cmd         (),
    .cfg_mem_cmd_seq     (),
    .mem_cmd_src_valid   (mem_cmd_src_valid),
    .mem_cmd_src_payload (mem_cmd_src_payload),
    .mem_cmd_src_ready   (mem_cmd_src_ready),
    .mem_cmd_src_req_toggle(mem_cmd_src_req_toggle),
    .mem_cmd_src_ack_toggle(mem_cmd_src_ack_toggle),
    .mem_cmd_src_ack_payload(mem_cmd_src_ack_payload),
    .frame_snap_src_valid(frame_snap_src_valid),
    .frame_snap_src_payload(frame_snap_src_payload),
    .frame_snap_src_ready(frame_snap_src_ready),
    .frame_snap_src_req_toggle(frame_snap_src_req_toggle),
    .frame_snap_src_ack_toggle(frame_snap_src_ack_toggle),
    .frame_snap_src_ack_payload(frame_snap_src_ack_payload),
    .stat_frame_snap_status(frame_snap_status_core),
    .stat_frame_snap_seq(frame_snap_seq_core),
    .stat_frame_snap_bank0_gen(frame_snap_bank0_gen_core),
    .stat_frame_snap_bank1_gen(frame_snap_bank1_gen_core),
    .stat_frame_snap_rom_epoch(frame_snap_rom_epoch_core),
    .save_snap_src_valid(save_snap_src_valid),
    .save_snap_src_payload(save_snap_src_payload),
    .save_snap_src_ready(save_snap_src_ready),
    .save_snap_src_req_toggle(save_snap_src_req_toggle),
    .save_snap_src_ack_toggle(save_snap_src_ack_toggle),
    .save_snap_src_ack_payload(save_snap_src_ack_payload),
    .stat_save_snap_counters(save_snap_counters_core),
    .stat_save_snap_status(save_snap_status_core),
    .stat_save_snap_sram_gen(save_snap_sram_gen_core),
    .stat_save_snap_flash_gen(save_snap_flash_gen_core),
    .stat_save_snap_eeprom_gen(save_snap_eeprom_gen_core),
    .save_ack_src_valid(save_ack_src_valid),
    .save_ack_src_payload(save_ack_src_payload),
    .save_ack_src_ready(save_ack_src_ready),
    .save_ack_src_req_toggle(save_ack_src_req_toggle),
    .save_ack_src_ack_toggle(save_ack_src_ack_toggle),
    .save_ack_src_ack_payload(save_ack_src_ack_payload),
    .cfg_feature_ctrl    (w_axi_feature_ctrl),
    .cfg_feature_action_save_toggle(w_axi_feature_action_save_toggle),
    .cfg_feature_action_load_toggle(w_axi_feature_action_load_toggle),
    .cfg_feature_action_cheat_push_toggle(w_axi_feature_action_cheat_push_toggle),
    .cfg_feature_action_cheat_clear_toggle(w_axi_feature_action_cheat_clear_toggle),
    .cfg_feature_action_rtc_new_toggle(w_axi_feature_action_rtc_new_toggle),
    .cfg_savestate_slot  (w_axi_savestate_slot),
    .cfg_cheat_flags     (w_axi_cheat_flags),
    .cfg_cheat_addr      (w_axi_cheat_addr),
    .cfg_cheat_compare   (w_axi_cheat_compare),
    .cfg_cheat_replace   (w_axi_cheat_replace),
    .cfg_sensor_input    (w_axi_sensor_input),
    .cfg_rtc_in_savedtime_lo(w_axi_rtc_in_savedtime_lo),
    .cfg_rtc_in_savedtime_hi(w_axi_rtc_in_savedtime_hi)
  );

  // @instance-role: u_config_mgr 把 AXI 寄存器域的配置、动作 toggle 和板级按键同步到 GBA core 时钟域。
  gba_config_mgr u_config_mgr (
    .clk_axi               (s_axi_aclk),
    .clk_core              (clk_100),
    .rst_axi_n             (s_axi_aresetn),
    .rst_core_n            (rst_n),
    .cfg_ctrl_axi          (w_axi_cfg_ctrl),
    .cfg_keys_axi          (w_axi_cfg_keys),
    .cfg_max_pak_addr_axi  (w_axi_cfg_max_pak_addr),
    .cfg_cycle_precalc_axi (w_axi_cfg_cycle_precalc),
    .cfg_rtc_timestamp_axi (w_axi_cfg_rtc_timestamp),
    .cfg_rtc_timestamp_saved_axi(w_axi_cfg_rtc_timestamp_saved),
    .cfg_display_frame_idx_axi(w_axi_display_frame_idx),
    .cfg_commit_toggle_axi (w_axi_cfg_commit_toggle),
    .cfg_feature_ctrl_axi  (w_axi_feature_ctrl),
    .cfg_savestate_slot_axi(w_axi_savestate_slot),
    .cfg_cheat_flags_axi   (w_axi_cheat_flags),
    .cfg_cheat_addr_axi    (w_axi_cheat_addr),
    .cfg_cheat_compare_axi (w_axi_cheat_compare),
    .cfg_cheat_replace_axi (w_axi_cheat_replace),
    .cfg_sensor_input_axi  (w_axi_sensor_input),
    .cfg_rtc_savedtime_lo_axi(w_axi_rtc_in_savedtime_lo),
    .cfg_rtc_savedtime_hi_axi(w_axi_rtc_in_savedtime_hi),
    .cfg_action_save_toggle_axi(w_axi_feature_action_save_toggle),
    .cfg_action_load_toggle_axi(w_axi_feature_action_load_toggle),
    .cfg_action_cheat_push_toggle_axi(w_axi_feature_action_cheat_push_toggle),
    .cfg_action_cheat_clear_toggle_axi(w_axi_feature_action_cheat_clear_toggle),
    .cfg_action_rtc_new_toggle_axi(w_axi_feature_action_rtc_new_toggle),
    .btns                  (btns),
    .sws                   (sws),
    .cfg_ctrl_core         (w_core_cfg_ctrl),
    .cfg_keys_core         (w_core_cfg_keys),
    .physical_keys_core    (w_core_physical_keys),
    .cfg_max_pak_addr_core (w_core_cfg_max_pak_addr),
    .cfg_cycle_precalc_core(w_core_cfg_cycle_precalc),
    .cfg_rtc_timestamp_core(w_core_cfg_rtc_timestamp),
    .cfg_rtc_timestamp_saved_core(w_core_cfg_rtc_timestamp_saved),
    .cfg_display_frame_idx_core(w_core_display_frame_idx),
    .cfg_feature_ctrl_core (w_core_feature_ctrl),
    .cfg_savestate_slot_core(w_core_savestate_slot),
    .cfg_cheat_flags_core  (w_core_cheat_flags),
    .cfg_cheat_addr_core   (w_core_cheat_addr),
    .cfg_cheat_compare_core(w_core_cheat_compare),
    .cfg_cheat_replace_core(w_core_cheat_replace),
    .cfg_sensor_solar_core (w_core_sensor_solar),
    .cfg_sensor_tilt_x_core(w_core_sensor_tilt_x),
    .cfg_sensor_tilt_y_core(w_core_sensor_tilt_y),
    .cfg_rtc_savedtime_core(w_core_rtc_savedtime),
    .cfg_rtc_save_loaded_core(w_core_rtc_save_loaded),
    .pulse_save_state_core (w_core_pulse_save_state),
    .pulse_load_state_core (w_core_pulse_load_state),
    .pulse_cheat_push_core (w_core_pulse_cheat_push),
    .pulse_cheat_clear_core(w_core_pulse_cheat_clear),
    .pulse_rtc_new_core    (w_core_pulse_rtc_new)
  );

  // ==========================================================================
  // --- 第二层：音频处理单元 (Audio Unit) ---
  // ==========================================================================
  // 责任：将核心 PCM 流转换为串行 I2S 协议
  
  // @instance-role: u_i2s_transmitter 把 core 产生的左右声道采样转换成板级音频 codec 需要的 I2S/PCM 时序。
  i2s_transmitter u_audio_out (
    .clk_100               (clk_100),
    .rst_n                 (rst_n),
    .audio_l               (audio_out_l),
    .audio_r               (audio_out_r),
    .ac_mclk               (ac_mclk),
    .ac_bclk               (ac_bclk),
    .ac_pblrc              (ac_pblrc),
    .ac_pbdat              (ac_pbdat),
    .ac_muten              (ac_muten),
    .sample_ce             (audio_sample_ce)
  );

  // 系统统计/指示灯映射
  assign leds[0] = audio_out_l[15];      // 播放活动指示
  assign leds[1] = ddram_busy;           // 内存活动指示
  assign leds[2] = |{audio_out_l, audio_out_r};  // 音频信号检测
  assign leds[3] = w_core_cfg_sw_reset;  // 软复位状态指示

  // ==========================================================================
  // --- 第三层：GBA 核心与内存中枢 (Core & Memory Hub) ---
  // ==========================================================================
  // 责任：运行 GBA 核心逻辑并管理其复杂的 DDR 访问路径
  
  gba_top #(
    .Softmap_GBA_FLASH_ADDR   (0),
    .Softmap_GBA_EEPROM_ADDR  (32768),
    .Softmap_GBA_WRam_ADDR    (131072),
    .Softmap_GBA_Gamerom_ADDR (196608),
    .Softmap_SaveState_ADDR   (67108864),
    .Softmap_Rewind_ADDR      (33554432),
    .turbosound               (1'b0)
  ) u_core (
    .clk100                (clk_100),
    .GBA_on                (w_core_cfg_ctrl[0] & ~w_core_cfg_sw_reset), // 核心使能受软复位控制
    .GBA_lockspeed         (w_core_cfg_ctrl[1]),
    .GBA_cputurbo          (w_core_cfg_ctrl[2]),
    .GBA_flash_1m          (w_core_cfg_ctrl[9]),
    .CyclePrecalc          (w_core_cfg_cycle_precalc),
    .Underclock            (GBA_UNDERCLOCK_OFF),
    .MaxPakAddr            (w_core_cfg_max_pak_addr),
    .CyclesMissing         (cycles_missing),
    .CyclesVsyncSpeed      (cycles_vsync_speed),
    .SramFlashEnable       (w_core_cfg_ctrl[4]),
    .Sram32KMirrorTest     (w_core_cfg_ctrl[13]),
    .memory_remap          (w_core_cfg_ctrl[5]),
    .increaseSSHeaderCount (1'b0),
    .save_state            (w_core_pulse_save_state),
    .load_state            (w_core_pulse_load_state),
    .interframe_blend      (2'b00),
    .maxpixels             (1'b0),
    .shade_mode            (3'b000),
    .hdmode2x_bg           (1'b0),
    .hdmode2x_obj          (1'b0),
    .specialmodule         (w_core_cfg_ctrl[10]),
    .solar_in              (w_core_sensor_solar),
    .tilt                  (w_core_cfg_ctrl[11]),
    .rewind_on             (w_core_feature_ctrl[0]),
    .rewind_active         (w_core_rewind_active),
    .savestate_number      ({29'd0, w_core_savestate_slot}),
    .RTC_timestampNew      (w_core_pulse_rtc_new),
    .RTC_timestampIn       (w_core_cfg_rtc_timestamp),
    .RTC_timestampSaved    (w_core_cfg_rtc_timestamp_saved),
    .RTC_savedtimeIn       (w_core_rtc_savedtime),
    .RTC_saveLoaded        (w_core_rtc_save_loaded),
    .RTC_timestampOut      (core_rtc_timestamp_out),
    .RTC_savedtimeOut      (core_rtc_savedtime_out),
    .RTC_inuse             (core_rtc_inuse),
    .cheat_clear           (w_core_pulse_cheat_clear),
    .cheats_enabled        (w_core_feature_ctrl[1]),
    .cheat_on              (w_core_pulse_cheat_push),
    .cheat_in              ({w_core_cheat_flags, w_core_cheat_addr, w_core_cheat_compare, w_core_cheat_replace}),
    .cheats_active         (core_cheats_active),

    // SDRAM 通道 1 (Core Instruction/Data Fetch)
    .sdram_read_ena        (sdram_read_ena),
    .sdram_read_done       (sdram_read_done),
    .sdram_read_addr       (sdram_read_addr),
    .sdram_read_data       (sdram_read_data),
    .sdram_second_dword    (sdram_second_dword),

    // 总线通道 2 (Generic Bus)
    .bus_out_Din           (bus_out_din),
    .bus_out_Dout          (bus_out_dout),
    .bus_out_Adr           (bus_out_adr),
    .bus_out_rnw           (bus_out_rnw),
    .bus_out_ena           (bus_out_ena),
    .bus_out_done          (bus_out_done),

    // 保存通道 4 (Save States / SRAM)
    .SAVE_out_Din          (save_out_din),
    .SAVE_out_Dout         (save_out_dout),
    .SAVE_out_Adr          (save_out_adr),
    .SAVE_out_rnw          (save_out_rnw),
    .SAVE_out_ena          (save_out_ena),
    .SAVE_out_active       (save_out_active),
    .SAVE_out_be           (save_out_be),
    .SAVE_out_done         (save_out_done),

    .bios_wraddr           (bios_wr_addr_core),
    .bios_wrdata           (bios_wr_data_core),
    .bios_wr               (bios_wr_core),
    .save_eeprom           (unused_save_eeprom),
    .save_sram             (unused_save_sram),
    .save_flash            (unused_save_flash),
    .load_done             (core_load_done),

    // 输入映射
    .KeyA                  (w_core_cfg_keys[0]),
    .KeyB                  (w_core_cfg_keys[1]),
    .KeySelect             (w_core_cfg_keys[2]),
    .KeyStart              (w_core_cfg_keys[3]),
    .KeyRight              (w_core_cfg_keys[4]),
    .KeyLeft               (w_core_cfg_keys[5]),
    .KeyUp                 (w_core_cfg_keys[6]),
    .KeyDown               (w_core_cfg_keys[7]),
    .KeyR                  (w_core_cfg_keys[8]),
    .KeyL                  (w_core_cfg_keys[9]),
    .AnalogTiltX           (w_core_sensor_tilt_x),
    .AnalogTiltY           (w_core_sensor_tilt_y),
    .Rumble                (core_rumble),
    .GBA_BusAddr           (28'd0),
    .GBA_BusRnW            (1'b0),
    .GBA_BusACC            (2'b00),
    .GBA_BusWriteData      (32'd0),
    .GBA_BusReadData       (unused_bus_read_data),
    .GBA_Bus_written       (1'b0),
    .pixel_out_x           (),
    .pixel_out_y           (),
    .pixel_out_addr        (core_pixel_addr),
    .pixel_out_data        (core_pixel_data),
    .pixel_out_we          (core_pixel_we),

    // 复用 core 内部原生的 largeimg 打包链路，让 framebuffer 写入
    .largeimg_out_base     (unused_core_fb_base),
    .largeimg_out_addr     (unused_core_fb_addr),
    .largeimg_out_data     (unused_core_fb_data),
    .largeimg_out_req      (unused_core_fb_req),
    .largeimg_out_done     (core_fb_done),
    .largeimg_newframe     (core_fb_newframe),
    .largeimg_singlebuf    (1'b0),

    // 音频流输出
    .sound_out_left        (core_audio_l),
    .sound_out_right       (core_audio_r),
    .debug_cpu_pc          (unused_debug_cpu_pc),
    .debug_cpu_mixed       (unused_debug_cpu_mixed),
    .debug_cpu_r0          (unused_debug_cpu_r0),
    .debug_cpu_r1          (unused_debug_cpu_r1),
    .debug_cpu_r2          (unused_debug_cpu_r2),
    .debug_cpu_r4          (unused_debug_cpu_r4),
    .debug_cpu_cpuset      (unused_debug_cpu_cpuset),
    .debug_irq             (unused_debug_irq),
    .debug_irq_ext         (unused_debug_irq_ext),
    .debug_dma             (unused_debug_dma),
    .debug_mem             (unused_debug_mem),
    .debug_vram_regs0      (unused_debug_vram_regs0),
    .debug_vram_regs1      (unused_debug_vram_regs1),
    .debug_vram_regs2      (unused_debug_vram_regs2),
    .debug_vram_regs3      (unused_debug_vram_regs3),
    .debug_vram_regs4      (unused_debug_vram_regs4),
    .debug_vram_hits       (unused_debug_vram_hits),
    .debug_vram_ring0      (unused_debug_vram_ring0),
    .debug_vram_ring1      (unused_debug_vram_ring1),
    .debug_vram_ring2      (unused_debug_vram_ring2),
    .debug_vram_ring3      (unused_debug_vram_ring3),
    .debug_vram_dist0      (unused_debug_vram_dist0),
    .debug_vram_dist1      (unused_debug_vram_dist1),
    .debug_dma_tr0         (unused_debug_dma_tr0),
    .debug_dma_tr1         (unused_debug_dma_tr1),
    .debug_dma_tr2         (unused_debug_dma_tr2),
    .debug_dma_tr3         (unused_debug_dma_tr3),
    .debug_dma_tr4         (unused_debug_dma_tr4),
    .debug_dma_tr5         (unused_debug_dma_tr5),
    .debug_dma_tr6         (unused_debug_dma_tr6),
    .debug_dma_tr7         (unused_debug_dma_tr7),
    .debug_dma_tr8         (unused_debug_dma_tr8),
    .debug_wait0           (unused_debug_wait0),
    .debug_wait1           (unused_debug_wait1),
    .debug_wait2           (unused_debug_wait2),
    .debug_wait3           (unused_debug_wait3),
    .debug_internal         (core_debug_internal)
  );

  // @instance-role: u_frame_capture_bram 提供 PS 可读的帧抓取缓冲，把 core 像素写入与 AXI/显示读取隔离。
  gba_frame_capture_bram u_fb_capture (
    .wr_clk            (clk_100),
    .wr_rst_n          (rst_n),
    .pixel_addr        (core_pixel_addr),
    .pixel_data        (core_pixel_data),
    .pixel_we          (core_pixel_we),
    .frame_seq         (fbcap_frame_seq),
    .frame_buf_idx     (fbcap_frame_buf_idx),
    .frame_status      (frame_status_core),
    .bank0_gen         (frame_bank0_gen_core),
    .bank1_gen         (frame_bank1_gen_core),
    .bram_clk_b        (fb_cap_bram_clk),
    .bram_rst_b        (fb_cap_bram_rst),
    .bram_en_b         (fb_cap_bram_en),
    .bram_we_b         (fb_cap_bram_we),
    .bram_addr_b       (fb_cap_bram_addr),
    .bram_din_b        (fb_cap_bram_din),
    .bram_dout_b       (fb_cap_bram_dout)
  );

  // Debug/status snapshots also refresh on physical key changes so the PS
  // menu can read board buttons when no game frame is being produced.
  // While the one-entry mailbox is busy, pending captures coalesce to the
  // latest synchronized key state.
  always @(posedge clk_100) begin
    if (!rst_n) begin
      mem_diag_seen_core <= 69'd0;
      physical_keys_seen_core <= 10'd0;
      debug_snapshot_pending_core <= 1'b0;
    end else if (fb_frame_pulse || sys_err_pulse_w || unused_save_sram ||
                 unused_save_flash || unused_save_eeprom || mem_diag_changed ||
                 physical_keys_changed) begin
      mem_diag_seen_core <= mem_diag_current;
      physical_keys_seen_core <= w_core_physical_keys;
      debug_snapshot_pending_core <= 1'b1;
    end else if (debug_snapshot_src_valid) begin
      debug_snapshot_pending_core <= 1'b0;
    end
  end

  // Snapshot payload registers remain stable from destination capture until
  // the next request from their independent owner mailbox.
  always @(posedge clk_100) begin
    if (!rst_n) begin
      frame_snap_status_core <= 32'd0;
      frame_snap_seq_core <= 32'd0;
      frame_snap_bank0_gen_core <= 32'd0;
      frame_snap_bank1_gen_core <= 32'd0;
      frame_snap_rom_epoch_core <= 32'd0;
      save_sram_gen_core <= 32'd0;
      save_flash_gen_core <= 32'd0;
      save_eeprom_gen_core <= 32'd0;
      save_sram_dirty_core <= 1'b0;
      save_flash_dirty_core <= 1'b0;
      save_eeprom_dirty_core <= 1'b0;
      save_sram_busy_count_core <= 3'd0;
      save_flash_busy_count_core <= 3'd0;
      save_eeprom_busy_count_core <= 3'd0;
      save_kind_fifo_wr_ptr <= 2'd0;
      save_kind_fifo_rd_ptr <= 2'd0;
      save_kind_fifo_count <= 3'd0;
      for (save_fifo_index = 0; save_fifo_index < 4; save_fifo_index = save_fifo_index + 1)
        save_kind_fifo[save_fifo_index] <= 2'd3;
      save_snap_counters_core <= 32'd0;
      save_snap_status_core <= 32'd0;
      save_snap_sram_gen_core <= 32'd0;
      save_snap_flash_gen_core <= 32'd0;
      save_snap_eeprom_gen_core <= 32'd0;
    end else begin
      if (frame_snap_dst_valid) begin
        frame_snap_status_core <= frame_status_core;
        frame_snap_seq_core <= fbcap_frame_seq;
        frame_snap_bank0_gen_core <= frame_bank0_gen_core;
        frame_snap_bank1_gen_core <= frame_bank1_gen_core;
        frame_snap_rom_epoch_core <= rom_epoch_core;
      end

      if (save_snap_dst_valid) begin
        save_snap_counters_core <= {8'd0, save_eeprom_count_core,
                                    save_flash_count_core, save_sram_count_core};
        save_snap_status_core <= save_snap_status_live;
        save_snap_sram_gen_core <= save_sram_gen_core;
        save_snap_flash_gen_core <= save_flash_gen_core;
        save_snap_eeprom_gen_core <= save_eeprom_gen_core;
      end

      if (save_ack_dst_valid) begin
        case (save_ack_dst_payload[65:64])
          `PS_PL_SAVE_KIND_SRAM: begin
            if ((save_ack_dst_payload[63:32] == save_sram_gen_core) &&
                (save_sram_busy_count_core == 0) &&
                !unused_save_sram) begin
              save_sram_dirty_core <= 1'b0;
            end
          end
          `PS_PL_SAVE_KIND_FLASH: begin
            if ((save_ack_dst_payload[63:32] == save_flash_gen_core) &&
                (save_flash_busy_count_core == 0) &&
                !unused_save_flash) begin
              save_flash_dirty_core <= 1'b0;
            end
          end
          `PS_PL_SAVE_KIND_EEPROM: begin
            if ((save_ack_dst_payload[63:32] == save_eeprom_gen_core) &&
                (save_eeprom_busy_count_core == 0) &&
                !unused_save_eeprom) begin
              save_eeprom_dirty_core <= 1'b0;
            end
          end
          default: begin
            // Unsupported kinds are acknowledged without changing save state.
          end
        endcase
      end

      if (save_write_push_valid_core) begin
        save_kind_fifo[save_kind_fifo_wr_ptr] <= save_write_kind_supported_core
                                                   ? save_write_kind_core : 2'd3;
        save_kind_fifo_wr_ptr <= save_kind_fifo_wr_ptr + 2'd1;
      end
      if (save_write_pop_valid_core) begin
        save_kind_fifo_rd_ptr <= save_kind_fifo_rd_ptr + 2'd1;
      end
      case ({save_write_push_valid_core, save_write_pop_valid_core})
        2'b10: save_kind_fifo_count <= save_kind_fifo_count + 3'd1;
        2'b01: save_kind_fifo_count <= save_kind_fifo_count - 3'd1;
        default: begin end
      endcase

      case ({save_write_push_valid_core && save_write_kind_core == `PS_PL_SAVE_KIND_SRAM,
             save_write_pop_valid_core && save_write_retired_kind_core == `PS_PL_SAVE_KIND_SRAM})
        2'b10: save_sram_busy_count_core <= save_sram_busy_count_core + 3'd1;
        2'b01: save_sram_busy_count_core <= save_sram_busy_count_core - 3'd1;
        default: begin end
      endcase
      case ({save_write_push_valid_core && save_write_kind_core == `PS_PL_SAVE_KIND_FLASH,
             save_write_pop_valid_core && save_write_retired_kind_core == `PS_PL_SAVE_KIND_FLASH})
        2'b10: save_flash_busy_count_core <= save_flash_busy_count_core + 3'd1;
        2'b01: save_flash_busy_count_core <= save_flash_busy_count_core - 3'd1;
        default: begin end
      endcase
      case ({save_write_push_valid_core && save_write_kind_core == `PS_PL_SAVE_KIND_EEPROM,
             save_write_pop_valid_core && save_write_retired_kind_core == `PS_PL_SAVE_KIND_EEPROM})
        2'b10: save_eeprom_busy_count_core <= save_eeprom_busy_count_core + 3'd1;
        2'b01: save_eeprom_busy_count_core <= save_eeprom_busy_count_core - 3'd1;
        default: begin end
      endcase

      if (unused_save_sram) begin
        save_sram_gen_core <= save_sram_gen_core + 32'd1;
        save_sram_dirty_core <= 1'b1;
      end
      if (unused_save_flash) begin
        save_flash_gen_core <= save_flash_gen_core + 32'd1;
        save_flash_dirty_core <= 1'b1;
      end
      if (unused_save_eeprom) begin
        save_eeprom_gen_core <= save_eeprom_gen_core + 32'd1;
        save_eeprom_dirty_core <= 1'b1;
      end

    end
  end

  // 内存仲裁与总线打包
  assign ch1_addr = {1'b0, sdram_read_addr, 1'b0};
  assign ch1_din  = 64'd0;
  assign ch1_req  = sdram_read_ena;
  assign ch1_rnw  = 1'b1;

  assign ch2_addr = {bus_out_adr, 1'b0};
  assign ch2_din  = {32'd0, bus_out_din};
  assign ch2_req  = bus_out_ena;
  assign ch2_rnw  = bus_out_rnw;

  assign ch3_addr = 25'd0;
  assign ch3_din  = 16'd0;
  assign ch3_req  = 1'b0;
  assign ch3_rnw  = 1'b1;

  assign ch4_addr = {save_out_adr, 1'b0};
  assign ch4_din  = save_out_din;
  assign ch4_req  = save_out_ena;
  assign ch4_rnw  = save_out_rnw;
  assign ch4_be   = save_out_be;

  // @instance-role: u_ddram_mux 汇聚 CPU/GPU/音频/抓帧等 DDRAM 通道，向 AXI DDR 后端输出单一仲裁后的读写请求。
  ddram_mux u_ddram_mux (
    .DDRAM_CLK        (clk_100),
    .rst_n            (rst_n),
    .DDRAM_BUSY       (ddram_busy),
    .DDRAM_BURSTCNT   (ddram_burstcnt),
    .DDRAM_ADDR       (ddram_addr),
    .DDRAM_DOUT       (ddram_dout),
    .DDRAM_DOUT_READY (ddram_dout_ready),
    .DDRAM_DONE       (ddram_done),
    .DDRAM_RD         (ddram_rd),
    .DDRAM_DIN        (ddram_din),
    .DDRAM_BE         (ddram_be),
    .DDRAM_WE         (ddram_we),
    .CFG_ROM_DDR_SAFE (w_core_rom_ddr_safe),
    .MEM_CMD_VALID    (mem_cmd_dst_valid),
    .MEM_CMD_PAYLOAD  (mem_cmd_dst_payload),
    .MEM_CMD_ACK_ENABLE(debug_snapshot_src_ready && !debug_snapshot_pending_core && !mem_diag_changed),
    .MEM_CMD_READY    (mem_cmd_dst_ready),
    .ch4_write_done   (ch4_write_done),
    .MEM_ACCEPT_NEW   (ddram_accept_new),
    .DDRAM_ERR_PULSE  (sys_err_pulse_w),
    .DDRAM_ERR_VEC    (sys_err_vec_w),
    .DDRAM_FATAL_FAULT(ddram_fatal_fault),
    .MEM_STATUS       (mem_status_core),
    .MEM_ERROR        (mem_error_core),
    .MEM_ERROR_ADDR   (mem_error_addr_core),
    .ROM_EPOCH        (rom_epoch_core),
    .ch1_addr(ch1_addr), .ch1_dout(ch1_dout), .ch1_din(ch1_din[15:0]), .ch1_req(ch1_req), .ch1_rnw(ch1_rnw), .ch1_ready(sdram_read_done),
    .ch2_addr(ch2_addr), .ch2_dout(ch2_dout),     .ch2_din(ch2_din[31:0]), .ch2_req(ch2_req), .ch2_rnw(ch2_rnw), .ch2_ready(bus_out_done),
    .ch3_addr(ch3_addr), .ch3_dout(ch3_dout_unused), .ch3_din(ch3_din), .ch3_req(ch3_req), .ch3_rnw(ch3_rnw), .ch3_ready(ch3_ready_unused),
    .ch4_addr(ch4_addr), .ch4_dout(ch4_dout), .ch4_din(ch4_din), .ch4_req(ch4_req), .ch4_rnw(ch4_rnw), .ch4_be(ch4_be), .ch4_ready(save_out_done),
    .ch5_addr(27'd0), .ch5_dout(), .ch5_din(64'd0), .ch5_req(1'b0), .ch5_rnw(1'b1), .ch5_ready()
  );

  assign sdram_read_data = ch1_dout[31:0];
  assign sdram_second_dword = ch1_dout[63:32];
  assign bus_out_dout = ch2_dout[31:0];
  assign save_out_dout = ch4_dout;

  ddr_axi_backend_sv #(
    .G_DDR_BASE (G_DDR_BASE)
  ) u_backend (
    .clk(clk_100), .rst_n(rst_n),
    .DDRAM_BUSY(ddram_busy), .DDRAM_BURSTCNT(ddram_burstcnt), .DDRAM_ADDR(ddram_addr),
    .DDRAM_DOUT(ddram_dout), .DDRAM_DOUT_READY(ddram_dout_ready), .DDRAM_DONE(ddram_done),
    .DDRAM_RD(ddram_rd),
    .DDRAM_DIN(ddram_din), .DDRAM_BE(ddram_be), .DDRAM_WE(ddram_we),
    .M_AXI_AWADDR(M_AXI_AWADDR), .M_AXI_AWLEN(M_AXI_AWLEN), .M_AXI_AWSIZE(M_AXI_AWSIZE), .M_AXI_AWBURST(M_AXI_AWBURST),
    .M_AXI_AWVALID(M_AXI_AWVALID), .M_AXI_AWREADY(M_AXI_AWREADY), .M_AXI_WDATA(M_AXI_WDATA), .M_AXI_WSTRB(M_AXI_WSTRB),
    .M_AXI_WLAST(M_AXI_WLAST), .M_AXI_WVALID(M_AXI_WVALID), .M_AXI_WREADY(M_AXI_WREADY), .M_AXI_BRESP(M_AXI_BRESP),
    .M_AXI_BVALID(M_AXI_BVALID), .M_AXI_BREADY(M_AXI_BREADY), .M_AXI_ARADDR(M_AXI_ARADDR), .M_AXI_ARLEN(M_AXI_ARLEN),
    .M_AXI_ARSIZE(M_AXI_ARSIZE), .M_AXI_ARBURST(M_AXI_ARBURST), .M_AXI_ARVALID(M_AXI_ARVALID), .M_AXI_ARREADY(M_AXI_ARREADY),
    .M_AXI_RDATA(M_AXI_RDATA), .M_AXI_RRESP(M_AXI_RRESP), .M_AXI_RLAST(M_AXI_RLAST), .M_AXI_RVALID(M_AXI_RVALID), .M_AXI_RREADY(M_AXI_RREADY),
    .ERR_VEC(sys_err_vec_w), .ERR_PULSE(sys_err_pulse_w),
    .FATAL_FAULT(ddram_fatal_fault)
  );

  assign fb_frame_pulse = core_fb_newframe;
  assign core_fb_done = 1'b1;

endmodule
