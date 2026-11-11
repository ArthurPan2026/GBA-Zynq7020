//------------------------------------------------------------------------------
// @file ddram_mux.sv
// @module-contract
// 职责: DDR 请求仲裁与预取层；DDR 访问多路复用器，在多个 GBA/帧缓存通道之间仲裁并提供短突发预取。
// 上游: GBA core 多个 MiSTer 风格内存通道。
// 下游: ddr_axi_backend 的统一 DDRAM 请求接口。
// 时钟域: clk100/clk_core/clk_100/s_axi_aclk 等，具体以端口命名为准。
// 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
// 关键协议: 内部 DDRAM 请求/ready、读数据有效、突发长度和预取命中共同决定一次访问何时完成。
// 设计注意点: 在各通道之间轮转仲裁；对取指/总线读做短突发预取；把返回数据按请求地址重新对齐给发起通道；本注释只解释设计意图，不改变 RTL/XDC 功能。
//------------------------------------------------------------------------------
// ddram_mux.sv: Zynq DDR multiplexer with short-burst read-ahead.
// Keeps the MiSTer RAM contract while using AXI-friendly sequential bursts.

`include "ps_pl_contract_generated.vh"

module ddram_mux (
    input  logic         DDRAM_CLK,
    input  logic         rst_n,
    input  logic         DDRAM_BUSY,
    output logic [7:0]   DDRAM_BURSTCNT,
    output logic [28:0]  DDRAM_ADDR,
    input  logic [63:0]  DDRAM_DOUT,
    input  logic         DDRAM_DOUT_READY,
    input  logic         DDRAM_DONE,
    output logic         DDRAM_RD,
    output logic [63:0]  DDRAM_DIN,
    output logic [7:0]   DDRAM_BE,
    output logic         DDRAM_WE,
    input  logic         CFG_ROM_DDR_SAFE,

    // One-entry command mailbox endpoint. The payload is {sequence, command}
    // and remains stable until MEM_CMD_READY completes the command.
    input  logic         MEM_CMD_VALID,
    input  logic [63:0]  MEM_CMD_PAYLOAD,
    input  logic         MEM_CMD_ACK_ENABLE,
    output logic         MEM_CMD_READY,
    output logic         ch4_write_done,
    output logic         MEM_ACCEPT_NEW,
    input  logic         DDRAM_ERR_PULSE,
    input  logic [31:0]  DDRAM_ERR_VEC,
    input  logic         DDRAM_FATAL_FAULT,
    output logic [4:0]   MEM_STATUS,
    output logic [3:0]   MEM_ERROR,
    output logic [27:0]  MEM_ERROR_ADDR,
    output logic [31:0]  ROM_EPOCH,

    // Channel 1: Core Instruction/Data
    input  logic [27:1]  ch1_addr,
    output logic [63:0]  ch1_dout,
    input  logic [15:0]  ch1_din,
    input  logic         ch1_req,
    input  logic         ch1_rnw,
    output logic         ch1_ready,

    // Channel 2: Generic Bus
    input  logic [27:1]  ch2_addr,
    output logic [31:0]  ch2_dout,
    input  logic [31:0]  ch2_din,
    input  logic         ch2_req,
    input  logic         ch2_rnw,
    output logic         ch2_ready,

    // Channel 3: Unused/Reserved
    input  logic [25:1]  ch3_addr,
    output logic [15:0]  ch3_dout,
    input  logic [15:0]  ch3_din,
    input  logic         ch3_req,
    input  logic         ch3_rnw,
    output logic         ch3_ready,

    // Channel 4: Save State
    input  logic [27:1]  ch4_addr,
    output logic [63:0]  ch4_dout,
    input  logic [63:0]  ch4_din,
    input  logic         ch4_req,
    input  logic         ch4_rnw,
    input  logic [7:0]   ch4_be,
    output logic         ch4_ready,

    // Channel 5: Framebuffer
    input  logic [27:1]  ch5_addr,
    output logic [63:0]  ch5_dout,
    input  logic [63:0]  ch5_din,
    input  logic         ch5_req,
    input  logic         ch5_rnw,
    output logic         ch5_ready
);

    localparam logic [1:0] S_IDLE      = 2'd0;
    localparam logic [1:0] S_WAIT_READ = 2'd1;
    localparam logic [7:0] C_READ_BURST_MIN = 8'd1;
    localparam logic [7:0] C_READ_BURST_MID = 8'd2;
    localparam logic [7:0] C_READ_BURST_MAX = 8'd4;
    localparam logic [19:0] C_SDRAM_READ_TIMEOUT = 20'd250000;

    logic [7:0]  ram_burst = 8'd1;
    logic [63:0] ram_q[5:1];
    logic [27:1] resp_addr[5:1];
    logic [63:0] ram_data;
    logic [27:1] ram_address;
    logic        ram_read = 1'b0;
    logic        ram_write = 1'b0;
    logic [7:0]  ram_be;
    logic [5:1]  ready = '0;

    logic [27:1] cache_addr[2:1];
    logic [2:1]  cached = 2'd0;
    logic [27:1] seq_last_addr[2:1];
    logic [2:1]  seq_last_valid = 2'd0;
    logic [1:0]  seq_depth[2:1];
    logic        rom_ddr_safe_prev = 1'b0;

    // Three prefetched 64-bit lines per latency-sensitive channel.
    logic [63:0] pf_q[2:1][2:0];
    logic [27:1] pf_addr[2:1][2:0];
    logic        pf_valid[2:1][2:0];

    logic [1:0]  state = S_IDLE;
    logic [19:0] read_watch_ctr = 20'd0;
    logic [2:0]  active_ch = 3'd0;
    logic [27:1] active_addr;
    logic [7:0]  active_burst = 8'd1;
    logic [7:0]  read_beat = 8'd0;
    (* MARK_DEBUG = "TRUE" *) logic [31:0] grant_count_ch1;
    (* MARK_DEBUG = "TRUE" *) logic [31:0] grant_count_ch2;
    (* MARK_DEBUG = "TRUE" *) logic [31:0] grant_count_ch3;
    (* MARK_DEBUG = "TRUE" *) logic [31:0] grant_count_ch4;
    (* MARK_DEBUG = "TRUE" *) logic [31:0] grant_count_ch5;

    logic [5:1]  ch_rq = '0;
    logic [31:0] cache_epoch;
    logic [31:0] active_epoch;
    logic        active_faulted;
    logic        accept_new_requests;
    logic        cache_flush;
    logic        rom_mode_change;
    logic        lifecycle_drained;
    logic        ch4_write_inflight;
    logic [27:1] rq_addr[5:1];
    logic [63:0] rq_din[5:1];
    logic [7:0]  rq_be[5:1];
    logic [5:1]  rq_rnw;

    logic [2:0]  rr_last_grant = 3'd5;
    logic [5:1]  pending_req;
    logic [2:0]  grant_ch;
    logic        grant_valid;

    logic [27:1] cur_addr[5:1];
    logic [63:0] cur_din[5:1];
    logic [7:0]  cur_be[5:1];
    logic [5:1]  cur_rnw;

    assign DDRAM_BURSTCNT = ram_burst;
    assign DDRAM_BE       = ram_read ? 8'hFF : ram_be;
    assign DDRAM_ADDR     = {4'b0011, ram_address[27:3]};
    assign DDRAM_RD       = ram_read;
    assign DDRAM_DIN      = ram_data;
    assign DDRAM_WE       = ram_write;

    // Return data must be decoded with the completed request address, not the live bus address.
    assign ch1_dout  = resp_addr[1][2] ? {ram_q[1][31:0], ram_q[1][63:32]} : ram_q[1];
    assign ch2_dout  = resp_addr[2][2] ? ram_q[2][63:32] : ram_q[2][31:0];
    assign ch3_dout  = {ram_q[3][39:32], ram_q[3][7:0]};
    assign ch4_dout  = ram_q[4];
    assign ch5_dout  = ram_q[5];

    assign ch1_ready = ready[1];
    assign ch2_ready = ready[2];
    assign ch3_ready = ready[3];
    assign ch4_ready = ready[4];
    assign ch5_ready = ready[5];
    assign ch4_write_done = DDRAM_DONE && ch4_write_inflight;
    assign MEM_ACCEPT_NEW = accept_new_requests;

    assign rom_mode_change = (CFG_ROM_DDR_SAFE != rom_ddr_safe_prev);
    assign lifecycle_drained = (state == S_IDLE) && (ch_rq == '0) &&
                               !DDRAM_BUSY && !ram_read && !ram_write;

    ddram_lifecycle_ctrl u_lifecycle (
        .clk                  (DDRAM_CLK),
        .rst_n                (rst_n),
        .cmd_valid            (MEM_CMD_VALID),
        .cmd_payload          (MEM_CMD_PAYLOAD),
        .ack_enable           (MEM_CMD_ACK_ENABLE),
        .cmd_ready            (MEM_CMD_READY),
        .drained              (lifecycle_drained),
        .backend_error_pulse  (DDRAM_ERR_PULSE),
        .backend_error_vec    (DDRAM_ERR_VEC),
        .backend_fatal        (DDRAM_FATAL_FAULT),
        .accept_new_requests  (accept_new_requests),
        .cache_flush          (cache_flush),
        .mem_status           (MEM_STATUS),
        .mem_error            (MEM_ERROR),
        .mem_error_addr       (MEM_ERROR_ADDR),
        .rom_epoch            (ROM_EPOCH)
    );

    assign cur_addr[1] = ch_rq[1] ? rq_addr[1] : ch1_addr;
    assign cur_addr[2] = ch_rq[2] ? rq_addr[2] : ch2_addr;
    assign cur_addr[3] = ch_rq[3] ? rq_addr[3] : {ch3_addr, 2'b00};
    assign cur_addr[4] = ch_rq[4] ? rq_addr[4] : ch4_addr;
    assign cur_addr[5] = ch_rq[5] ? rq_addr[5] : ch5_addr;

    assign cur_din[1] = ch_rq[1] ? rq_din[1] : {4{ch1_din}};
    assign cur_din[2] = ch_rq[2] ? rq_din[2] : {2{ch2_din}};
    assign cur_din[3] = ch_rq[3] ? rq_din[3] : {24'd0, ch3_din[15:8], 24'd0, ch3_din[7:0]};
    assign cur_din[4] = ch_rq[4] ? rq_din[4] : ch4_din;
    assign cur_din[5] = ch_rq[5] ? rq_din[5] : ch5_din;

    assign cur_be[1]  = ch_rq[1] ? rq_be[1] : (8'h03 << {ch1_addr[2:1], 1'b0});
    assign cur_be[2]  = ch_rq[2] ? rq_be[2] : (ch2_addr[2] ? 8'hF0 : 8'h0F);
    assign cur_be[3]  = ch_rq[3] ? rq_be[3] : 8'hFF;
    assign cur_be[4]  = ch_rq[4] ? rq_be[4] : ch4_be;
    assign cur_be[5]  = ch_rq[5] ? rq_be[5] : 8'hFF;

    assign cur_rnw[1] = ch_rq[1] ? rq_rnw[1] : ch1_rnw;
    assign cur_rnw[2] = ch_rq[2] ? rq_rnw[2] : ch2_rnw;
    assign cur_rnw[3] = ch_rq[3] ? rq_rnw[3] : ch3_rnw;
    assign cur_rnw[4] = ch_rq[4] ? rq_rnw[4] : ch4_rnw;
    assign cur_rnw[5] = ch_rq[5] ? rq_rnw[5] : ch5_rnw;

    // @process-purpose: 为 DDR 请求仲裁与预取层生成本拍组合选择，供后级时序块或输出端口立即使用。
    // @process-mechanism: 把 ch*_req 与已挂起的 ch_rq 合成 pending_req，再从 rr_last_grant 的下一路开始扫描，得到 grant_ch/grant_valid。
    // @process-result: 结果是调用点或后级逻辑得到无状态的组合返回/选择值，不引入额外寄存器、握手或跨时钟域副作用。
    always_comb begin
        pending_req[1] = ch_rq[1] | (accept_new_requests && ch1_req);
        pending_req[2] = ch_rq[2] | (accept_new_requests && ch2_req);
        pending_req[3] = ch_rq[3] | (accept_new_requests && ch3_req);
        pending_req[4] = ch_rq[4] | (accept_new_requests && ch4_req);
        pending_req[5] = ch_rq[5] | (accept_new_requests && ch5_req);

        grant_ch    = 3'd0;
        grant_valid = 1'b0;

        unique case (rr_last_grant)
            3'd1: begin
                if (pending_req[2]) begin grant_ch = 3'd2; grant_valid = 1'b1; end
                else if (pending_req[3]) begin grant_ch = 3'd3; grant_valid = 1'b1; end
                else if (pending_req[4]) begin grant_ch = 3'd4; grant_valid = 1'b1; end
                else if (pending_req[5]) begin grant_ch = 3'd5; grant_valid = 1'b1; end
                else if (pending_req[1]) begin grant_ch = 3'd1; grant_valid = 1'b1; end
            end
            3'd2: begin
                if (pending_req[3]) begin grant_ch = 3'd3; grant_valid = 1'b1; end
                else if (pending_req[4]) begin grant_ch = 3'd4; grant_valid = 1'b1; end
                else if (pending_req[5]) begin grant_ch = 3'd5; grant_valid = 1'b1; end
                else if (pending_req[1]) begin grant_ch = 3'd1; grant_valid = 1'b1; end
                else if (pending_req[2]) begin grant_ch = 3'd2; grant_valid = 1'b1; end
            end
            3'd3: begin
                if (pending_req[4]) begin grant_ch = 3'd4; grant_valid = 1'b1; end
                else if (pending_req[5]) begin grant_ch = 3'd5; grant_valid = 1'b1; end
                else if (pending_req[1]) begin grant_ch = 3'd1; grant_valid = 1'b1; end
                else if (pending_req[2]) begin grant_ch = 3'd2; grant_valid = 1'b1; end
                else if (pending_req[3]) begin grant_ch = 3'd3; grant_valid = 1'b1; end
            end
            3'd4: begin
                if (pending_req[5]) begin grant_ch = 3'd5; grant_valid = 1'b1; end
                else if (pending_req[1]) begin grant_ch = 3'd1; grant_valid = 1'b1; end
                else if (pending_req[2]) begin grant_ch = 3'd2; grant_valid = 1'b1; end
                else if (pending_req[3]) begin grant_ch = 3'd3; grant_valid = 1'b1; end
                else if (pending_req[4]) begin grant_ch = 3'd4; grant_valid = 1'b1; end
            end
            default: begin
                if (pending_req[1]) begin grant_ch = 3'd1; grant_valid = 1'b1; end
                else if (pending_req[2]) begin grant_ch = 3'd2; grant_valid = 1'b1; end
                else if (pending_req[3]) begin grant_ch = 3'd3; grant_valid = 1'b1; end
                else if (pending_req[4]) begin grant_ch = 3'd4; grant_valid = 1'b1; end
                else if (pending_req[5]) begin grant_ch = 3'd5; grant_valid = 1'b1; end
            end
        endcase
    end

    // @process-purpose: 封装 DDR 请求仲裁与预取层中重复使用的纯组合换算规则，避免地址/位域规则散落在调用点。
    // @process-mechanism: 比较请求地址和预取条目的 64-bit line 地址位，只要 valid 且 line 相同就视为命中。
    // @process-result: 结果是调用点或后级逻辑得到无状态的组合返回/选择值，不引入额外寄存器、握手或跨时钟域副作用。
    function automatic logic pf_match(
        input logic [27:1] a,
        input logic        valid,
        input logic [27:1] pfa
    );
    begin
        pf_match = valid && (pfa[27:3] == a[27:3]);
    end
    endfunction

    function automatic logic [7:0] select_burst(
        input logic       safe_mode,
        input logic       next_line,
        input logic [1:0] depth
    );
    begin
        if (safe_mode) begin
            select_burst = C_READ_BURST_MIN;
        end else if (!next_line) begin
            select_burst = C_READ_BURST_MIN;
        end else if (depth == 2'd0) begin
            select_burst = C_READ_BURST_MID;
        end else begin
            select_burst = C_READ_BURST_MAX;
        end
    end
    endfunction

    function automatic logic [7:0] clamp_burst_4k(
        input logic [27:1] addr,
        input logic [7:0]  burst
    );
        logic [9:0] addr_line;
        logic [9:0] last_line;
        logic [9:0] lines_fit;
    begin
        addr_line = {1'b0, addr[11:3]};
        last_line = addr_line + {2'b00, burst} - 10'd1;
        if (last_line <= 10'd511) begin
            clamp_burst_4k = burst;
        end else begin
            lines_fit = 10'd512 - addr_line;
            if (lines_fit == 10'd0) begin
                clamp_burst_4k = 8'd1;
            end else begin
                clamp_burst_4k = lines_fit[7:0];
            end
        end
        if (clamp_burst_4k == 8'd0) begin
            clamp_burst_4k = 8'd1;
        end
    end
    endfunction

    // @process-purpose: 封装 DDR 请求仲裁与预取层状态机的公共收尾动作，保证完成、错误和清理路径执行一致的赋值。
    // @process-mechanism: 清掉指定通道三个预取 valid 位，使后续访问重新从 DDR 拉取。
    // @process-result: 结果是被写通道的旧预取条目立即失效，后续读请求不会误用被写操作覆盖前的缓存数据。
    task automatic invalidate_prefetch(input int unsigned channel);
    begin
        pf_valid[channel][0] <= 1'b0;
        pf_valid[channel][1] <= 1'b0;
        pf_valid[channel][2] <= 1'b0;
    end
    endtask

    task automatic invalidate_all_cache;
    begin
        cached <= '0;
        seq_last_valid <= '0;
        seq_depth[1] <= 2'd0;
        seq_depth[2] <= 2'd0;
        for (int c = 1; c <= 2; c++) begin
            for (int b = 0; b < 3; b++) begin
                pf_valid[c][b] <= 1'b0;
            end
        end
    end
    endtask

    task automatic start_read(
        input logic [2:0]  channel,
        input logic [27:1] addr,
        input logic [7:0]  burst
    );
    begin
        read_watch_ctr <= 20'd0;
        active_ch    <= channel;
        active_addr  <= addr;
        active_burst <= burst;
        active_epoch <= cache_epoch;
        active_faulted <= 1'b0;
        read_beat    <= 8'd0;
        ram_address  <= addr;
        ram_burst    <= burst;
        ram_read     <= 1'b1;
        state        <= S_WAIT_READ;
    end
    endtask

    // @process-purpose: 在 DDRAM_CLK 时钟域处理 DDR 请求仲裁与预取层的请求、事件或计数条件，并把结果锁存为下游可采样的控制/状态信号。
    // @process-mechanism: 进入时先缓存各通道请求；空闲时优先处理预取命中，否则按 grant_ch 发起读写；读返回时填充 ram_q/pf_q 并向 active_ch 置 ready。
    // @process-result: 结果是各通道只看到自己的 ready/data 返回，DDR 后端只看到已经仲裁并对齐好的单一路请求。
    always_ff @(posedge DDRAM_CLK) begin
        if (!rst_n) begin
            ram_burst <= 8'd1;
            ram_q[1] <= 64'd0; ram_q[2] <= 64'd0; ram_q[3] <= 64'd0;
            ram_q[4] <= 64'd0; ram_q[5] <= 64'd0;
            resp_addr[1] <= '0; resp_addr[2] <= '0; resp_addr[3] <= '0;
            resp_addr[4] <= '0; resp_addr[5] <= '0;
            ram_data <= 64'd0;
            ram_address <= '0;
            ram_read <= 1'b0;
            ram_write <= 1'b0;
            ram_be <= 8'd0;
            ready <= '0;
            cache_addr[1] <= '0; cache_addr[2] <= '0;
            cached <= '0;
            seq_last_addr[1] <= '0; seq_last_addr[2] <= '0;
            seq_last_valid <= '0;
            seq_depth[1] <= 2'd0; seq_depth[2] <= 2'd0;
            rom_ddr_safe_prev <= CFG_ROM_DDR_SAFE;
            for (int c = 1; c <= 2; c++) begin
                for (int b = 0; b < 3; b++) begin
                    pf_q[c][b] <= 64'd0;
                    pf_addr[c][b] <= '0;
                    pf_valid[c][b] <= 1'b0;
                end
            end
            state <= S_IDLE;
            read_watch_ctr <= 20'd0;
            active_ch <= 3'd0;
            active_addr <= '0;
            active_burst <= 8'd1;
            read_beat <= 8'd0;
            cache_epoch <= 32'd0;
            active_epoch <= 32'd0;
            active_faulted <= 1'b0;
            ch4_write_inflight <= 1'b0;
            ch_rq <= '0;
            for (int c = 1; c <= 5; c++) begin
                rq_addr[c] <= '0;
                rq_din[c] <= 64'd0;
                rq_be[c] <= 8'd0;
                rq_rnw[c] <= 1'b0;
            end
            rr_last_grant <= 3'd5;
            grant_count_ch1 <= 32'd0;
            grant_count_ch2 <= 32'd0;
            grant_count_ch3 <= 32'd0;
            grant_count_ch4 <= 32'd0;
            grant_count_ch5 <= 32'd0;
        end else begin
        ready     <= 5'd0;
        ram_read  <= 1'b0;
        ram_write <= 1'b0;

        if (accept_new_requests && ch1_req && !ch_rq[1]) begin
            rq_addr[1] <= ch1_addr;
            rq_din[1]  <= {4{ch1_din}};
            rq_be[1]   <= 8'h03 << {ch1_addr[2:1], 1'b0};
            rq_rnw[1]  <= ch1_rnw;
        end
        if (accept_new_requests && ch2_req && !ch_rq[2]) begin
            rq_addr[2] <= ch2_addr;
            rq_din[2]  <= {2{ch2_din}};
            rq_be[2]   <= ch2_addr[2] ? 8'hF0 : 8'h0F;
            rq_rnw[2]  <= ch2_rnw;
        end
        if (accept_new_requests && ch3_req && !ch_rq[3]) begin
            rq_addr[3] <= {ch3_addr, 2'b00};
            rq_din[3]  <= {24'd0, ch3_din[15:8], 24'd0, ch3_din[7:0]};
            rq_be[3]   <= 8'hFF;
            rq_rnw[3]  <= ch3_rnw;
        end
        if (accept_new_requests && ch4_req && !ch_rq[4]) begin
            rq_addr[4] <= ch4_addr;
            rq_din[4]  <= ch4_din;
            rq_be[4]   <= ch4_be;
            rq_rnw[4]  <= ch4_rnw;
        end
        if (accept_new_requests && ch5_req && !ch_rq[5]) begin
            rq_addr[5] <= ch5_addr;
            rq_din[5]  <= ch5_din;
            rq_be[5]   <= 8'hFF;
            rq_rnw[5]  <= ch5_rnw;
        end
        if (DDRAM_DONE && ch4_write_inflight) begin
            ch4_write_inflight <= 1'b0;
        end
        if (accept_new_requests) begin
            ch_rq <= ch_rq | {ch5_req, ch4_req, ch3_req, ch2_req, ch1_req};
        end
        if (DDRAM_ERR_PULSE && (state == S_WAIT_READ)) begin
            active_faulted <= 1'b1;
        end

        if (rom_mode_change) begin
            rom_ddr_safe_prev <= CFG_ROM_DDR_SAFE;
        end
        if (rom_mode_change || cache_flush) begin
            cache_epoch <= cache_epoch + 32'd1;
            invalidate_all_cache();
        end

        if (state == S_WAIT_READ && active_faulted && !DDRAM_BUSY) begin
            // The backend completed its drain after a fault. Leave the guest
            // request unacknowledged; it will be sampled again after RESUME.
            state <= S_IDLE;
            read_watch_ctr <= 20'd0;
            active_ch <= 3'd0;
            active_faulted <= 1'b0;
        end else if (state == S_WAIT_READ) begin
            if (DDRAM_DOUT_READY) begin
                if ((active_epoch == cache_epoch) && !rom_mode_change &&
                    !cache_flush && !DDRAM_ERR_PULSE && !active_faulted) begin
                    if (active_ch <= 3'd2) begin
                        if (read_beat == 8'd0) begin
                            ram_q[active_ch]      <= DDRAM_DOUT;
                            resp_addr[active_ch]  <= active_addr;
                            cache_addr[active_ch] <= active_addr;
                            cached[active_ch]     <= 1'b1;
                            ready[active_ch]      <= 1'b1;
                        end else if (read_beat <= 8'd3) begin
                            pf_q[active_ch][read_beat - 8'd1] <= DDRAM_DOUT;
                            // Tag each prefetched line by its 64-bit line index.
                            pf_addr[active_ch][read_beat - 8'd1] <= {
                                active_addr[27:3] + {{17{1'b0}}, read_beat},
                                2'b00
                            };
                            pf_valid[active_ch][read_beat - 8'd1] <= 1'b1;
                        end
                    end else begin
                        ram_q[active_ch] <= DDRAM_DOUT;
                        resp_addr[active_ch] <= active_addr;
                        ready[active_ch] <= 1'b1;
                    end
                end

                read_watch_ctr <= 20'd0;
                if (read_beat >= (active_burst - 8'd1)) begin
                    state <= S_IDLE;
                end else begin
                    read_beat <= read_beat + 8'd1;
                end
            end else begin
                read_watch_ctr <= read_watch_ctr + 20'd1;
                if (read_watch_ctr >= C_SDRAM_READ_TIMEOUT) begin
                    state <= S_IDLE;
                end
            end
        end else if (!DDRAM_BUSY && grant_valid && !rom_mode_change &&
                     !cache_flush && !DDRAM_ERR_PULSE && !DDRAM_FATAL_FAULT) begin
            rr_last_grant <= grant_ch;
            ch_rq[grant_ch] <= 1'b0;
            unique case (grant_ch)
              3'd1: if (grant_count_ch1 != 32'hFFFF_FFFF) grant_count_ch1 <= grant_count_ch1 + 32'd1;
              3'd2: if (grant_count_ch2 != 32'hFFFF_FFFF) grant_count_ch2 <= grant_count_ch2 + 32'd1;
              3'd3: if (grant_count_ch3 != 32'hFFFF_FFFF) grant_count_ch3 <= grant_count_ch3 + 32'd1;
              3'd4: if (grant_count_ch4 != 32'hFFFF_FFFF) grant_count_ch4 <= grant_count_ch4 + 32'd1;
              default: if (grant_count_ch5 != 32'hFFFF_FFFF) grant_count_ch5 <= grant_count_ch5 + 32'd1;
            endcase

            unique case (grant_ch)
                3'd1: begin
                    ram_data <= cur_din[1];
                    ram_be   <= cur_be[1];
                    if (!cur_rnw[1]) begin
                        ram_address <= cur_addr[1];
                        ram_burst   <= 8'd1;
                        ram_write   <= 1'b1;
                        cached[1]   <= 1'b0;
                        seq_last_valid[1] <= 1'b0;
                        seq_depth[1] <= 2'd0;
                        invalidate_prefetch(1);
                        ready[1]    <= 1'b1;
                    end else if (cached[1] && (cache_addr[1][27:3] == cur_addr[1][27:3])) begin
                        resp_addr[1] <= cur_addr[1];
                        seq_last_addr[1] <= cur_addr[1];
                        seq_last_valid[1] <= 1'b1;
                        ready[1] <= 1'b1;
                    end else if (!CFG_ROM_DDR_SAFE && pf_match(cur_addr[1], pf_valid[1][0], pf_addr[1][0])) begin
                        ram_q[1]       <= pf_q[1][0];
                        resp_addr[1]   <= cur_addr[1];
                        cache_addr[1]  <= cur_addr[1];
                        cached[1]      <= 1'b1;
                        pf_valid[1][0] <= 1'b0;
                        seq_last_addr[1] <= cur_addr[1];
                        seq_last_valid[1] <= 1'b1;
                        ready[1]       <= 1'b1;
                    end else if (!CFG_ROM_DDR_SAFE && pf_match(cur_addr[1], pf_valid[1][1], pf_addr[1][1])) begin
                        ram_q[1]       <= pf_q[1][1];
                        resp_addr[1]   <= cur_addr[1];
                        cache_addr[1]  <= cur_addr[1];
                        cached[1]      <= 1'b1;
                        pf_valid[1][1] <= 1'b0;
                        seq_last_addr[1] <= cur_addr[1];
                        seq_last_valid[1] <= 1'b1;
                        ready[1]       <= 1'b1;
                    end else if (!CFG_ROM_DDR_SAFE && pf_match(cur_addr[1], pf_valid[1][2], pf_addr[1][2])) begin
                        ram_q[1]       <= pf_q[1][2];
                        resp_addr[1]   <= cur_addr[1];
                        cache_addr[1]  <= cur_addr[1];
                        cached[1]      <= 1'b1;
                        pf_valid[1][2] <= 1'b0;
                        seq_last_addr[1] <= cur_addr[1];
                        seq_last_valid[1] <= 1'b1;
                        ready[1]       <= 1'b1;
                    end else begin
                        logic next_line;
                        next_line = seq_last_valid[1] &&
                                    ((seq_last_addr[1][27:3] + 25'd1) == cur_addr[1][27:3]);
                        cached[1] <= 1'b0;
                        seq_last_addr[1] <= cur_addr[1];
                        seq_last_valid[1] <= 1'b1;
                        if (next_line) begin
                            if (seq_depth[1] != 2'd3) begin
                                seq_depth[1] <= seq_depth[1] + 2'd1;
                            end
                        end else begin
                            seq_depth[1] <= 2'd0;
                        end
                        invalidate_prefetch(1);
                        start_read(3'd1,
                                   cur_addr[1],
                                   clamp_burst_4k(cur_addr[1],
                                                  select_burst(CFG_ROM_DDR_SAFE, next_line, seq_depth[1])));
                    end
                end

                3'd2: begin
                    ram_data <= cur_din[2];
                    ram_be   <= cur_be[2];
                    if (!cur_rnw[2]) begin
                        ram_address <= cur_addr[2];
                        ram_burst   <= 8'd1;
                        ram_write   <= 1'b1;
                        cached[2]   <= 1'b0;
                        seq_last_valid[2] <= 1'b0;
                        seq_depth[2] <= 2'd0;
                        invalidate_prefetch(2);
                        ready[2]    <= 1'b1;
                    end else if (cached[2] && (cache_addr[2][27:3] == cur_addr[2][27:3])) begin
                        resp_addr[2] <= cur_addr[2];
                        seq_last_addr[2] <= cur_addr[2];
                        seq_last_valid[2] <= 1'b1;
                        ready[2] <= 1'b1;
                    end else if (!CFG_ROM_DDR_SAFE && pf_match(cur_addr[2], pf_valid[2][0], pf_addr[2][0])) begin
                        ram_q[2]       <= pf_q[2][0];
                        resp_addr[2]   <= cur_addr[2];
                        cache_addr[2]  <= cur_addr[2];
                        cached[2]      <= 1'b1;
                        pf_valid[2][0] <= 1'b0;
                        seq_last_addr[2] <= cur_addr[2];
                        seq_last_valid[2] <= 1'b1;
                        ready[2]       <= 1'b1;
                    end else if (!CFG_ROM_DDR_SAFE && pf_match(cur_addr[2], pf_valid[2][1], pf_addr[2][1])) begin
                        ram_q[2]       <= pf_q[2][1];
                        resp_addr[2]   <= cur_addr[2];
                        cache_addr[2]  <= cur_addr[2];
                        cached[2]      <= 1'b1;
                        pf_valid[2][1] <= 1'b0;
                        seq_last_addr[2] <= cur_addr[2];
                        seq_last_valid[2] <= 1'b1;
                        ready[2]       <= 1'b1;
                    end else if (!CFG_ROM_DDR_SAFE && pf_match(cur_addr[2], pf_valid[2][2], pf_addr[2][2])) begin
                        ram_q[2]       <= pf_q[2][2];
                        resp_addr[2]   <= cur_addr[2];
                        cache_addr[2]  <= cur_addr[2];
                        cached[2]      <= 1'b1;
                        pf_valid[2][2] <= 1'b0;
                        seq_last_addr[2] <= cur_addr[2];
                        seq_last_valid[2] <= 1'b1;
                        ready[2]       <= 1'b1;
                    end else begin
                        logic next_line;
                        next_line = seq_last_valid[2] &&
                                    ((seq_last_addr[2][27:3] + 25'd1) == cur_addr[2][27:3]);
                        cached[2] <= 1'b0;
                        seq_last_addr[2] <= cur_addr[2];
                        seq_last_valid[2] <= 1'b1;
                        if (next_line) begin
                            if (seq_depth[2] != 2'd3) begin
                                seq_depth[2] <= seq_depth[2] + 2'd1;
                            end
                        end else begin
                            seq_depth[2] <= 2'd0;
                        end
                        invalidate_prefetch(2);
                        start_read(3'd2,
                                   cur_addr[2],
                                   clamp_burst_4k(cur_addr[2],
                                                  select_burst(CFG_ROM_DDR_SAFE, next_line, seq_depth[2])));
                    end
                end

                3'd3: begin
                    ram_data    <= cur_din[3];
                    ram_be      <= cur_be[3];
                    ram_address <= cur_addr[3];
                    ram_burst   <= 8'd1;
                    if (!cur_rnw[3]) begin
                        ram_write <= 1'b1;
                        cached[2] <= 1'b0;
                        seq_last_valid[2] <= 1'b0;
                        seq_depth[2] <= 2'd0;
                        invalidate_prefetch(2);
                        ready[3]  <= 1'b1;
                    end else begin
                        start_read(3'd3, cur_addr[3], 8'd1);
                    end
                end

                3'd4: begin
                    ram_data    <= cur_din[4];
                    ram_be      <= cur_be[4];
                    ram_address <= cur_addr[4];
                    ram_burst   <= 8'd1;
                    if (!cur_rnw[4]) begin
                        ram_write <= 1'b1;
                        ch4_write_inflight <= 1'b1;
                        ready[4]  <= 1'b1;
                    end else begin
                        start_read(3'd4, cur_addr[4], 8'd1);
                    end
                end

                default: begin
                    ram_data    <= cur_din[5];
                    ram_be      <= cur_be[5];
                    ram_address <= cur_addr[5];
                    ram_burst   <= 8'd1;
                    if (!cur_rnw[5]) begin
                        ram_write <= 1'b1;
                        ready[5]  <= 1'b1;
                    end else begin
                        start_read(3'd5, cur_addr[5], 8'd1);
                    end
                end
            endcase
        end
        end
    end

`ifndef SYNTHESIS
  property p_channel4_write_busy_until_backend_retire;
    @(posedge DDRAM_CLK) disable iff (!rst_n)
      ch4_write_inflight && !DDRAM_DONE |=> ch4_write_inflight;
  endproperty
  assert property (p_channel4_write_busy_until_backend_retire);
