//------------------------------------------------------------------------------
// @file axi_lite_ctrl_regs.sv
// @module-contract
// 职责: PS 控制寄存器窗口；AXI4-Lite 控制/状态寄存器文件，提供 ROM/运行状态/调试/扩展功能的 PS 访问窗口。
// 上游: PS 软件通过 AXI4-Lite 读写。
// 邮箱契约: 软件先写完整payload与seq，再把REQ_TOGGLE写成当前bit异或1；
// 每个owner单笔在途。payload只在source-ready时可改，AXI写请求始终正常响应。
// 下游: 配置管理器、BIOS 写口、IRQ 线、调试状态采样。
// 时钟域: clk100/clk_core/clk_100/s_axi_aclk 等，具体以端口命名为准。
// 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
// 关键协议: AXI valid/ready、写 strobe、读写响应和中断/错误状态按寄存器或总线协议传递。
// 设计注意点: 把软件寄存器映射成硬件配置位和动作 toggle，同时把 core/DDR/视频状态打包给 PS 读取；本注释只解释设计意图，不改变 RTL/XDC 功能。
//------------------------------------------------------------------------------
`include "ps_pl_contract_generated.vh"

module axi_lite_ctrl_regs #(
  parameter int ADDR_W = 12,
  parameter int DATA_W = 32
) (
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic [ADDR_W-1:0]    s_axi_awaddr,
  input  logic                 s_axi_awvalid,
  output logic                 s_axi_awready,
  input  logic [DATA_W-1:0]    s_axi_wdata,
  input  logic [(DATA_W/8)-1:0] s_axi_wstrb,
  input  logic                 s_axi_wvalid,
  output logic                 s_axi_wready,
  output logic [1:0]           s_axi_bresp,
  output logic                 s_axi_bvalid,
  input  logic                 s_axi_bready,

  input  logic [ADDR_W-1:0]    s_axi_araddr,
  input  logic                 s_axi_arvalid,
  output logic                 s_axi_arready,
  output logic [DATA_W-1:0]    s_axi_rdata,
  output logic [1:0]           s_axi_rresp,
  output logic                 s_axi_rvalid,
  input  logic                 s_axi_rready,

  input  logic [13:0]          stat_cycles_missing,
  input  logic [15:0]          stat_cycles_vsync_speed,
  input  logic [1:0]           stat_fb_frame_idx,
  input  logic [9:0]           stat_physical_keys,
  input  logic [31:0]          stat_debug_cpu_pc,
  input  logic [31:0]          stat_debug_cpu_mixed,
  input  logic [31:0]          stat_debug_cpu_r0,
  input  logic [31:0]          stat_debug_cpu_r1,
  input  logic [31:0]          stat_debug_cpu_r2,
  input  logic [31:0]          stat_debug_cpu_r4,
  input  logic [31:0]          stat_debug_cpu_cpuset,
  input  logic [31:0]          stat_ddr_atom_word0,
  input  logic [31:0]          stat_ddr_atom_word1,
  input  logic [31:0]          stat_ddr_atom_next0,
  input  logic [31:0]          stat_ddr_atom_next1,
  input  logic [31:0]          stat_ddr_atom_stat,
  input  logic [31:0]          stat_debug_irq,
  input  logic [31:0]          stat_debug_irq_ext,
  input  logic [31:0]          stat_debug_dma,
  input  logic [31:0]          stat_debug_mem,
  input  logic [31:0]          stat_debug_vram_regs0,
  input  logic [31:0]          stat_debug_vram_regs1,
  input  logic [31:0]          stat_debug_vram_regs2,
  input  logic [31:0]          stat_debug_vram_regs3,
  input  logic [31:0]          stat_debug_vram_regs4,
  input  logic [31:0]          stat_debug_vram_hits,
  input  logic [31:0]          stat_debug_vram_ring0,
  input  logic [31:0]          stat_debug_vram_ring1,
  input  logic [31:0]          stat_debug_vram_ring2,
  input  logic [31:0]          stat_debug_vram_ring3,
  input  logic [31:0]          stat_debug_vram_dist0,
  input  logic [31:0]          stat_debug_vram_dist1,
  input  logic [31:0]          stat_debug_dma_tr0,
  input  logic [31:0]          stat_debug_dma_tr1,
  input  logic [31:0]          stat_debug_dma_tr2,
  input  logic [31:0]          stat_debug_dma_tr3,
  input  logic [31:0]          stat_debug_dma_tr4,
  input  logic [31:0]          stat_debug_dma_tr5,
  input  logic [31:0]          stat_debug_dma_tr6,
  input  logic [31:0]          stat_debug_dma_tr7,
  input  logic [31:0]          stat_debug_dma_tr8,
  input  logic [31:0]          stat_debug_wait0,
  input  logic [31:0]          stat_debug_wait1,
  input  logic [31:0]          stat_debug_wait2,
  input  logic [31:0]          stat_debug_wait3,
  input  logic [31:0]          stat_debug_audio_status,
  input  logic [31:0]          stat_dbg_chain_flags,
  input  logic [31:0]          stat_dbg_chain_counts0,
  input  logic [31:0]          stat_dbg_chain_counts1,
  input  logic [31:0]          stat_dbg_ch1_first_addr,
  input  logic [31:0]          stat_dbg_ch1_first_meta,
  input  logic [31:0]          stat_dbg_ch1_last_addr,
  input  logic [31:0]          stat_dbg_ch1_last_meta,
  input  logic [31:0]          stat_dbg_ddr_first_addr,
  input  logic [31:0]          stat_dbg_ddr_first_meta,
  input  logic [31:0]          stat_dbg_ddr_last_addr,
  input  logic [31:0]          stat_dbg_ddr_last_meta,
  input  logic [31:0]          stat_dbg_axi_ar_first_addr,
  input  logic [31:0]          stat_dbg_axi_ar_first_meta,
  input  logic [31:0]          stat_dbg_axi_ar_last_addr,
  input  logic [31:0]          stat_dbg_axi_ar_last_meta,
  input  logic [31:0]          stat_dbg_axi_r_first_addr,
  input  logic [31:0]          stat_dbg_axi_r_first_meta,
  input  logic [31:0]          stat_dbg_axi_r_last_addr,
  input  logic [31:0]          stat_dbg_axi_r_last_meta,
  input  logic [31:0]          stat_dbg_done_first_addr,
  input  logic [31:0]          stat_dbg_done_first_meta,
  input  logic [31:0]          stat_dbg_done_last_addr,
  input  logic [31:0]          stat_dbg_done_last_meta,

  // High-level status
  input  logic                 sys_rom_loading,
  input  logic [31:0]          sys_error_in,

  // Granular Interrupt signals
  input  logic                 irq_vsync_pulse,
  input  logic                 irq_error_pulse,
  output logic                 irq_out,

  // Extended feature status from core domain (already AXI-synchronized by top)
  input  logic                 stat_feature_savestate_busy,
  input  logic                 stat_feature_load_done_pulse,
  input  logic                 stat_feature_rewind_active,
  input  logic                 stat_feature_rumble_out,
  input  logic                 stat_feature_cheats_active,
  input  logic                 stat_feature_rtc_inuse,
  input  logic [2:0]           stat_feature_slot_echo,
  input  logic [2:0]           stat_feature_solar_echo,
  input  logic [31:0]          stat_rtc_out_timestamp,
  input  logic [31:0]          stat_rtc_out_savedtime_lo,
  input  logic [31:0]          stat_rtc_out_savedtime_hi,

  output logic [31:0]          cfg_ctrl,
  output logic [9:0]           cfg_keys,
  output logic [24:0]          cfg_max_pak_addr,
  output logic [15:0]          cfg_cycle_precalc,
  output logic [31:0]          cfg_rtc_timestamp,
  output logic [31:0]          cfg_rtc_timestamp_saved,
  output logic [1:0]           cfg_display_frame_idx,
  output logic                 cfg_sw_reset,
  output logic                 cfg_commit_toggle,
  input  logic [31:0]          stat_fbcap_frame_seq,
  input  logic                 stat_fbcap_frame_buf_idx,
  input  logic [31:0]          stat_save_status,
  output logic [11:0]          cfg_bios_wr_addr,
  output logic [31:0]          cfg_bios_wr_data,
  output logic                 cfg_bios_wr_req_toggle,
  input  logic [31:0]          stat_bios_wr_ack_seq,
  output logic                 bios_wr_src_valid,
  output logic [43:0]          bios_wr_src_payload,
  input  logic                 bios_wr_src_ready,
  input  logic                 bios_wr_src_req_toggle,
  input  logic                 bios_wr_src_ack_toggle,
  input  logic [43:0]          bios_wr_src_ack_payload,

  // PS/PL contract status and one-entry mailbox endpoints (source side).
  input  logic [4:0]           stat_mem_status,
  input  logic [3:0]           stat_mem_error,
  input  logic [27:0]          stat_mem_error_addr,
  input  logic [31:0]          stat_rom_epoch,
  output logic [31:0]          cfg_mem_cmd,
  output logic [31:0]          cfg_mem_cmd_seq,
  output logic                 mem_cmd_src_valid,
  output logic [63:0]          mem_cmd_src_payload,
  input  logic                 mem_cmd_src_ready,
  input  logic                 mem_cmd_src_req_toggle,
  input  logic                 mem_cmd_src_ack_toggle,
  input  logic [63:0]          mem_cmd_src_ack_payload,

  output logic                 frame_snap_src_valid,
  output logic [31:0]          frame_snap_src_payload,
  input  logic                 frame_snap_src_ready,
  input  logic                 frame_snap_src_req_toggle,
  input  logic                 frame_snap_src_ack_toggle,
  input  logic [31:0]          frame_snap_src_ack_payload,
  input  logic [31:0]          stat_frame_snap_status,
  input  logic [31:0]          stat_frame_snap_seq,
  input  logic [31:0]          stat_frame_snap_bank0_gen,
  input  logic [31:0]          stat_frame_snap_bank1_gen,
  input  logic [31:0]          stat_frame_snap_rom_epoch,

  output logic                 save_snap_src_valid,
  output logic [31:0]          save_snap_src_payload,
  input  logic                 save_snap_src_ready,
  input  logic                 save_snap_src_req_toggle,
  input  logic                 save_snap_src_ack_toggle,
  input  logic [31:0]          save_snap_src_ack_payload,
  input  logic [31:0]          stat_save_snap_counters,
  input  logic [31:0]          stat_save_snap_status,
  input  logic [31:0]          stat_save_snap_sram_gen,
  input  logic [31:0]          stat_save_snap_flash_gen,
  input  logic [31:0]          stat_save_snap_eeprom_gen,

  output logic                 save_ack_src_valid,
  output logic [65:0]          save_ack_src_payload,
  input  logic                 save_ack_src_ready,
  input  logic                 save_ack_src_req_toggle,
  input  logic                 save_ack_src_ack_toggle,
  input  logic [65:0]          save_ack_src_ack_payload,

  output logic [5:0]           cfg_feature_ctrl,
  output logic                 cfg_feature_action_save_toggle,
  output logic                 cfg_feature_action_load_toggle,
  output logic                 cfg_feature_action_cheat_push_toggle,
  output logic                 cfg_feature_action_cheat_clear_toggle,
  output logic                 cfg_feature_action_rtc_new_toggle,
  output logic [2:0]           cfg_savestate_slot,
  output logic [31:0]          cfg_cheat_flags,
  output logic [31:0]          cfg_cheat_addr,
  output logic [31:0]          cfg_cheat_compare,
  output logic [31:0]          cfg_cheat_replace,
  output logic [23:0]          cfg_sensor_input,
  output logic [31:0]          cfg_rtc_in_savedtime_lo,
  output logic [31:0]          cfg_rtc_in_savedtime_hi
);

  localparam logic [ADDR_W-1:0] REG_CTRL            = 12'h000;
  localparam logic [ADDR_W-1:0] REG_KEYS            = 12'h004;
  localparam logic [ADDR_W-1:0] REG_MAX_PAK_ADDR    = 12'h008;
  localparam logic [ADDR_W-1:0] REG_CYCLE_PRECALC   = 12'h00C;
  localparam logic [ADDR_W-1:0] REG_RTC_TIMESTAMP   = 12'h010;
  localparam logic [ADDR_W-1:0] REG_COMMIT          = 12'h014;
  localparam logic [ADDR_W-1:0] REG_STATUS0         = 12'h018;
  localparam logic [ADDR_W-1:0] REG_STATUS1         = 12'h01C;
  localparam logic [ADDR_W-1:0] REG_SW_RESET        = 12'h020;
  localparam logic [ADDR_W-1:0] REG_ROM_STATUS      = 12'h024;
  localparam logic [ADDR_W-1:0] REG_ERROR_LATCH     = 12'h028;
  localparam logic [ADDR_W-1:0] REG_IRQ_EN          = 12'h02C;
  localparam logic [ADDR_W-1:0] REG_IRQ_STS         = 12'h030;
  localparam logic [ADDR_W-1:0] REG_DEBUG_CPU_PC    = 12'h034;
  localparam logic [ADDR_W-1:0] REG_DEBUG_CPU_MIX   = 12'h038;
  localparam logic [ADDR_W-1:0] REG_DEBUG_IRQ       = 12'h03C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA       = 12'h040;
  localparam logic [ADDR_W-1:0] REG_DEBUG_MEM       = 12'h044;
  localparam logic [ADDR_W-1:0] REG_DISPLAY_FRAME   = 12'h048;
  localparam logic [ADDR_W-1:0] REG_DBG_CHAIN_FLAGS       = 12'h04C;
  localparam logic [ADDR_W-1:0] REG_DBG_CHAIN_COUNTS0     = 12'h050;
  localparam logic [ADDR_W-1:0] REG_DBG_CHAIN_COUNTS1     = 12'h054;
  localparam logic [ADDR_W-1:0] REG_DBG_CH1_FIRST_ADDR    = 12'h058;
  localparam logic [ADDR_W-1:0] REG_DBG_CH1_FIRST_META    = 12'h05C;
  localparam logic [ADDR_W-1:0] REG_DBG_CH1_LAST_ADDR     = 12'h060;
  localparam logic [ADDR_W-1:0] REG_DBG_CH1_LAST_META     = 12'h064;
  localparam logic [ADDR_W-1:0] REG_DBG_DDR_FIRST_ADDR    = 12'h068;
  localparam logic [ADDR_W-1:0] REG_DBG_DDR_FIRST_META    = 12'h06C;
  localparam logic [ADDR_W-1:0] REG_DBG_DDR_LAST_ADDR     = 12'h070;
  localparam logic [ADDR_W-1:0] REG_DBG_DDR_LAST_META     = 12'h074;
  localparam logic [ADDR_W-1:0] REG_DBG_AXI_AR_FIRST_ADDR = 12'h078;
  localparam logic [ADDR_W-1:0] REG_DBG_AXI_AR_FIRST_META = 12'h07C;
  localparam logic [ADDR_W-1:0] REG_DBG_AXI_AR_LAST_ADDR  = 12'h080;
  localparam logic [ADDR_W-1:0] REG_DBG_AXI_AR_LAST_META  = 12'h084;
  localparam logic [ADDR_W-1:0] REG_DBG_AXI_R_FIRST_ADDR  = 12'h088;
  localparam logic [ADDR_W-1:0] REG_DBG_AXI_R_FIRST_META  = 12'h08C;
  localparam logic [ADDR_W-1:0] REG_DBG_AXI_R_LAST_ADDR   = 12'h090;
  localparam logic [ADDR_W-1:0] REG_DBG_AXI_R_LAST_META   = 12'h094;
  localparam logic [ADDR_W-1:0] REG_DBG_DONE_FIRST_ADDR   = 12'h098;
  localparam logic [ADDR_W-1:0] REG_DBG_DONE_FIRST_META   = 12'h09C;
  localparam logic [ADDR_W-1:0] REG_DBG_DONE_LAST_ADDR    = 12'h0A0;
  localparam logic [ADDR_W-1:0] REG_DBG_DONE_LAST_META    = 12'h0A4;
  localparam logic [ADDR_W-1:0] REG_FB_CAP_STATUS         = 12'h0A8;
  localparam logic [ADDR_W-1:0] REG_FB_CAP_SEQ            = 12'h0AC;
  localparam logic [ADDR_W-1:0] REG_SAVE_STATUS           = 12'h0B0;
  localparam logic [ADDR_W-1:0] REG_BIOS_WR_ADDR          = 12'h0B4;
  localparam logic [ADDR_W-1:0] REG_BIOS_WR_DATA          = 12'h0B8;
  localparam logic [ADDR_W-1:0] REG_BIOS_WR_REQ           = 12'h0BC;
  localparam logic [ADDR_W-1:0] REG_BIOS_WR_ACK           = 12'h0C0;
  localparam logic [ADDR_W-1:0] REG_FEATURE_CTRL          = 12'h0C4;
  localparam logic [ADDR_W-1:0] REG_FEATURE_ACTION        = 12'h0C8;
  localparam logic [ADDR_W-1:0] REG_SAVESTATE_SLOT        = 12'h0CC;
  localparam logic [ADDR_W-1:0] REG_CHEAT_FLAGS           = 12'h0D0;
  localparam logic [ADDR_W-1:0] REG_CHEAT_ADDR            = 12'h0D4;
  localparam logic [ADDR_W-1:0] REG_CHEAT_COMPARE         = 12'h0D8;
  localparam logic [ADDR_W-1:0] REG_CHEAT_REPLACE         = 12'h0DC;
  localparam logic [ADDR_W-1:0] REG_SENSOR_INPUT          = 12'h0E0;
  localparam logic [ADDR_W-1:0] REG_RTC_IN_SAVEDTIME_LO   = 12'h0E4;
  localparam logic [ADDR_W-1:0] REG_RTC_IN_SAVEDTIME_HI   = 12'h0E8;
  localparam logic [ADDR_W-1:0] REG_RTC_OUT_TIMESTAMP     = 12'h0EC;
  localparam logic [ADDR_W-1:0] REG_RTC_OUT_SAVEDTIME_LO  = 12'h0F0;
  localparam logic [ADDR_W-1:0] REG_RTC_OUT_SAVEDTIME_HI  = 12'h0F4;
  localparam logic [ADDR_W-1:0] REG_FEATURE_STATUS        = 12'h0F8;
  localparam logic [ADDR_W-1:0] REG_FEATURE_STATUS_CLR    = 12'h0FC;
  localparam logic [ADDR_W-1:0] REG_RTC_TIMESTAMP_SAVED   = 12'h100;
  localparam logic [ADDR_W-1:0] REG_DEBUG_IRQ_EXT         = 12'h104;
  localparam logic [ADDR_W-1:0] REG_DEBUG_CPU_R0          = 12'h108;
  localparam logic [ADDR_W-1:0] REG_DEBUG_CPU_R1          = 12'h10C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_CPU_R2          = 12'h110;
  localparam logic [ADDR_W-1:0] REG_DEBUG_CPU_R4          = 12'h114;
  localparam logic [ADDR_W-1:0] REG_DEBUG_CPU_CPUSET      = 12'h118;
  localparam logic [ADDR_W-1:0] REG_DDR_ATOM_WORD0        = 12'h11C;
  localparam logic [ADDR_W-1:0] REG_DDR_ATOM_WORD1        = 12'h120;
  localparam logic [ADDR_W-1:0] REG_DDR_ATOM_NEXT0        = 12'h124;
  localparam logic [ADDR_W-1:0] REG_DDR_ATOM_NEXT1        = 12'h128;
  localparam logic [ADDR_W-1:0] REG_DDR_ATOM_STAT         = 12'h12C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_REGS0      = 12'h130;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_REGS1      = 12'h134;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_REGS2      = 12'h138;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_REGS3      = 12'h13C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_REGS4      = 12'h140;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_HITS       = 12'h144;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_RING0      = 12'h148;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_RING1      = 12'h14C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_RING2      = 12'h150;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_RING3      = 12'h154;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_DIST0      = 12'h158;
  localparam logic [ADDR_W-1:0] REG_DEBUG_VRAM_DIST1      = 12'h15C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR0         = 12'h160;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR1         = 12'h164;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR2         = 12'h168;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR3         = 12'h16C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR4         = 12'h170;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR5         = 12'h174;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR6         = 12'h178;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR7         = 12'h17C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_DMA_TR8         = 12'h180;
  localparam logic [ADDR_W-1:0] REG_DEBUG_WAIT0           = 12'h184;
  localparam logic [ADDR_W-1:0] REG_DEBUG_WAIT1           = 12'h188;
  localparam logic [ADDR_W-1:0] REG_DEBUG_WAIT2           = 12'h18C;
  localparam logic [ADDR_W-1:0] REG_DEBUG_WAIT3           = 12'h190;
  localparam logic [ADDR_W-1:0] REG_DEBUG_AUDIO_STATUS    = 12'h194;

  logic [31:0] shadow_ctrl;
  logic [9:0]  shadow_keys;
  logic [24:0] shadow_max_pak_addr;
  logic [15:0] shadow_cycle_precalc;
  logic [31:0] shadow_rtc_timestamp;
  logic [31:0] shadow_rtc_timestamp_saved;
  logic [11:0] shadow_bios_wr_addr;
  logic [31:0] shadow_bios_wr_data;

  logic [5:0]  shadow_feature_ctrl;
  logic [2:0]  shadow_savestate_slot;
  logic [31:0] shadow_cheat_flags;
  logic [31:0] shadow_cheat_addr;
  logic [31:0] shadow_cheat_compare;
  logic [31:0] shadow_cheat_replace;
  logic [23:0] shadow_sensor_input;
  logic [31:0] shadow_rtc_in_savedtime_lo;
  logic [31:0] shadow_rtc_in_savedtime_hi;

  logic [31:0] irq_en;
  logic [1:0]  irq_sts; // [1] error, [0] vsync
  logic [31:0] error_latch;
  logic        load_done_latched;
  logic [31:0] mem_status_axi;
  logic [3:0] mem_proto_error_axi;
  logic [27:0] mem_proto_error_addr_axi;

  assign irq_out = |(irq_sts & irq_en[1:0]);
  assign mem_status_axi = stat_mem_status |
      ((mem_proto_error_axi != 4'd0) ? `PS_PL_MEM_STATUS_FAULTED : 32'd0);

  logic [ADDR_W-1:0] awaddr_latched;
  logic awaddr_valid;
  logic [31:0] frame_snap_req_seq;
  logic [31:0] save_snap_req_seq;
  logic [1:0] save_ack_kind;
  logic [31:0] save_ack_gen;
  logic [31:0] save_ack_seq;
  logic [31:0] mem_cmd_ack_seq_axi;
  logic [31:0] frame_snap_ack_seq_axi;
  logic [31:0] save_snap_ack_seq_axi;
  logic [31:0] save_ack_ack_seq_axi;
  logic mem_cmd_ack_seen;
  logic frame_snap_ack_seen;
  logic save_snap_ack_seen;
  logic save_ack_ack_seen;
  logic [31:0] snap_frame_status_axi;
  logic [31:0] snap_frame_seq_axi;
  logic [31:0] snap_frame_bank0_gen_axi;
  logic [31:0] snap_frame_bank1_gen_axi;
  logic [31:0] snap_frame_rom_epoch_axi;
  logic [31:0] snap_save_counters_axi;
  logic [31:0] snap_save_status_axi;
  logic [31:0] snap_save_sram_gen_axi;
  logic [31:0] snap_save_flash_gen_axi;
  logic [31:0] snap_save_eeprom_gen_axi;

  wire write_fire = s_axi_wvalid && s_axi_wready;
  wire read_fire  = s_axi_arvalid && s_axi_arready;
  assign s_axi_awready = rst_n && !awaddr_valid && !s_axi_bvalid;
  assign s_axi_wready  = rst_n && awaddr_valid && !s_axi_bvalid &&
                         ((awaddr_latched != REG_BIOS_WR_REQ) || bios_wr_src_ready);
  assign s_axi_arready = rst_n && !s_axi_rvalid;

  assign cfg_bios_wr_req_toggle = bios_wr_src_req_toggle;
  assign bios_wr_src_payload = {shadow_bios_wr_addr, shadow_bios_wr_data};
  assign bios_wr_src_valid = write_fire &&
       (awaddr_latched == REG_BIOS_WR_REQ) && s_axi_wstrb[0] &&
       s_axi_wdata[0] && bios_wr_src_ready;

  assign mem_cmd_src_valid = write_fire &&
       (awaddr_latched == `PS_PL_REG_MEM_CMD_REQ_TOGGLE) &&
       s_axi_wstrb[0] && mem_cmd_src_ready &&
       (s_axi_wdata[0] != mem_cmd_src_req_toggle);
  assign mem_cmd_src_payload = {cfg_mem_cmd_seq, cfg_mem_cmd};
  assign frame_snap_src_valid = write_fire &&
       (awaddr_latched == `PS_PL_REG_FRAME_SNAP_REQ_TOGGLE) &&
       s_axi_wstrb[0] && frame_snap_src_ready &&
       (s_axi_wdata[0] != frame_snap_src_req_toggle);
  assign frame_snap_src_payload = frame_snap_req_seq;
  assign save_snap_src_valid = write_fire &&
       (awaddr_latched == `PS_PL_REG_SAVE_SNAP_REQ_TOGGLE) &&
       s_axi_wstrb[0] && save_snap_src_ready &&
       (s_axi_wdata[0] != save_snap_src_req_toggle);
  assign save_snap_src_payload = save_snap_req_seq;
  assign save_ack_src_valid = write_fire &&
       (awaddr_latched == `PS_PL_REG_SAVE_ACK_REQ_TOGGLE) &&
       s_axi_wstrb[0] && save_ack_src_ready &&
       (s_axi_wdata[0] != save_ack_src_req_toggle);
  assign save_ack_src_payload = {save_ack_kind, save_ack_gen, save_ack_seq};

