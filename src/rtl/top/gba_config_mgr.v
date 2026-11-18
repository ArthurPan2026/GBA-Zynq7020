//------------------------------------------------------------------------------
// @file gba_config_mgr.v
// @module-contract
// 职责: 配置跨域桥；配置管理与 CDC 桥接模块，将 PS 侧控制寄存器稳定提交到 GBA core 时钟域。
// 上游: AXI4-Lite 寄存器域、板载按键/拨码。
// 下游: GBA core 的配置、按键、savestate/cheat/RTC 动作脉冲。
// 配置契约: 一个AXI源域完整payload在toggle请求期间保持不变；core域一次捕获整组配置并同拍提交，
// ACK返回前源域不复用该mailbox，期间的新配置提交在源域合并为最新完整快照。
// 时钟域: clk100/clk_core/clk_100/s_axi_aclk 等，具体以端口命名为准。
// Reset: separate domain-local active-low resets from the common system reset epoch.
// 关键协议: AXI valid/ready、写 strobe、读写响应和中断/错误状态按寄存器或总线协议传递。
// 设计注意点: 同步 AXI 配置，用 commit/toggle 语义生成 core 域稳定事件，避免半更新配置进入模拟核心；本注释只解释设计意图，不改变 RTL/XDC 功能。
//------------------------------------------------------------------------------
// gba_config_mgr.v: 系统控制层 - 处理寄存器同步、CDC 与按键映射
// 责任：将 PS 端的非同步配置转化为 PL 核心端的稳定同步信号

