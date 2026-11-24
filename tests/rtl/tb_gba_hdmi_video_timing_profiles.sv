`timescale 1ns/1ps
module tb_gba_hdmi_video_timing_profiles;
  logic pixel_clk = 1'b0;
  logic resetn = 1'b0;
  logic timing_enable = 1'b1;
  logic [1:0] timing_profile = 2'd0;
  logic [11:0] held_h_count, held_v_count;

  logic ACTIVE_VIDEO;
  logic HBLANK;
  logic VBLANK;
  logic HSYNC;
  logic VSYNC;
  logic FIELD;

  logic ACTIVE_VIDEO_NOM;
  logic HBLANK_NOM;
  logic VBLANK_NOM;
  logic HSYNC_NOM;
  logic VSYNC_NOM;
  logic FIELD_NOM;

  integer checks = 0;
  integer h;
  integer v;
  logic expected_active;
  logic expected_hblank;
  logic expected_vblank;
  logic expected_hsync;
  logic expected_vsync;
  logic h_pulse;
  logic v_pulse;

  always #5 pixel_clk = ~pixel_clk;

  hdmi_video_timing_gen #(
    .VGA_H_TOTAL(10), .VGA_H_ACTIVE(6), .VGA_H_FRONT(1), .VGA_H_SYNC(2),
    .VGA_V_TOTAL(7), .VGA_V_ACTIVE(4), .VGA_V_FRONT(1), .VGA_V_SYNC(1),
    .HD720_H_TOTAL(12), .HD720_H_ACTIVE(8), .HD720_H_FRONT(2), .HD720_H_SYNC(1),
    .HD720_V_TOTAL(9), .HD720_V_ACTIVE(6), .HD720_V_FRONT(1), .HD720_V_SYNC(1),
    .HD1080_H_TOTAL(14), .HD1080_H_ACTIVE(10), .HD1080_H_FRONT(1), .HD1080_H_SYNC(2),
    .HD1080_V_TOTAL(10), .HD1080_V_ACTIVE(7), .HD1080_V_FRONT(1), .HD1080_V_SYNC(1)
  ) dut_small (
    .pixel_clk(pixel_clk), .resetn(resetn), .enable(timing_enable), .timing_profile(timing_profile),
    .ACTIVE_VIDEO(ACTIVE_VIDEO), .HBLANK(HBLANK), .VBLANK(VBLANK),
    .HSYNC(HSYNC), .VSYNC(VSYNC), .FIELD(FIELD)
  );

  // Keep a default-parameter instance in reset to validate the published VIC constants
  // without simulating millions of 74 MHz pixel cycles.
  hdmi_video_timing_gen dut_nominal (
    .pixel_clk(pixel_clk), .resetn(1'b0), .enable(1'b1), .timing_profile(2'd0),
    .ACTIVE_VIDEO(ACTIVE_VIDEO_NOM), .HBLANK(HBLANK_NOM), .VBLANK(VBLANK_NOM),
    .HSYNC(HSYNC_NOM), .VSYNC(VSYNC_NOM), .FIELD(FIELD_NOM)
  );

  task automatic check(input logic condition, input string message);
    begin
      checks = checks + 1;
      if (condition !== 1'b1)
        $fatal(1, "CHECK FAILED: %s at %0t", message, $time);
    end
  endtask

  task automatic tick(input integer count);
    integer i;
    begin
      for (i = 0; i < count; i = i + 1) begin
        @(posedge pixel_clk);
        #1;
      end
    end
  endtask

  task automatic select_profile(input logic [1:0] requested_profile);
    integer i;
    begin
      @(negedge pixel_clk);
      timing_profile = requested_profile;
      if (dut_small.profile_active != requested_profile) begin
        for (i = 0; i < 3; i = i + 1) begin
          @(posedge pixel_clk);
          #1;
        end
        check(dut_small.profile_active === requested_profile,
              "profile crosses into pixel domain after synchronizer latency");
        check(dut_small.h_count === 12'd0 && dut_small.v_count === 12'd0,
              "profile change restarts raster counters");
      end
    end
  endtask

  task automatic check_profile_frame(
    input logic [1:0] profile,
    input integer h_total,
    input integer h_active,
    input integer h_front,
    input integer h_sync_width,
    input integer v_total,
    input integer v_active,
    input integer v_front,
    input integer v_sync_width,
    input logic hsync_positive,
    input logic vsync_positive,
    input string profile_name
  );
    begin
      select_profile(profile);
      for (v = 0; v < v_total; v = v + 1) begin
        for (h = 0; h < h_total; h = h + 1) begin
          #1;
          expected_active = (h < h_active) && (v < v_active);
          expected_hblank = (h >= h_active);
          expected_vblank = (v >= v_active);
          h_pulse = (h >= (h_active + h_front)) &&
                    (h < (h_active + h_front + h_sync_width));
          v_pulse = (v >= (v_active + v_front)) &&
                    (v < (v_active + v_front + v_sync_width));
          expected_hsync = h_pulse ? hsync_positive : !hsync_positive;
          expected_vsync = v_pulse ? vsync_positive : !vsync_positive;

          if (ACTIVE_VIDEO !== expected_active)
            $fatal(1, "%s active-video mismatch at x=%0d y=%0d", profile_name, h, v);
          if (HBLANK !== expected_hblank)
            $fatal(1, "%s HBLANK mismatch at x=%0d y=%0d", profile_name, h, v);
          if (VBLANK !== expected_vblank)
            $fatal(1, "%s VBLANK mismatch at x=%0d y=%0d", profile_name, h, v);
          if (HSYNC !== expected_hsync)
            $fatal(1, "%s HSYNC mismatch at x=%0d y=%0d", profile_name, h, v);
          if (VSYNC !== expected_vsync)
            $fatal(1, "%s VSYNC mismatch at x=%0d y=%0d", profile_name, h, v);
          if (FIELD !== 1'b0)
            $fatal(1, "%s progressive FIELD is not low at x=%0d y=%0d", profile_name, h, v);
          checks = checks + 6;

          @(posedge pixel_clk);
          #1;
        end
      end
      check(dut_small.h_count === 12'd0 && dut_small.v_count === 12'd0,
            {profile_name, " frame wraps at exact H/V totals"});
    end
  endtask

  initial begin
    // Nominal CTA/VESA timing table and sync polarity checks.
    check(dut_nominal.VGA_H_TOTAL == 800 && dut_nominal.VGA_H_ACTIVE == 640 &&
          dut_nominal.VGA_H_FRONT == 16 && dut_nominal.VGA_H_SYNC == 96 &&
          dut_nominal.VGA_H_BACK == 48, "VIC1 VGA horizontal totals and porches");
    check(dut_nominal.VGA_V_TOTAL == 525 && dut_nominal.VGA_V_ACTIVE == 480 &&
          dut_nominal.VGA_V_FRONT == 10 && dut_nominal.VGA_V_SYNC == 2 &&
          dut_nominal.VGA_V_BACK == 33, "VIC1 VGA vertical totals and porches");
    check(dut_nominal.VGA_HSYNC_ACTIVE_HIGH == 1'b0 &&
          dut_nominal.VGA_VSYNC_ACTIVE_HIGH == 1'b0, "VIC1 negative sync polarity");

    check(dut_nominal.HD720_H_TOTAL == 1650 && dut_nominal.HD720_H_ACTIVE == 1280 &&
          dut_nominal.HD720_H_FRONT == 110 && dut_nominal.HD720_H_SYNC == 40 &&
          dut_nominal.HD720_H_BACK == 220, "VIC4 720p horizontal totals and porches");
    check(dut_nominal.HD720_V_TOTAL == 750 && dut_nominal.HD720_V_ACTIVE == 720 &&
          dut_nominal.HD720_V_FRONT == 5 && dut_nominal.HD720_V_SYNC == 5 &&
          dut_nominal.HD720_V_BACK == 20, "VIC4 720p vertical totals and porches");
    check(dut_nominal.HD720_HSYNC_ACTIVE_HIGH == 1'b1 &&
          dut_nominal.HD720_VSYNC_ACTIVE_HIGH == 1'b1, "VIC4 positive sync polarity");

    check(dut_nominal.HD1080_H_TOTAL == 2200 && dut_nominal.HD1080_H_ACTIVE == 1920 &&
          dut_nominal.HD1080_H_FRONT == 88 && dut_nominal.HD1080_H_SYNC == 44 &&
          dut_nominal.HD1080_H_BACK == 148, "VIC34 1080p30 horizontal totals and porches");
    check(dut_nominal.HD1080_V_TOTAL == 1125 && dut_nominal.HD1080_V_ACTIVE == 1080 &&
          dut_nominal.HD1080_V_FRONT == 4 && dut_nominal.HD1080_V_SYNC == 5 &&
          dut_nominal.HD1080_V_BACK == 36, "VIC34 1080p30 vertical totals and porches");
    check(dut_nominal.HD1080_HSYNC_ACTIVE_HIGH == 1'b1 &&
          dut_nominal.HD1080_VSYNC_ACTIVE_HIGH == 1'b1, "VIC34 positive sync polarity");

    repeat (3) @(posedge pixel_clk);
    #1;
    check(ACTIVE_VIDEO === 1'b0 && HBLANK === 1'b1 && VBLANK === 1'b1 &&
          HSYNC === 1'b1 && VSYNC === 1'b1 && FIELD === 1'b0,
          "reset drives blank safe timing outputs");
    @(negedge pixel_clk);
    resetn = 1'b1;
    select_profile(2'd3); // GBA profile 3 is 1080p60 and resets the first raster to (0,0).

    check_profile_frame(2'd0, 10, 6, 1, 2, 7, 4, 1, 1, 1'b0, 1'b0, "VGA480");

    // The upstream video-out timing enable must pause both raster counters.
    @(negedge pixel_clk);
    timing_enable = 1'b0;
    held_h_count = dut_small.h_count;
    held_v_count = dut_small.v_count;
    tick(5);
    check(dut_small.h_count === held_h_count && dut_small.v_count === held_v_count,
          "video-out timing enable pauses raster position");
    @(negedge pixel_clk);
    timing_enable = 1'b1;
    tick(1);

    // Switch mid-line. After profile synchronization, both raster counters restart at zero.
    tick(4);
    check(dut_small.h_count != 12'd0, "VGA raster advanced before profile switch");
    check_profile_frame(2'd1, 12, 8, 2, 1, 9, 6, 1, 1, 1'b1, 1'b1, "720p60");
    check_profile_frame(2'd2, 14, 10, 1, 2, 10, 7, 1, 1, 1'b1, 1'b1, "1080p30 VIC34");
    check_profile_frame(2'd3, 14, 10, 1, 2, 10, 7, 1, 1, 1'b1, 1'b1, "1080p60 VIC16");

    // Return from the 1080p60 profile to VGA and verify the raster restarts cleanly.
    check_profile_frame(2'd0, 10, 6, 1, 2, 7, 4, 1, 1, 1'b0, 1'b0,
                        "VGA recovery after 1080p60");

    $display("TEST_PASS: tb_gba_hdmi_video_timing_profiles checks=%0d", checks);
    $display("Coverage: VIC1/VIC4/VIC34/VIC16 totals, porches, active areas, sync widths/polarities,");
    $display("          exact frame wrap, reset, profile-domain synchronization, mid-frame reset,");
    $display("          VGA-to-HD/HD-to-HD transitions and VGA recovery after 1080p60.");
    $finish;
  end
endmodule