`ifndef SYNTHESIS
  property p_mem_mailbox_payload_held_while_busy;
    @(posedge clk) disable iff (!rst_n)
      !mem_cmd_src_ready |=> $stable({cfg_mem_cmd, cfg_mem_cmd_seq});
  endproperty
  assert property (p_mem_mailbox_payload_held_while_busy);

  property p_snapshot_payload_held_while_busy;
    @(posedge clk) disable iff (!rst_n)
      !frame_snap_src_ready |=> $stable(frame_snap_req_seq);
  endproperty
  assert property (p_snapshot_payload_held_while_busy);

  property p_save_snapshot_payload_held_while_busy;
    @(posedge clk) disable iff (!rst_n)
      !save_snap_src_ready |=> $stable(save_snap_req_seq);
  endproperty
  assert property (p_save_snapshot_payload_held_while_busy);

  property p_save_ack_payload_held_while_busy;
    @(posedge clk) disable iff (!rst_n)
      !save_ack_src_ready |=> $stable({save_ack_kind, save_ack_gen, save_ack_seq});
  endproperty
  assert property (p_save_ack_payload_held_while_busy);

  property p_bios_payload_held_until_accept;
    @(posedge clk) disable iff (!rst_n)
      bios_wr_src_valid |-> bios_wr_src_ready;
  endproperty
  assert property (p_bios_payload_held_until_accept);
`endif

  // @process-purpose: 封装PS 控制寄存器窗口中重复使用的纯组合换算规则，避免地址/位域规则散落在调用点。
  // @process-mechanism: 先把 4-bit WSTRB 扩展成 32-bit 字节掩码；掩码为 1 的字节取 AXI 写数据 new_v，掩码为 0 的字节保留旧寄存器 old_v。
  // @process-result: 结果是调用点或后级逻辑得到无状态的组合返回/选择值，不引入额外寄存器、握手或跨时钟域副作用。
  function automatic logic [31:0] apply_wstrb(
    input logic [31:0] old_v,
    input logic [31:0] new_v,
    input logic [3:0]  wstrb
  );
    logic [31:0] mask;
  begin
    mask = {
      {8{wstrb[3]}},
      {8{wstrb[2]}},
      {8{wstrb[1]}},
      {8{wstrb[0]}}
    };
    apply_wstrb = (old_v & ~mask) | (new_v & mask);
  end
  endfunction

  // @process-purpose: 在 clk 时钟域处理PS 控制寄存器窗口的请求、事件或计数条件，并把结果锁存为下游可采样的控制/状态信号。
  // @process-mechanism: 写侧在 AW/W 握手后按地址译码更新配置、IRQ 与动作 toggle；读侧锁存 ARADDR，再从状态/调试/配置寄存器中选一路返回。
  // @process-result: 结果是 PS 侧获得符合 AXI4-Lite 语义的寄存器读写响应，core 侧动作以 toggle 或状态位形式被明确记录。
  always_ff @(posedge clk) begin
    logic [31:0] rdata_next;
    logic [31:0] merged32;

    if (!rst_n) begin
      shadow_ctrl                <= 32'h0000_1616;
      shadow_keys                <= '0;
      shadow_max_pak_addr        <= '0;
      shadow_cycle_precalc       <= 16'd100;
      shadow_rtc_timestamp       <= '0;
      shadow_rtc_timestamp_saved <= '0;
      shadow_bios_wr_addr        <= 12'd0;
      shadow_bios_wr_data        <= 32'd0;

      shadow_feature_ctrl        <= 6'h1C;
      shadow_savestate_slot      <= 3'd0;
      shadow_cheat_flags         <= 32'd0;
      shadow_cheat_addr          <= 32'd0;
      shadow_cheat_compare       <= 32'd0;
      shadow_cheat_replace       <= 32'd0;
      shadow_sensor_input        <= {8'd0, 8'd0, 5'd0, 3'd3};
      shadow_rtc_in_savedtime_lo <= 32'd0;
      shadow_rtc_in_savedtime_hi <= 32'd0;

      cfg_ctrl                   <= 32'h0000_1616;
      cfg_keys                   <= '0;
      cfg_max_pak_addr           <= '0;
      cfg_cycle_precalc          <= 16'd100;
      cfg_rtc_timestamp          <= '0;
      cfg_rtc_timestamp_saved    <= '0;
      cfg_display_frame_idx      <= 2'd0;
      cfg_sw_reset               <= 1'b0;
      cfg_commit_toggle          <= 1'b0;
      cfg_bios_wr_addr           <= 12'd0;
      cfg_bios_wr_data           <= 32'd0;
      cfg_mem_cmd                <= 32'd0;
      cfg_mem_cmd_seq            <= 32'd0;
      frame_snap_req_seq         <= 32'd0;
      save_snap_req_seq          <= 32'd0;
      save_ack_kind              <= 2'd0;
      save_ack_gen               <= 32'd0;
      save_ack_seq               <= 32'd0;
      mem_cmd_ack_seen           <= 1'b0;
      frame_snap_ack_seen        <= 1'b0;
      save_snap_ack_seen         <= 1'b0;
      save_ack_ack_seen          <= 1'b0;
      mem_cmd_ack_seq_axi        <= 32'd0;
      frame_snap_ack_seq_axi     <= 32'd0;
      save_snap_ack_seq_axi      <= 32'd0;
      save_ack_ack_seq_axi       <= 32'd0;
      snap_frame_status_axi      <= 32'd0;
      snap_frame_seq_axi         <= 32'd0;
      snap_frame_bank0_gen_axi   <= 32'd0;
      snap_frame_bank1_gen_axi   <= 32'd0;
      snap_frame_rom_epoch_axi   <= 32'd0;
      snap_save_counters_axi     <= 32'd0;
      snap_save_status_axi       <= 32'd0;
      snap_save_sram_gen_axi     <= 32'd0;
      snap_save_flash_gen_axi    <= 32'd0;
      snap_save_eeprom_gen_axi   <= 32'd0;
      mem_proto_error_axi        <= 4'd0;
      mem_proto_error_addr_axi   <= 28'd0;

      cfg_feature_ctrl           <= 6'h1C;
      cfg_feature_action_save_toggle       <= 1'b0;
      cfg_feature_action_load_toggle       <= 1'b0;
      cfg_feature_action_cheat_push_toggle <= 1'b0;
      cfg_feature_action_cheat_clear_toggle <= 1'b0;
      cfg_feature_action_rtc_new_toggle    <= 1'b0;
      cfg_savestate_slot         <= 3'd0;
      cfg_cheat_flags            <= 32'd0;
      cfg_cheat_addr             <= 32'd0;
      cfg_cheat_compare          <= 32'd0;
      cfg_cheat_replace          <= 32'd0;
      cfg_sensor_input           <= {8'd0, 8'd0, 5'd0, 3'd3};
      cfg_rtc_in_savedtime_lo    <= 32'd0;
      cfg_rtc_in_savedtime_hi    <= 32'd0;

      irq_en                     <= 32'h0;
      irq_sts                    <= 2'b0;
      error_latch                <= 32'h0;
      load_done_latched          <= 1'b0;

      s_axi_bresp                <= 2'b00;
      s_axi_bvalid               <= 1'b0;

      s_axi_rresp                <= 2'b00;
      s_axi_rvalid               <= 1'b0;
      s_axi_rdata                <= 32'h0;

      awaddr_latched             <= '0;
      awaddr_valid               <= 1'b0;
    end else begin
      if (mem_cmd_src_ack_toggle != mem_cmd_ack_seen) begin
        mem_cmd_ack_seen <= mem_cmd_src_ack_toggle;
        // Payload order is {sequence, command}; ACK_SEQ reports the upper word.
        mem_cmd_ack_seq_axi <= mem_cmd_src_ack_payload[63:32];
        if ((cfg_mem_cmd == `PS_PL_MEM_CMD_CLEAR_ERROR) &&
            (stat_mem_error == 4'd0) &&
            !(stat_mem_status & `PS_PL_MEM_STATUS_FAULTED) &&
            !(stat_mem_status & `PS_PL_MEM_STATUS_FATAL_FAULT)) begin
          mem_proto_error_axi <= 4'd0;
          mem_proto_error_addr_axi <= 28'd0;
        end
      end
      if (frame_snap_src_ack_toggle != frame_snap_ack_seen) begin
        frame_snap_ack_seen <= frame_snap_src_ack_toggle;
        frame_snap_ack_seq_axi <= frame_snap_src_ack_payload[31:0];
        snap_frame_status_axi <= stat_frame_snap_status;
        snap_frame_seq_axi <= stat_frame_snap_seq;
        snap_frame_bank0_gen_axi <= stat_frame_snap_bank0_gen;
        snap_frame_bank1_gen_axi <= stat_frame_snap_bank1_gen;
        snap_frame_rom_epoch_axi <= stat_frame_snap_rom_epoch;
      end
      if (save_snap_src_ack_toggle != save_snap_ack_seen) begin
        save_snap_ack_seen <= save_snap_src_ack_toggle;
        save_snap_ack_seq_axi <= save_snap_src_ack_payload[31:0];
        snap_save_counters_axi <= stat_save_snap_counters;
        snap_save_status_axi <= stat_save_snap_status;
        snap_save_sram_gen_axi <= stat_save_snap_sram_gen;
        snap_save_flash_gen_axi <= stat_save_snap_flash_gen;
        snap_save_eeprom_gen_axi <= stat_save_snap_eeprom_gen;
      end
      if (save_ack_src_ack_toggle != save_ack_ack_seen) begin
        save_ack_ack_seen <= save_ack_src_ack_toggle;
        save_ack_ack_seq_axi <= save_ack_src_ack_payload[31:0];
      end

      // Handle IRQ pulses (sticky status)
      if (irq_vsync_pulse) irq_sts[0] <= 1'b1;
      if (irq_error_pulse) irq_sts[1] <= 1'b1;

      if (stat_feature_load_done_pulse) begin
        load_done_latched <= 1'b1;
      end

      // Capture error if latch is empty
      if (sys_error_in != 0 && error_latch == 0) begin
        error_latch <= sys_error_in;
      end

      if (s_axi_awvalid && s_axi_awready) begin
        awaddr_latched <= s_axi_awaddr;
        awaddr_valid   <= 1'b1;
      end

      if (write_fire) begin
        unique case (awaddr_latched)
          REG_CTRL: begin
            shadow_ctrl <= apply_wstrb(shadow_ctrl, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_KEYS: begin
            merged32    = apply_wstrb({22'd0, shadow_keys}, s_axi_wdata, s_axi_wstrb[3:0]);
            shadow_keys <= merged32[9:0];
          end
          REG_MAX_PAK_ADDR: begin
            merged32            = apply_wstrb({7'd0, shadow_max_pak_addr}, s_axi_wdata, s_axi_wstrb[3:0]);
            shadow_max_pak_addr <= merged32[24:0];
          end
          REG_CYCLE_PRECALC: begin
            merged32              = apply_wstrb({16'd0, shadow_cycle_precalc}, s_axi_wdata, s_axi_wstrb[3:0]);
            shadow_cycle_precalc  <= merged32[15:0];
          end
          REG_RTC_TIMESTAMP: begin
            shadow_rtc_timestamp <= apply_wstrb(shadow_rtc_timestamp, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_RTC_TIMESTAMP_SAVED: begin
            shadow_rtc_timestamp_saved <= apply_wstrb(shadow_rtc_timestamp_saved, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_BIOS_WR_ADDR: begin
            merged32           = apply_wstrb({20'd0, shadow_bios_wr_addr}, s_axi_wdata, s_axi_wstrb[3:0]);
            shadow_bios_wr_addr <= merged32[11:0];
          end
          REG_BIOS_WR_DATA: begin
            shadow_bios_wr_data <= apply_wstrb(shadow_bios_wr_data, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_BIOS_WR_REQ: begin
            if (s_axi_wstrb[0] && s_axi_wdata[0]) begin
              cfg_bios_wr_addr       <= shadow_bios_wr_addr;
              cfg_bios_wr_data       <= shadow_bios_wr_data;
            end
          end
          `PS_PL_REG_MEM_CMD: begin
            if (mem_cmd_src_ready)
              cfg_mem_cmd <= apply_wstrb(cfg_mem_cmd, s_axi_wdata, s_axi_wstrb[3:0]);
            else begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_MEM_CMD_SEQ: begin
            if (mem_cmd_src_ready)
              cfg_mem_cmd_seq <= apply_wstrb(cfg_mem_cmd_seq, s_axi_wdata, s_axi_wstrb[3:0]);
            else begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_MEM_CMD_REQ_TOGGLE: begin
            if (s_axi_wstrb[0] && (s_axi_wdata[0] != mem_cmd_src_req_toggle) &&
                !mem_cmd_src_ready) begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_FRAME_SNAP_REQ_SEQ: begin
            if (frame_snap_src_ready)
              frame_snap_req_seq <= apply_wstrb(frame_snap_req_seq, s_axi_wdata, s_axi_wstrb[3:0]);
            else begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_SAVE_SNAP_REQ_SEQ: begin
            if (save_snap_src_ready)
              save_snap_req_seq <= apply_wstrb(save_snap_req_seq, s_axi_wdata, s_axi_wstrb[3:0]);
            else begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_FRAME_SNAP_REQ_TOGGLE: begin
            if (s_axi_wstrb[0] &&
                (s_axi_wdata[0] != frame_snap_src_req_toggle) &&
                !frame_snap_src_ready) begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_SAVE_SNAP_REQ_TOGGLE: begin
            if (s_axi_wstrb[0] &&
                (s_axi_wdata[0] != save_snap_src_req_toggle) &&
                !save_snap_src_ready) begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_SAVE_ACK_KIND: begin
            if (save_ack_src_ready) begin
              merged32 = apply_wstrb({30'd0, save_ack_kind}, s_axi_wdata, s_axi_wstrb[3:0]);
              save_ack_kind <= merged32[1:0];
            end else begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_SAVE_ACK_GEN: begin
            if (save_ack_src_ready)
              save_ack_gen <= apply_wstrb(save_ack_gen, s_axi_wdata, s_axi_wstrb[3:0]);
            else begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_SAVE_ACK_SEQ: begin
            if (save_ack_src_ready)
              save_ack_seq <= apply_wstrb(save_ack_seq, s_axi_wdata, s_axi_wstrb[3:0]);
            else begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          `PS_PL_REG_SAVE_ACK_REQ_TOGGLE: begin
            if (s_axi_wstrb[0] &&
                (s_axi_wdata[0] != save_ack_src_req_toggle) &&
                !save_ack_src_ready) begin
              mem_proto_error_axi <= 4'h1;
              mem_proto_error_addr_axi <= 28'd0;
            end
          end
          REG_COMMIT: begin
            cfg_ctrl          <= shadow_ctrl;
            cfg_keys          <= shadow_keys;
            cfg_max_pak_addr  <= shadow_max_pak_addr;
            cfg_cycle_precalc <= shadow_cycle_precalc;
            cfg_rtc_timestamp <= shadow_rtc_timestamp;
            cfg_rtc_timestamp_saved <= shadow_rtc_timestamp_saved;
            cfg_commit_toggle <= ~cfg_commit_toggle;
          end
          REG_SW_RESET: begin
            cfg_sw_reset <= s_axi_wdata[0];
          end
          REG_DISPLAY_FRAME: begin
            cfg_display_frame_idx <= s_axi_wdata[1:0];
            cfg_commit_toggle <= ~cfg_commit_toggle;
          end
          REG_ERROR_LATCH: begin
            // Write 1 to clear current error latch
            if (s_axi_wdata[0]) error_latch <= 32'h0;
          end
          REG_IRQ_EN: begin
            irq_en <= apply_wstrb(irq_en, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_IRQ_STS: begin
            // W1C for status bits
            if (s_axi_wdata[0]) irq_sts[0] <= 1'b0;
            if (s_axi_wdata[1]) irq_sts[1] <= 1'b0;
          end

          REG_FEATURE_CTRL: begin
            merged32            = apply_wstrb({26'd0, shadow_feature_ctrl}, s_axi_wdata, s_axi_wstrb[3:0]);
            shadow_feature_ctrl <= merged32[5:0];
            cfg_feature_ctrl    <= merged32[5:0];
          end
          REG_FEATURE_ACTION: begin
            if (s_axi_wstrb[0]) begin
              if (s_axi_wdata[0]) cfg_feature_action_save_toggle        <= ~cfg_feature_action_save_toggle;
              if (s_axi_wdata[1]) cfg_feature_action_load_toggle        <= ~cfg_feature_action_load_toggle;
              if (s_axi_wdata[2]) cfg_feature_action_cheat_push_toggle  <= ~cfg_feature_action_cheat_push_toggle;
              if (s_axi_wdata[3]) cfg_feature_action_cheat_clear_toggle <= ~cfg_feature_action_cheat_clear_toggle;
              if (s_axi_wdata[4]) cfg_feature_action_rtc_new_toggle     <= ~cfg_feature_action_rtc_new_toggle;
            end
          end
          REG_SAVESTATE_SLOT: begin
            merged32               = apply_wstrb({29'd0, shadow_savestate_slot}, s_axi_wdata, s_axi_wstrb[3:0]);
            shadow_savestate_slot  <= merged32[2:0];
            cfg_savestate_slot     <= merged32[2:0];
          end
          REG_CHEAT_FLAGS: begin
            shadow_cheat_flags <= apply_wstrb(shadow_cheat_flags, s_axi_wdata, s_axi_wstrb[3:0]);
            cfg_cheat_flags    <= apply_wstrb(shadow_cheat_flags, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_CHEAT_ADDR: begin
            shadow_cheat_addr <= apply_wstrb(shadow_cheat_addr, s_axi_wdata, s_axi_wstrb[3:0]);
            cfg_cheat_addr    <= apply_wstrb(shadow_cheat_addr, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_CHEAT_COMPARE: begin
            shadow_cheat_compare <= apply_wstrb(shadow_cheat_compare, s_axi_wdata, s_axi_wstrb[3:0]);
            cfg_cheat_compare    <= apply_wstrb(shadow_cheat_compare, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_CHEAT_REPLACE: begin
            shadow_cheat_replace <= apply_wstrb(shadow_cheat_replace, s_axi_wdata, s_axi_wstrb[3:0]);
            cfg_cheat_replace    <= apply_wstrb(shadow_cheat_replace, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_SENSOR_INPUT: begin
            merged32           = apply_wstrb({8'd0, shadow_sensor_input}, s_axi_wdata, s_axi_wstrb[3:0]);
            shadow_sensor_input <= merged32[23:0];
            cfg_sensor_input    <= merged32[23:0];
          end
          REG_RTC_IN_SAVEDTIME_LO: begin
            shadow_rtc_in_savedtime_lo <= apply_wstrb(shadow_rtc_in_savedtime_lo, s_axi_wdata, s_axi_wstrb[3:0]);
            cfg_rtc_in_savedtime_lo    <= apply_wstrb(shadow_rtc_in_savedtime_lo, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_RTC_IN_SAVEDTIME_HI: begin
            shadow_rtc_in_savedtime_hi <= apply_wstrb(shadow_rtc_in_savedtime_hi, s_axi_wdata, s_axi_wstrb[3:0]);
            cfg_rtc_in_savedtime_hi    <= apply_wstrb(shadow_rtc_in_savedtime_hi, s_axi_wdata, s_axi_wstrb[3:0]);
          end
          REG_FEATURE_STATUS_CLR: begin
            if (s_axi_wstrb[0] && s_axi_wdata[0]) begin
              load_done_latched <= 1'b0;
            end
          end
          default: begin
          end
        endcase

        // Feature configuration fields historically take effect on write.
        // Reuse the atomic bundle mailbox for those complete snapshots too.
        if ((awaddr_latched == REG_FEATURE_CTRL) ||
            (awaddr_latched == REG_SAVESTATE_SLOT) ||
            (awaddr_latched == REG_CHEAT_FLAGS) ||
            (awaddr_latched == REG_CHEAT_ADDR) ||
            (awaddr_latched == REG_CHEAT_COMPARE) ||
            (awaddr_latched == REG_CHEAT_REPLACE) ||
            (awaddr_latched == REG_SENSOR_INPUT) ||
            (awaddr_latched == REG_RTC_IN_SAVEDTIME_LO) ||
            (awaddr_latched == REG_RTC_IN_SAVEDTIME_HI)) begin
          cfg_commit_toggle <= ~cfg_commit_toggle;
        end

        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= 2'b00;
        awaddr_valid <= 1'b0;
      end

      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end

      if (read_fire) begin
        unique case (s_axi_araddr)
          REG_CTRL:                rdata_next = cfg_ctrl;
          REG_KEYS:                rdata_next = {22'd0, cfg_keys};
          REG_MAX_PAK_ADDR:        rdata_next = {7'd0, cfg_max_pak_addr};
          REG_CYCLE_PRECALC:       rdata_next = {16'd0, cfg_cycle_precalc};
          REG_RTC_TIMESTAMP:       rdata_next = cfg_rtc_timestamp;
          REG_RTC_TIMESTAMP_SAVED: rdata_next = cfg_rtc_timestamp_saved;
          REG_STATUS0:             rdata_next = {22'd0, stat_physical_keys};
          REG_STATUS1:             rdata_next = {stat_cycles_vsync_speed, stat_cycles_missing, stat_fb_frame_idx};
          REG_SW_RESET:            rdata_next = {31'd0, cfg_sw_reset};
          REG_ROM_STATUS:          rdata_next = {31'd0, sys_rom_loading};
          REG_ERROR_LATCH:         rdata_next = error_latch;
          REG_IRQ_EN:              rdata_next = irq_en;
          REG_IRQ_STS:             rdata_next = {30'd0, irq_sts};
          REG_BIOS_WR_ADDR:        rdata_next = {20'd0, shadow_bios_wr_addr};
          REG_BIOS_WR_DATA:        rdata_next = shadow_bios_wr_data;
          REG_BIOS_WR_REQ:         rdata_next = {31'd0, cfg_bios_wr_req_toggle};
          REG_BIOS_WR_ACK:         rdata_next = stat_bios_wr_ack_seq;
          REG_DEBUG_CPU_PC:        rdata_next = stat_debug_cpu_pc;
          REG_DEBUG_CPU_MIX:       rdata_next = stat_debug_cpu_mixed;
          REG_DEBUG_CPU_R0:        rdata_next = stat_debug_cpu_r0;
          REG_DEBUG_CPU_R1:        rdata_next = stat_debug_cpu_r1;
          REG_DEBUG_CPU_R2:        rdata_next = stat_debug_cpu_r2;
          REG_DEBUG_CPU_R4:        rdata_next = stat_debug_cpu_r4;
          REG_DEBUG_CPU_CPUSET:    rdata_next = stat_debug_cpu_cpuset;
          REG_DDR_ATOM_WORD0:      rdata_next = stat_ddr_atom_word0;
          REG_DDR_ATOM_WORD1:      rdata_next = stat_ddr_atom_word1;
          REG_DDR_ATOM_NEXT0:      rdata_next = stat_ddr_atom_next0;
          REG_DDR_ATOM_NEXT1:      rdata_next = stat_ddr_atom_next1;
          REG_DDR_ATOM_STAT:       rdata_next = stat_ddr_atom_stat;
          REG_DEBUG_IRQ:           rdata_next = stat_debug_irq;
          REG_DEBUG_IRQ_EXT:       rdata_next = stat_debug_irq_ext;
          REG_DEBUG_DMA:           rdata_next = stat_debug_dma;
          REG_DEBUG_MEM:           rdata_next = stat_debug_mem;
          REG_DEBUG_VRAM_REGS0:    rdata_next = stat_debug_vram_regs0;
          REG_DEBUG_VRAM_REGS1:    rdata_next = stat_debug_vram_regs1;
          REG_DEBUG_VRAM_REGS2:    rdata_next = stat_debug_vram_regs2;
          REG_DEBUG_VRAM_REGS3:    rdata_next = stat_debug_vram_regs3;
          REG_DEBUG_VRAM_REGS4:    rdata_next = stat_debug_vram_regs4;
          REG_DEBUG_VRAM_HITS:     rdata_next = stat_debug_vram_hits;
          REG_DEBUG_VRAM_RING0:    rdata_next = stat_debug_vram_ring0;
          REG_DEBUG_VRAM_RING1:    rdata_next = stat_debug_vram_ring1;
          REG_DEBUG_VRAM_RING2:    rdata_next = stat_debug_vram_ring2;
          REG_DEBUG_VRAM_RING3:    rdata_next = stat_debug_vram_ring3;
          REG_DEBUG_VRAM_DIST0:    rdata_next = stat_debug_vram_dist0;
          REG_DEBUG_VRAM_DIST1:    rdata_next = stat_debug_vram_dist1;
          REG_DEBUG_DMA_TR0:       rdata_next = stat_debug_dma_tr0;
          REG_DEBUG_DMA_TR1:       rdata_next = stat_debug_dma_tr1;
          REG_DEBUG_DMA_TR2:       rdata_next = stat_debug_dma_tr2;
          REG_DEBUG_DMA_TR3:       rdata_next = stat_debug_dma_tr3;
          REG_DEBUG_DMA_TR4:       rdata_next = stat_debug_dma_tr4;
          REG_DEBUG_DMA_TR5:       rdata_next = stat_debug_dma_tr5;
          REG_DEBUG_DMA_TR6:       rdata_next = stat_debug_dma_tr6;
          REG_DEBUG_DMA_TR7:       rdata_next = stat_debug_dma_tr7;
          REG_DEBUG_DMA_TR8:       rdata_next = stat_debug_dma_tr8;
          REG_DEBUG_WAIT0:         rdata_next = stat_debug_wait0;
          REG_DEBUG_WAIT1:         rdata_next = stat_debug_wait1;
          REG_DEBUG_WAIT2:         rdata_next = stat_debug_wait2;
          REG_DEBUG_WAIT3:         rdata_next = stat_debug_wait3;
          REG_DEBUG_AUDIO_STATUS:  rdata_next = stat_debug_audio_status;
          REG_DISPLAY_FRAME:       rdata_next = {30'd0, cfg_display_frame_idx};
          REG_DBG_CHAIN_FLAGS:     rdata_next = stat_dbg_chain_flags;
          REG_DBG_CHAIN_COUNTS0:   rdata_next = stat_dbg_chain_counts0;
          REG_DBG_CHAIN_COUNTS1:   rdata_next = stat_dbg_chain_counts1;
          REG_DBG_CH1_FIRST_ADDR:  rdata_next = stat_dbg_ch1_first_addr;
          REG_DBG_CH1_FIRST_META:  rdata_next = stat_dbg_ch1_first_meta;
          REG_DBG_CH1_LAST_ADDR:   rdata_next = stat_dbg_ch1_last_addr;
          REG_DBG_CH1_LAST_META:   rdata_next = stat_dbg_ch1_last_meta;
          REG_DBG_DDR_FIRST_ADDR:  rdata_next = stat_dbg_ddr_first_addr;
          REG_DBG_DDR_FIRST_META:  rdata_next = stat_dbg_ddr_first_meta;
          REG_DBG_DDR_LAST_ADDR:   rdata_next = stat_dbg_ddr_last_addr;
          REG_DBG_DDR_LAST_META:   rdata_next = stat_dbg_ddr_last_meta;
          REG_DBG_AXI_AR_FIRST_ADDR: rdata_next = stat_dbg_axi_ar_first_addr;
          REG_DBG_AXI_AR_FIRST_META: rdata_next = stat_dbg_axi_ar_first_meta;
          REG_DBG_AXI_AR_LAST_ADDR:  rdata_next = stat_dbg_axi_ar_last_addr;
          REG_DBG_AXI_AR_LAST_META:  rdata_next = stat_dbg_axi_ar_last_meta;
          REG_DBG_AXI_R_FIRST_ADDR:  rdata_next = stat_dbg_axi_r_first_addr;
          REG_DBG_AXI_R_FIRST_META:  rdata_next = stat_dbg_axi_r_first_meta;
          REG_DBG_AXI_R_LAST_ADDR:   rdata_next = stat_dbg_axi_r_last_addr;
          REG_DBG_AXI_R_LAST_META:   rdata_next = stat_dbg_axi_r_last_meta;
          REG_DBG_DONE_FIRST_ADDR:   rdata_next = stat_dbg_done_first_addr;
          REG_DBG_DONE_FIRST_META:   rdata_next = stat_dbg_done_first_meta;
          REG_DBG_DONE_LAST_ADDR:    rdata_next = stat_dbg_done_last_addr;
          REG_DBG_DONE_LAST_META:    rdata_next = stat_dbg_done_last_meta;
          REG_FB_CAP_STATUS:         rdata_next = {31'd0, stat_fbcap_frame_buf_idx};
          REG_FB_CAP_SEQ:            rdata_next = stat_fbcap_frame_seq;
          REG_SAVE_STATUS:           rdata_next = stat_save_status;

          `PS_PL_REG_ABI_MAGIC:      rdata_next = `PS_PL_ABI_MAGIC;
          `PS_PL_REG_ABI_VERSION:    rdata_next = `PS_PL_ABI_VERSION;
          `PS_PL_REG_ABI_CAPS:       rdata_next = `PS_PL_ABI_CAP_MEMORY_LIFECYCLE |
                                                  `PS_PL_ABI_CAP_ATOMIC_SNAPSHOT |
                                                  `PS_PL_ABI_CAP_FRAME_BANK_GENERATION |
                                                  `PS_PL_ABI_CAP_SAVE_DIRTY_GENERATION |
                                                  `PS_PL_ABI_CAP_CONTRACT_BUILD_ID;
          `PS_PL_REG_ABI_BUILD_ID:   rdata_next = `PS_PL_ABI_BUILD_ID;
          `PS_PL_REG_MEM_CMD:        rdata_next = cfg_mem_cmd;
          `PS_PL_REG_MEM_CMD_SEQ:    rdata_next = cfg_mem_cmd_seq;
          `PS_PL_REG_MEM_CMD_REQ_TOGGLE: rdata_next = {31'd0, mem_cmd_src_req_toggle};
          `PS_PL_REG_MEM_CMD_ACK_SEQ: rdata_next = mem_cmd_ack_seq_axi;
          `PS_PL_REG_MEM_STATUS:     rdata_next = mem_status_axi;
          `PS_PL_REG_MEM_ERROR:      rdata_next = (stat_mem_error != 4'd0)
                                                  ? {28'd0, stat_mem_error}
                                                  : {28'd0, mem_proto_error_axi};
          `PS_PL_REG_MEM_ERROR_ADDR: rdata_next = (stat_mem_error != 4'd0)
                                                  ? {4'd0, stat_mem_error_addr}
                                                  : {4'd0, mem_proto_error_addr_axi};
          `PS_PL_REG_ROM_EPOCH:      rdata_next = stat_rom_epoch;

          `PS_PL_REG_FRAME_SNAP_REQ_SEQ: rdata_next = frame_snap_req_seq;
          `PS_PL_REG_FRAME_SNAP_REQ_TOGGLE: rdata_next = {31'd0, frame_snap_src_req_toggle};
          `PS_PL_REG_FRAME_SNAP_ACK_SEQ: rdata_next = frame_snap_ack_seq_axi;
          `PS_PL_REG_FRAME_SNAP_ACK_TOGGLE: rdata_next = {31'd0, frame_snap_src_ack_toggle};
          `PS_PL_REG_SNAP_FRAME_STATUS: rdata_next = snap_frame_status_axi;
          `PS_PL_REG_SNAP_FRAME_SEQ: rdata_next = snap_frame_seq_axi;
          `PS_PL_REG_SNAP_FRAME_BANK0_GEN: rdata_next = snap_frame_bank0_gen_axi;
          `PS_PL_REG_SNAP_FRAME_BANK1_GEN: rdata_next = snap_frame_bank1_gen_axi;
          `PS_PL_REG_SNAP_FRAME_ROM_EPOCH: rdata_next = snap_frame_rom_epoch_axi;

          `PS_PL_REG_SAVE_SNAP_REQ_SEQ: rdata_next = save_snap_req_seq;
          `PS_PL_REG_SAVE_SNAP_REQ_TOGGLE: rdata_next = {31'd0, save_snap_src_req_toggle};
          `PS_PL_REG_SAVE_SNAP_ACK_SEQ: rdata_next = save_snap_ack_seq_axi;
          `PS_PL_REG_SAVE_SNAP_ACK_TOGGLE: rdata_next = {31'd0, save_snap_src_ack_toggle};
          `PS_PL_REG_SNAP_SAVE_COUNTERS: rdata_next = snap_save_counters_axi;
          `PS_PL_REG_SNAP_SAVE_STATUS: rdata_next = snap_save_status_axi;
          `PS_PL_REG_SNAP_SAVE_SRAM_GEN: rdata_next = snap_save_sram_gen_axi;
          `PS_PL_REG_SNAP_SAVE_FLASH_GEN: rdata_next = snap_save_flash_gen_axi;
          `PS_PL_REG_SNAP_SAVE_EEPROM_GEN: rdata_next = snap_save_eeprom_gen_axi;

          `PS_PL_REG_SAVE_ACK_KIND: rdata_next = {30'd0, save_ack_kind};
          `PS_PL_REG_SAVE_ACK_GEN: rdata_next = save_ack_gen;
          `PS_PL_REG_SAVE_ACK_SEQ: rdata_next = save_ack_seq;
          `PS_PL_REG_SAVE_ACK_REQ_TOGGLE: rdata_next = {31'd0, save_ack_src_req_toggle};
          `PS_PL_REG_SAVE_ACK_ACK_SEQ: rdata_next = save_ack_ack_seq_axi;
          `PS_PL_REG_SAVE_ACK_ACK_TOGGLE: rdata_next = {31'd0, save_ack_src_ack_toggle};

          REG_FEATURE_CTRL:          rdata_next = {26'd0, cfg_feature_ctrl};
          REG_FEATURE_ACTION:        rdata_next = {27'd0,
                                                   cfg_feature_action_rtc_new_toggle,
                                                   cfg_feature_action_cheat_clear_toggle,
                                                   cfg_feature_action_cheat_push_toggle,
                                                   cfg_feature_action_load_toggle,
                                                   cfg_feature_action_save_toggle};
          REG_SAVESTATE_SLOT:        rdata_next = {29'd0, cfg_savestate_slot};
          REG_CHEAT_FLAGS:           rdata_next = cfg_cheat_flags;
          REG_CHEAT_ADDR:            rdata_next = cfg_cheat_addr;
          REG_CHEAT_COMPARE:         rdata_next = cfg_cheat_compare;
          REG_CHEAT_REPLACE:         rdata_next = cfg_cheat_replace;
          REG_SENSOR_INPUT:          rdata_next = {8'd0, cfg_sensor_input};
          REG_RTC_IN_SAVEDTIME_LO:   rdata_next = cfg_rtc_in_savedtime_lo;
          REG_RTC_IN_SAVEDTIME_HI:   rdata_next = cfg_rtc_in_savedtime_hi;
          REG_RTC_OUT_TIMESTAMP:     rdata_next = stat_rtc_out_timestamp;
          REG_RTC_OUT_SAVEDTIME_LO:  rdata_next = stat_rtc_out_savedtime_lo;
          REG_RTC_OUT_SAVEDTIME_HI:  rdata_next = stat_rtc_out_savedtime_hi;
          REG_FEATURE_STATUS: begin
            rdata_next = {20'd0,
                          stat_feature_solar_echo,
                          stat_feature_slot_echo,
                          stat_feature_rtc_inuse,
                          stat_feature_cheats_active,
                          stat_feature_rumble_out,
                          stat_feature_rewind_active,
                          load_done_latched,
                          stat_feature_savestate_busy};
          end
          REG_FEATURE_STATUS_CLR:    rdata_next = {31'd0, load_done_latched};
          default:                   rdata_next = 32'h0;
        endcase

        s_axi_rdata  <= rdata_next;
        s_axi_rresp  <= 2'b00;
        s_axi_rvalid <= 1'b1;
      end

      if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