`endif
endmodule


//------------------------------------------------------------------------------
// @module-contract
// One-outstanding DDR lifecycle command controller. MEM_CMD_PAYLOAD is held by
// the upstream CDC mailbox until MEM_CMD_READY. QUIESCE blocks new grants and
// waits for the backend plus all accepted channel requests to drain. FLUSH_ROM
// is legal only after that drain; it clears ROM cache state and advances the
// externally visible epoch. RESUME requires a completed flush and no soft or
// fatal fault. CLEAR_ERROR is only accepted while quiesced and drained.
//------------------------------------------------------------------------------
module ddram_lifecycle_ctrl (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        cmd_valid,
  input  logic [63:0] cmd_payload,
  input  logic        ack_enable,
  output logic        cmd_ready,
  input  logic        drained,
  input  logic        backend_error_pulse,
  input  logic [31:0] backend_error_vec,
  input  logic        backend_fatal,
  output logic        accept_new_requests,
  output logic        cache_flush,
  output logic [4:0]  mem_status,
  output logic [3:0]  mem_error,
  output logic [27:0] mem_error_addr,
  output logic [31:0] rom_epoch
);
  typedef enum logic [2:0] {
    CMD_IDLE,
    CMD_EXEC,
    CMD_QUIESCE_WAIT,
    CMD_FLUSH_APPLY,
    CMD_FLUSH_WAIT,
    CMD_ACK
  } cmd_state_t;

  cmd_state_t cmd_state;
  logic [31:0] cmd_word;
  logic [31:0] cmd_seq;
  logic        quiesce_requested;
  logic        quiesced;
  logic        flush_since_quiesce;
  logic        faulted;
  logic        fatal_fault;
  logic        flush_busy;
  logic [31:0] status_word;

  assign cmd_ready = (cmd_state == CMD_ACK) && ack_enable;
  assign accept_new_requests = !quiesce_requested && !quiesced &&
                               !faulted && !fatal_fault;
  always_comb begin
    status_word = 32'd0;
    if (quiesced) status_word |= `PS_PL_MEM_STATUS_QUIESCED;
    if (quiesced && drained) status_word |= `PS_PL_MEM_STATUS_DRAINED;
    if (flush_busy) status_word |= `PS_PL_MEM_STATUS_FLUSH_BUSY;
    if (faulted) status_word |= `PS_PL_MEM_STATUS_FAULTED;
    if (fatal_fault) status_word |= `PS_PL_MEM_STATUS_FATAL_FAULT;
    mem_status = status_word[4:0];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cmd_state <= CMD_IDLE;
      cmd_word <= 32'd0;
      cmd_seq <= 32'd0;
      quiesce_requested <= 1'b0;
      quiesced <= 1'b0;
      flush_since_quiesce <= 1'b0;
      faulted <= 1'b0;
      fatal_fault <= 1'b0;
      flush_busy <= 1'b0;
      cache_flush <= 1'b0;
      mem_error <= 4'd0;
      mem_error_addr <= 28'd0;
      rom_epoch <= 32'd0;
    end else begin
      cache_flush <= 1'b0;

      if (backend_error_pulse) begin
        if (mem_error == 4'd0) begin
          mem_error <= (backend_error_vec[31:28] == 4'd0)
                         ? 4'hD : backend_error_vec[31:28];
          mem_error_addr <= backend_error_vec[27:0];
        end
        faulted <= 1'b1;
        quiesce_requested <= 1'b1;
        quiesced <= 1'b0;
      end

      if (backend_fatal) begin
        fatal_fault <= 1'b1;
        faulted <= 1'b1;
        quiesce_requested <= 1'b1;
        quiesced <= 1'b0;
      end

      if (quiesce_requested && drained && !fatal_fault) begin
        quiesced <= 1'b1;
      end

      case (cmd_state)
        CMD_IDLE: begin
          if (cmd_valid) begin
            cmd_word <= cmd_payload[31:0];
            cmd_seq <= cmd_payload[63:32];
            if (cmd_payload[31:0] == `PS_PL_MEM_CMD_QUIESCE) begin
              quiesce_requested <= 1'b1;
              quiesced <= 1'b0;
              flush_since_quiesce <= 1'b0;
            end
            cmd_state <= CMD_EXEC;
          end
        end

        CMD_EXEC: begin
          case (cmd_word)
            `PS_PL_MEM_CMD_QUIESCE: begin
              quiesce_requested <= 1'b1;
              quiesced <= 1'b0;
              flush_since_quiesce <= 1'b0;
              if (fatal_fault) begin
                mem_error <= (mem_error == 4'd0) ? 4'hF : mem_error;
                cmd_state <= CMD_ACK;
              end else begin
                cmd_state <= CMD_QUIESCE_WAIT;
              end
            end

            `PS_PL_MEM_CMD_FLUSH_ROM: begin
              if (quiesced && drained && !fatal_fault) begin
                flush_busy <= 1'b1;
                cmd_state <= CMD_FLUSH_APPLY;
              end else begin
                if (mem_error == 4'd0) begin
                  mem_error <= 4'hF;
                  mem_error_addr <= 28'd0;
                end
                faulted <= 1'b1;
                quiesce_requested <= 1'b1;
                cmd_state <= CMD_ACK;
              end
            end

            `PS_PL_MEM_CMD_CLEAR_ERROR: begin
              if (quiesced && drained && !fatal_fault && flush_since_quiesce) begin
                mem_error <= 4'd0;
                mem_error_addr <= 28'd0;
                faulted <= 1'b0;
                cmd_state <= CMD_ACK;
              end else begin
                if (mem_error == 4'd0) begin
                  mem_error <= 4'hF;
                  mem_error_addr <= 28'd0;
                end
                faulted <= 1'b1;
                quiesce_requested <= 1'b1;
                cmd_state <= CMD_ACK;
              end
            end

            `PS_PL_MEM_CMD_RESUME: begin
              if (quiesced && drained && flush_since_quiesce &&
                  !faulted && !fatal_fault && (mem_error == 4'd0)) begin
                quiesce_requested <= 1'b0;
                quiesced <= 1'b0;
                flush_since_quiesce <= 1'b0;
                cmd_state <= CMD_ACK;
              end else begin
                if (mem_error == 4'd0) begin
                  mem_error <= 4'hF;
                  mem_error_addr <= 28'd0;
                end
                faulted <= 1'b1;
                quiesce_requested <= 1'b1;
                cmd_state <= CMD_ACK;
              end
            end

            default: begin
              if (mem_error == 4'd0) begin
                mem_error <= 4'hF;
                mem_error_addr <= 28'd0;
              end
              faulted <= 1'b1;
              quiesce_requested <= 1'b1;
              cmd_state <= CMD_ACK;
            end
          endcase
        end

        CMD_QUIESCE_WAIT: begin
          if (fatal_fault) begin
            if (mem_error == 4'd0) mem_error <= 4'hF;
            cmd_state <= CMD_ACK;
          end else if (drained) begin
            quiesced <= 1'b1;
            cmd_state <= CMD_ACK;
          end
        end

        CMD_FLUSH_APPLY: begin
          cache_flush <= 1'b1;
          rom_epoch <= rom_epoch + 32'd1;
          flush_since_quiesce <= 1'b1;
          cmd_state <= CMD_FLUSH_WAIT;
        end

        CMD_FLUSH_WAIT: begin
          flush_busy <= 1'b0;
          cmd_state <= CMD_ACK;
        end

        CMD_ACK: begin
          if (cmd_valid && cmd_ready) begin
            cmd_state <= CMD_IDLE;
          end
        end

        default: begin
          fatal_fault <= 1'b1;
          faulted <= 1'b1;
          quiesce_requested <= 1'b1;
          if (mem_error == 4'd0) mem_error <= 4'hE;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  property p_flush_only_when_quiesced_and_drained;
    @(posedge clk) disable iff (!rst_n)
      cache_flush |-> quiesced && drained && !fatal_fault;
  endproperty
  assert property (p_flush_only_when_quiesced_and_drained);

  property p_no_resume_with_fault;
    @(posedge clk) disable iff (!rst_n)
      accept_new_requests |-> !faulted && !fatal_fault;
  endproperty
  assert property (p_no_resume_with_fault);


  property p_ack_waits_for_command;
    @(posedge clk) disable iff (!rst_n)
      cmd_ready |-> cmd_valid;
  endproperty
  assert property (p_ack_waits_for_command);

  property p_ack_keeps_original_sequence;
    @(posedge clk) disable iff (!rst_n)
      cmd_ready |-> cmd_valid && (cmd_payload[63:32] == cmd_seq);
  endproperty
  assert property (p_ack_keeps_original_sequence);
`endif
endmodule
