`timescale 1ns/1ps
module hdmi_runtime_status #(
  parameter integer SERIAL_ACTIVITY_DIV_BITS = 8,
  parameter integer PIXEL_ACTIVITY_DIV_BITS = 8
) (
  input  logic       aclk,
  input  logic       aresetn,
  input  logic       pixel_clk,
  input  logic       mmcm_locked_async,
  input  logic       pixel_resetn_async,
  input  logic       pixel_reset_ext_asserted_async,
  input  logic       serial_clk,
  input  logic       video_vsync_async,
  output logic [5:0] status
);
  logic [SERIAL_ACTIVITY_DIV_BITS-1:0] serial_activity_divider;
  logic [PIXEL_ACTIVITY_DIV_BITS-1:0] pixel_activity_divider;
  logic serial_activity_aresetn, pixel_activity_aresetn;
  logic serial_activity_toggle, pixel_activity_toggle;
  (* ASYNC_REG = "TRUE" *) logic pixel_resetn_meta, pixel_resetn_sync;
  (* ASYNC_REG = "TRUE" *) logic mmcm_lock_meta, mmcm_lock_sync;
  (* ASYNC_REG = "TRUE" *) logic pixel_reset_ext_meta, pixel_reset_ext_sync;
  (* ASYNC_REG = "TRUE" *) logic serial_toggle_meta, serial_toggle_sync;
  (* ASYNC_REG = "TRUE" *) logic pixel_toggle_meta, pixel_toggle_sync;
  (* ASYNC_REG = "TRUE" *) logic vsync_meta, vsync_sync;
  logic serial_toggle_prev, pixel_toggle_prev, vsync_prev;
  logic serial_clock_seen, pixel_clock_seen, vsync_seen;

  embedded_video_ip_reset_sync u_serial_activity_reset_sync (
    .clk(serial_clk), .async_aresetn(aresetn),
    .sync_aresetn(serial_activity_aresetn)
  );
  embedded_video_ip_reset_sync u_pixel_activity_reset_sync (
    .clk(pixel_clk), .async_aresetn(aresetn),
    .sync_aresetn(pixel_activity_aresetn)
  );

  // 每个产生时钟域独立同步复位释放，避免把AXI域复位直接送到计数器。
  // 串行时钟每256个边沿翻转一次，跨到aclk后可可靠检测。
  always_ff @(posedge serial_clk or negedge serial_activity_aresetn) begin
    if (!serial_activity_aresetn) begin
      serial_activity_divider <= '0;
      serial_activity_toggle <= 1'b0;
    end else if (&serial_activity_divider) begin
      serial_activity_divider <= '0;
      serial_activity_toggle <= ~serial_activity_toggle;
    end else begin
      serial_activity_divider <= serial_activity_divider + 1'b1;
    end
  end

  // 像素时钟也使用分频心跳，避免把MMCM锁定误当作CLKOUT1一定在跳变。
  always_ff @(posedge pixel_clk or negedge pixel_activity_aresetn) begin
    if (!pixel_activity_aresetn) begin
      pixel_activity_divider <= '0;
      pixel_activity_toggle <= 1'b0;
    end else if (&pixel_activity_divider) begin
      pixel_activity_divider <= '0;
      pixel_activity_toggle <= ~pixel_activity_toggle;
    end else begin
      pixel_activity_divider <= pixel_activity_divider + 1'b1;
    end
  end

  // 像素复位、MMCM锁定、串行/像素时钟心跳和VSYNC跨到aclk域后再读出。
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      pixel_resetn_meta <= 1'b0;
      pixel_resetn_sync <= 1'b0;
      mmcm_lock_meta <= 1'b0;
      mmcm_lock_sync <= 1'b0;
      pixel_reset_ext_meta <= 1'b0;
      pixel_reset_ext_sync <= 1'b0;
      serial_toggle_meta <= 1'b0;
      serial_toggle_sync <= 1'b0;
      pixel_toggle_meta <= 1'b0;
      pixel_toggle_sync <= 1'b0;
      vsync_meta <= 1'b0;
      vsync_sync <= 1'b0;
      serial_toggle_prev <= 1'b0;
      pixel_toggle_prev <= 1'b0;
      vsync_prev <= 1'b0;
      serial_clock_seen <= 1'b0;
      pixel_clock_seen <= 1'b0;
      vsync_seen <= 1'b0;
    end else begin
      pixel_resetn_meta <= pixel_resetn_async;
      pixel_resetn_sync <= pixel_resetn_meta;
      mmcm_lock_meta <= mmcm_locked_async;
      mmcm_lock_sync <= mmcm_lock_meta;
      pixel_reset_ext_meta <= pixel_reset_ext_asserted_async;
      pixel_reset_ext_sync <= pixel_reset_ext_meta;
      serial_toggle_meta <= serial_activity_toggle;
      serial_toggle_sync <= serial_toggle_meta;
      pixel_toggle_meta <= pixel_activity_toggle;
      pixel_toggle_sync <= pixel_toggle_meta;
      vsync_meta <= video_vsync_async;
      vsync_sync <= vsync_meta;
      serial_toggle_prev <= serial_toggle_sync;
      pixel_toggle_prev <= pixel_toggle_sync;
      vsync_prev <= vsync_sync;
      if (serial_toggle_sync != serial_toggle_prev)
        serial_clock_seen <= 1'b1;
      if (pixel_toggle_sync != pixel_toggle_prev)
        pixel_clock_seen <= 1'b1;
      if (vsync_sync != vsync_prev)
        vsync_seen <= 1'b1;
    end
  end

  // STATUS[8]=像素复位释放；[9]=串行时钟活动；[10]=VSYNC变化；
  // [11]=MMCM锁定；[12]=像素时钟活动；[13]=复位外部输入仍有效。
  assign status = {pixel_reset_ext_sync, pixel_clock_seen, mmcm_lock_sync,
                   vsync_seen, serial_clock_seen, pixel_resetn_sync};
endmodule