module gba_config_mgr (
    input         clk_axi,        // AXI 配置源时钟
    input         clk_core,       // 核心频率时钟 (100MHz)
    input         rst_axi_n,      // AXI source-domain reset
    input         rst_core_n,     // core destination-domain reset

    // AXI 控制寄存器接口 (来自 AXI Domain)
    input [31:0]  cfg_ctrl_axi,
    input [9:0]   cfg_keys_axi,
    input [24:0]  cfg_max_pak_addr_axi,
    input [15:0]  cfg_cycle_precalc_axi,
    input [31:0]  cfg_rtc_timestamp_axi,
    input [31:0]  cfg_rtc_timestamp_saved_axi,
    input [1:0]   cfg_display_frame_idx_axi,
    input         cfg_commit_toggle_axi,

    input [5:0]   cfg_feature_ctrl_axi,
    input [2:0]   cfg_savestate_slot_axi,
    input [31:0]  cfg_cheat_flags_axi,
    input [31:0]  cfg_cheat_addr_axi,
    input [31:0]  cfg_cheat_compare_axi,
    input [31:0]  cfg_cheat_replace_axi,
    input [23:0]  cfg_sensor_input_axi,
    input [31:0]  cfg_rtc_savedtime_lo_axi,
    input [31:0]  cfg_rtc_savedtime_hi_axi,

    input         cfg_action_save_toggle_axi,
    input         cfg_action_load_toggle_axi,
    input         cfg_action_cheat_push_toggle_axi,
    input         cfg_action_cheat_clear_toggle_axi,
    input         cfg_action_rtc_new_toggle_axi,

    // 板载物理输入 (来自 Pin Domain)
    input [3:0]   btns,           // BTN0=Right, BTN1=Down, BTN2=Up, BTN3=Left (pressed high)
    input [3:0]   sws,            // SW0=A, SW1=B, SW2=Select, SW3=Start

    // 同步后的核心配置 (Core Domain)
    output reg [31:0] cfg_ctrl_core,
    output     [9:0]  cfg_keys_core,
    output     [9:0]  physical_keys_core,
    output reg [24:0] cfg_max_pak_addr_core,
    output reg [15:0] cfg_cycle_precalc_core,
    output reg [31:0] cfg_rtc_timestamp_core,
    output reg [31:0] cfg_rtc_timestamp_saved_core,
    output reg [1:0]  cfg_display_frame_idx_core,

    output reg [5:0]  cfg_feature_ctrl_core,
    output reg [2:0]  cfg_savestate_slot_core,
    output reg [31:0] cfg_cheat_flags_core,
    output reg [31:0] cfg_cheat_addr_core,
    output reg [31:0] cfg_cheat_compare_core,
    output reg [31:0] cfg_cheat_replace_core,
    output reg [2:0]  cfg_sensor_solar_core,
    output reg signed [7:0] cfg_sensor_tilt_x_core,
    output reg signed [7:0] cfg_sensor_tilt_y_core,
    output reg [41:0] cfg_rtc_savedtime_core,
    output reg        cfg_rtc_save_loaded_core,

    output            pulse_save_state_core,
    output            pulse_load_state_core,
    output            pulse_cheat_push_core,
    output            pulse_cheat_clear_core,
    output            pulse_rtc_new_core
);

    // A complete configuration image is held in the AXI domain until the
    // destination accepts it. Commits received while the mailbox is occupied
    // coalesce to the newest complete image; the in-flight payload never moves.
    localparam integer CFG_BUNDLE_WIDTH = 374;
    wire [CFG_BUNDLE_WIDTH-1:0] cfg_bundle_axi = {
        cfg_ctrl_axi,
        cfg_keys_axi,
        cfg_max_pak_addr_axi,
        cfg_cycle_precalc_axi,
        cfg_rtc_timestamp_axi,
        cfg_rtc_timestamp_saved_axi,
        cfg_feature_ctrl_axi,
        cfg_savestate_slot_axi,
        cfg_cheat_flags_axi,
        cfg_cheat_addr_axi,
        cfg_cheat_compare_axi,
        cfg_cheat_replace_axi,
        cfg_sensor_input_axi,
        cfg_rtc_savedtime_lo_axi,
        cfg_rtc_savedtime_hi_axi,
        cfg_display_frame_idx_axi
    };

    reg [9:0] cfg_keys_core_reg;
    reg [CFG_BUNDLE_WIDTH-1:0] cfg_bundle_pending_axi;
    reg                        cfg_commit_seen_axi;
    reg                        cfg_commit_pending_axi;
    wire                       cfg_commit_event_axi =
        cfg_commit_toggle_axi != cfg_commit_seen_axi;
    wire                       cfg_mailbox_src_valid =
        cfg_commit_pending_axi && cfg_mailbox_src_ready;
    wire                       cfg_mailbox_src_ready;
    wire                       cfg_mailbox_src_busy;
    wire                       cfg_mailbox_req_toggle;
    wire                       cfg_mailbox_ack_toggle;
    wire [CFG_BUNDLE_WIDTH-1:0] cfg_mailbox_ack_payload;
    wire                       cfg_mailbox_dst_valid;
    wire [CFG_BUNDLE_WIDTH-1:0] cfg_mailbox_dst_payload;

    cdc_toggle_mailbox #(.WIDTH(CFG_BUNDLE_WIDTH)) u_cfg_mailbox (
        .src_clk          (clk_axi),
        .src_rst_n        (rst_axi_n),
        .src_valid        (cfg_mailbox_src_valid),
        .src_payload      (cfg_bundle_pending_axi),
        .src_ready        (cfg_mailbox_src_ready),
        .src_busy         (cfg_mailbox_src_busy),
        .src_req_toggle   (cfg_mailbox_req_toggle),
        .src_ack_toggle   (cfg_mailbox_ack_toggle),
        .src_ack_payload  (cfg_mailbox_ack_payload),
        .dst_clk          (clk_core),
        .dst_rst_n        (rst_core_n),
        .dst_valid        (cfg_mailbox_dst_valid),
        .dst_payload      (cfg_mailbox_dst_payload),
        .dst_ready        (cfg_mailbox_dst_valid)
    );

    always @(posedge clk_axi) begin
        if (!rst_axi_n) begin
            cfg_commit_seen_axi <= 1'b0;
            cfg_commit_pending_axi <= 1'b0;
            cfg_bundle_pending_axi <= {32'h0000_1612, 10'd0, 25'd0, 16'd100,
                                       32'd0, 32'd0, 6'h1C, 3'd0,
                                       128'd0, 24'h000003, 32'd0, 32'd0, 2'd0};
        end else if (cfg_commit_event_axi) begin
            cfg_commit_seen_axi <= cfg_commit_toggle_axi;
            cfg_bundle_pending_axi <= cfg_bundle_axi;
            cfg_commit_pending_axi <= 1'b1;
        end else if (cfg_mailbox_src_valid) begin
            cfg_commit_pending_axi <= 1'b0;
        end
    end

    // One-cycle actions remain event toggles; each is synchronized separately
    // because they are independent operations rather than configuration data.
    (* ASYNC_REG = "TRUE" *) reg [2:0] cfg_action_save_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] cfg_action_load_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] cfg_action_cheat_push_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] cfg_action_cheat_clear_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] cfg_action_rtc_new_sync;

    assign pulse_save_state_core  = cfg_action_save_sync[2] ^ cfg_action_save_sync[1];
    assign pulse_load_state_core  = cfg_action_load_sync[2] ^ cfg_action_load_sync[1];
    assign pulse_cheat_push_core  = cfg_action_cheat_push_sync[2] ^ cfg_action_cheat_push_sync[1];
    assign pulse_cheat_clear_core = cfg_action_cheat_clear_sync[2] ^ cfg_action_cheat_clear_sync[1];
    assign pulse_rtc_new_core     = cfg_action_rtc_new_sync[2] ^ cfg_action_rtc_new_sync[1];

    always @(posedge clk_core) begin
        if (!rst_core_n) begin
            cfg_action_save_sync <= 3'b000;
            cfg_action_load_sync <= 3'b000;
            cfg_action_cheat_push_sync <= 3'b000;
            cfg_action_cheat_clear_sync <= 3'b000;
            cfg_action_rtc_new_sync <= 3'b000;
        end else begin
            cfg_action_save_sync <= {cfg_action_save_sync[1:0], cfg_action_save_toggle_axi};
            cfg_action_load_sync <= {cfg_action_load_sync[1:0], cfg_action_load_toggle_axi};
            cfg_action_cheat_push_sync <= {cfg_action_cheat_push_sync[1:0], cfg_action_cheat_push_toggle_axi};
            cfg_action_cheat_clear_sync <= {cfg_action_cheat_clear_sync[1:0], cfg_action_cheat_clear_toggle_axi};
            cfg_action_rtc_new_sync <= {cfg_action_rtc_new_sync[1:0], cfg_action_rtc_new_toggle_axi};
        end
    end

    // @module-contract: cfg_* crosses as one bundled payload. The request toggle
    // only announces a stable payload; all core configuration registers change
    // on the same destination edge and the mailbox acknowledges that capture.
    always @(posedge clk_core) begin
        if (!rst_core_n) begin
            cfg_ctrl_core          <= 32'h0000_1612;
            cfg_keys_core_reg      <= 10'd0;
            cfg_max_pak_addr_core  <= 25'd0;
            cfg_cycle_precalc_core <= 16'd100;
            cfg_rtc_timestamp_core <= 32'd0;
            cfg_rtc_timestamp_saved_core <= 32'd0;
            cfg_display_frame_idx_core <= 2'd0;
            cfg_feature_ctrl_core <= 6'h1C;
            cfg_savestate_slot_core <= 3'd0;
            cfg_cheat_flags_core <= 32'd0;
            cfg_cheat_addr_core <= 32'd0;
            cfg_cheat_compare_core <= 32'd0;
            cfg_cheat_replace_core <= 32'd0;
            cfg_sensor_solar_core <= 3'd3;
            cfg_sensor_tilt_x_core <= 8'sd0;
            cfg_sensor_tilt_y_core <= 8'sd0;
            cfg_rtc_savedtime_core <= 42'd0;
            cfg_rtc_save_loaded_core <= 1'b0;
        end else if (cfg_mailbox_dst_valid) begin
            cfg_ctrl_core          <= cfg_mailbox_dst_payload[373:342];
            cfg_keys_core_reg      <= cfg_mailbox_dst_payload[341:332];
            cfg_max_pak_addr_core  <= cfg_mailbox_dst_payload[331:307];
            cfg_cycle_precalc_core <= cfg_mailbox_dst_payload[306:291];
            cfg_rtc_timestamp_core <= cfg_mailbox_dst_payload[290:259];
            cfg_rtc_timestamp_saved_core <= cfg_mailbox_dst_payload[258:227];
            cfg_feature_ctrl_core <= cfg_mailbox_dst_payload[226:221];
            cfg_savestate_slot_core <= cfg_mailbox_dst_payload[220:218];
            cfg_cheat_flags_core <= cfg_mailbox_dst_payload[217:186];
            cfg_cheat_addr_core <= cfg_mailbox_dst_payload[185:154];
            cfg_cheat_compare_core <= cfg_mailbox_dst_payload[153:122];
            cfg_cheat_replace_core <= cfg_mailbox_dst_payload[121:90];
            cfg_sensor_solar_core <= cfg_mailbox_dst_payload[68:66];
            cfg_sensor_tilt_x_core <= $signed(cfg_mailbox_dst_payload[81:74]);
            cfg_sensor_tilt_y_core <= $signed(cfg_mailbox_dst_payload[89:82]);
            cfg_rtc_savedtime_core <= {cfg_mailbox_dst_payload[11:2],
                                       cfg_mailbox_dst_payload[65:34]};
            cfg_rtc_save_loaded_core <= cfg_mailbox_dst_payload[33];
            cfg_display_frame_idx_core <= cfg_mailbox_dst_payload[1:0];
        end
    end

    // --- 2. 物理按键 CDC 同步与合并 ---
    wire [9:0] physical_keys_sync;
    gba_physical_key_mapper u_physical_key_mapper (
        .clk_core(clk_core),
        .rst_core_n(rst_core_n),
        .btns(btns),
        .sws(sws),
        .physical_keys(physical_keys_sync)
    );

    // 最终核心按键输入 = AXI控制值 | 已同步的物理输入值
    assign cfg_keys_core = cfg_keys_core_reg | physical_keys_sync;
    assign physical_keys_core = physical_keys_sync;

