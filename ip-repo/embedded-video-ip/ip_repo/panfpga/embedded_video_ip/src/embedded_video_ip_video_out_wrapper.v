// Project-owned video composition; retain the packaged AXI4S-to-video IP.
module embedded_video_ip_video_out_wrapper (
 input wire aclk,aresetn,hdmi_ref_clk,
 input wire [1:0] clock_mode, input wire pixel_reset_hold,
 input wire [1:0] timing_profile,
 input wire [23:0] s_axis_video_tdata, input wire s_axis_video_tvalid,
 input wire s_axis_video_tuser,s_axis_video_tlast, output wire s_axis_video_tready,
 output wire [23:0] video_rgb, output wire video_de,video_hsync,video_vsync,video_vsync_raw,
 output wire pixel_clk,serial_monitor_clk,pixel_aresetn,
 (* CLOCK_BUFFER_TYPE="NONE" *) output wire serial_clk,
 (* CLOCK_BUFFER_TYPE="NONE" *) output wire serdes_pixel_clk,
 output wire hdmi_mmcm_locked,pixel_reset_ext_asserted,output wire [1:0] locked_profiles
);
 wire active,field_id,hblank,hsync,vblank,vsync;
 reg [25:0] stream0, stream1;
 reg [1:0] stream_count;
 wire sink_ready;
 wire stream_push = s_axis_video_tvalid && s_axis_video_tready;
 wire stream_pop = (stream_count != 0) && sink_ready;
 assign s_axis_video_tready = (stream_count != 2) && !pixel_reset_hold;
 always @(posedge aclk) begin
  if (!aresetn || pixel_reset_hold) begin
   stream_count <= 0;
   stream0 <= 0;
   stream1 <= 0;
  end else begin
   case ({stream_push,stream_pop})
    2'b10: stream_count <= stream_count + 1'b1;
    2'b01: stream_count <= stream_count - 1'b1;
    default: begin end
   endcase
   if (stream_pop) stream0 <= stream1;
   if (stream_push) begin
    if (stream_count == 0 || (stream_count == 1 && stream_pop))
     stream0 <= {s_axis_video_tuser,s_axis_video_tlast,s_axis_video_tdata};
    else stream1 <= {s_axis_video_tuser,s_axis_video_tlast,s_axis_video_tdata};
   end
  end
 end
 hdmi_four_mode_clocks clocks(.ctrl_clk(aclk),.resetn(aresetn),.ref_clk(hdmi_ref_clk),
  .mode(clock_mode),.pixel_clk(pixel_clk),.serial_clk(serial_clk),
  .serdes_pixel_clk(serdes_pixel_clk),.serial_monitor_clk(serial_monitor_clk),.locked(hdmi_mmcm_locked));
 assign locked_profiles={2{hdmi_mmcm_locked}};
 assign pixel_reset_ext_asserted=!aresetn || pixel_reset_hold || !hdmi_mmcm_locked;
 embedded_video_ip_reset_sync pixel_reset(.clk(pixel_clk),
  .async_aresetn(!pixel_reset_ext_asserted),.sync_aresetn(pixel_aresetn));
 hdmi_video_timing_gen timing_gen(.pixel_clk(pixel_clk),.resetn(pixel_aresetn),
  .enable(1'b1),.timing_profile(timing_profile),.ACTIVE_VIDEO(active),
  .FIELD(field_id),.HBLANK(hblank),.HSYNC(hsync),.VBLANK(vblank),.VSYNC(vsync));
 assign video_vsync_raw=vsync;
 embedded_video_ip_video_out_video_out_0 video_out (
  .aclk(aclk),.aclken(!pixel_reset_hold),.aresetn(aresetn),.fid(1'b0),
  .s_axis_video_tdata(stream0[23:0]),.s_axis_video_tlast(stream0[24]),
  .s_axis_video_tready(sink_ready),.s_axis_video_tuser(stream0[25]),
  .s_axis_video_tvalid(stream_count != 0),.vid_active_video(video_de),
  .vid_data(video_rgb),.vid_hsync(video_hsync),.vid_vsync(video_vsync),
  .vid_io_out_ce(1'b1),.vid_io_out_clk(pixel_clk),.vid_io_out_reset(!pixel_aresetn),
  .vtg_active_video(active),.vtg_field_id(field_id),.vtg_hblank(hblank),
  .vtg_hsync(hsync),.vtg_vblank(vblank),.vtg_vsync(vsync));
endmodule