endmodule


// Zybo Z7 PL buttons are active high when pressed (Board Reference Manual §13).
// Synchronize raw pin levels first, then apply the fixed consumer mapping:
// BTN0/BTN3 stay Right/Left; SW0..SW3 provide A/B/Select/Start.
// The 1,000,000-cycle default requires 10 ms stability at the 100 MHz core clock.
module gba_physical_key_mapper #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000
) (
    input wire clk_core,
    input wire rst_core_n,
    input wire [3:0] btns,
    input wire [3:0] sws,
    output wire [9:0] physical_keys
);
    (* ASYNC_REG = "TRUE" *) reg [3:0] btns_meta;
    (* ASYNC_REG = "TRUE" *) reg [3:0] btns_sync;
    (* ASYNC_REG = "TRUE" *) reg [3:0] sws_meta;
    (* ASYNC_REG = "TRUE" *) reg [3:0] sws_sync;
    reg [3:0] btns_debounced;
    localparam integer DEBOUNCE_COUNT_WIDTH = (DEBOUNCE_CYCLES > 1) ?
                                               $clog2(DEBOUNCE_CYCLES) : 1;
    reg [DEBOUNCE_COUNT_WIDTH-1:0] btn_debounce_count [0:3];
    integer debounce_index;

    always @(posedge clk_core) begin
        if (!rst_core_n) begin
            btns_meta <= 4'b0000;
            btns_sync <= 4'b0000;
            sws_meta <= 4'b0000;
            sws_sync <= 4'b0000;
            btns_debounced <= 4'b0000;
            for (debounce_index = 0; debounce_index < 4; debounce_index = debounce_index + 1)
                btn_debounce_count[debounce_index] <= {DEBOUNCE_COUNT_WIDTH{1'b0}};
        end else begin
            btns_meta <= btns;
            btns_sync <= btns_meta;
            sws_meta <= sws;
            sws_sync <= sws_meta;
            for (debounce_index = 0; debounce_index < 4; debounce_index = debounce_index + 1) begin
                if (btns_sync[debounce_index] == btns_debounced[debounce_index]) begin
                    btn_debounce_count[debounce_index] <= {DEBOUNCE_COUNT_WIDTH{1'b0}};
                end else if (btn_debounce_count[debounce_index] >= DEBOUNCE_CYCLES - 1) begin
                    btns_debounced[debounce_index] <= btns_sync[debounce_index];
                    btn_debounce_count[debounce_index] <= {DEBOUNCE_COUNT_WIDTH{1'b0}};
                end else begin
                    btn_debounce_count[debounce_index] <= btn_debounce_count[debounce_index] + 1'b1;
                end
            end
        end
    end

    // GBA key order is {L,R,Down,Up,Left,Right,Start,Select,B,A}.
    assign physical_keys = {
        2'b00,
        btns_debounced[1], btns_debounced[2], btns_debounced[3], btns_debounced[0],
        sws_sync[3], sws_sync[2], sws_sync[1], sws_sync[0]
    };
endmodule
