`timescale 1ns/1ps
module tb_gba_hdmi_pcm_profile_rates;
  // Long enough to observe at least four ACR intervals at 148.5 MHz / 2200.
  localparam integer SAMPLE_PHASE_TEST_CYCLES = 750_000;
  localparam integer FIFO_ADDR_WIDTH = 3;
  logic pixel_clk=0, audio_pcm_clk=0, resetn=0;
  logic line_prepare=0, vsync=0, linegen_enable=0;
  logic hdmi_mode_active=1, hdmi_audio_enable=0, packet_ready=1;
  logic [31:0] pixel_clock_hz=0, h_total=0;
  logic [7:0] video_vic=8'd1;
  logic [47:0] audio_pcm_tdata=0;
  logic audio_pcm_tvalid=0;
  logic ready48,ready96,ready192;
  logic valid48,valid96,valid192;
  logic cancel48,cancel96,cancel192,link_cancel48,link_cancel96,link_cancel192;
  logic under48,under96,under192,over48,over96,over192;
  logic [23:0] header48,header96,header192;
  logic [55:0] sub48_0,sub48_1,sub48_2,sub48_3;
  logic [55:0] sub96_0,sub96_1,sub96_2,sub96_3;
  logic [55:0] sub192_0,sub192_1,sub192_2,sub192_3;
  integer line_phase=0, line_number=0, line_count=0, current_mode=-1;
  integer acr_count48=0,acr_count96=0,acr_count192=0;
  integer info_count48=0,info_count96=0,info_count192=0;
  integer avi_count48=0,avi_count96=0,avi_count192=0;
  integer last_acr_line48=-1,last_acr_line96=-1,last_acr_line192=-1;
  integer interval_count48=0,interval_count96=0,interval_count192=0;
  longint unsigned interval_lines48=0,interval_lines96=0,interval_lines192=0;
  integer sample_due48=0,sample_due96=0,sample_due192=0;
  logic [31:0] phase_start48=0,phase_start96=0,phase_start192=0;
  integer cadence_min=0,cadence_max=0;
  logic sample_observe=0;
  integer cycles, error_abs;
  longint unsigned expected48,expected96,expected192,actual_term,expected_term;

  covergroup profile_rate_matrix_cg with function sample(input integer mode_id,
                                                         input integer rate_khz);
    mode_cp: coverpoint mode_id {
      bins vga480={0}; bins hd720={1}; bins hd1080p30={2}; bins hd1080p60={3};
    }
    rate_cp: coverpoint rate_khz {
      bins fs48={48}; bins fs96={96}; bins fs192={192};
    }
    mode_x_rate: cross mode_cp,rate_cp;
  endgroup
  profile_rate_matrix_cg profile_rate_cov = new();

  always #5 pixel_clk=~pixel_clk;
  always #3 audio_pcm_clk=~audio_pcm_clk;

  hdmi_pcm_packet_source #(.ENABLE_HDMI_AUDIO(1'b1), .USE_VIDEO_PROFILE_CLOCKS(1'b1),
    .AUDIO_SAMPLE_RATE_HZ(48_000),
    .FIFO_ADDR_WIDTH(FIFO_ADDR_WIDTH)) profile48 (
    .pixel_clk(pixel_clk), .audio_pcm_clk(audio_pcm_clk), .pixel_clock_hz(pixel_clock_hz),
    .h_total(h_total), .video_vic(video_vic),
    .pixel_aresetn(resetn), .audio_pcm_aresetn(resetn), .hdmi_mode_active(hdmi_mode_active),
    .vsync(vsync), .line_prepare(line_prepare), .packet_active(1'b0),
    .audio_pcm_tdata(audio_pcm_tdata), .audio_pcm_tvalid(audio_pcm_tvalid), .audio_pcm_tready(ready48),
    .hdmi_audio_enable(hdmi_audio_enable), .audio_mute(1'b0), .audio_gain_q15(17'd32768),
    .packet_ready(packet_ready), .packet_valid(valid48), .packet_cancel(cancel48), .packet_cancel_link(link_cancel48),
    .packet_header(header48), .packet_sub0(sub48_0), .packet_sub1(sub48_1), .packet_sub2(sub48_2), .packet_sub3(sub48_3),
    .audio_underflow_event(under48), .audio_overflow_event(over48)
  );
  hdmi_pcm_packet_source #(.ENABLE_HDMI_AUDIO(1'b1), .USE_VIDEO_PROFILE_CLOCKS(1'b1),
    .AUDIO_SAMPLE_RATE_HZ(96_000),
    .FIFO_ADDR_WIDTH(FIFO_ADDR_WIDTH)) profile96 (
    .pixel_clk(pixel_clk), .audio_pcm_clk(audio_pcm_clk), .pixel_clock_hz(pixel_clock_hz),
    .h_total(h_total), .video_vic(video_vic),
    .pixel_aresetn(resetn), .audio_pcm_aresetn(resetn), .hdmi_mode_active(hdmi_mode_active),
    .vsync(vsync), .line_prepare(line_prepare), .packet_active(1'b0),
    .audio_pcm_tdata(audio_pcm_tdata), .audio_pcm_tvalid(audio_pcm_tvalid), .audio_pcm_tready(ready96),
    .hdmi_audio_enable(hdmi_audio_enable), .audio_mute(1'b0), .audio_gain_q15(17'd32768),
    .packet_ready(packet_ready), .packet_valid(valid96), .packet_cancel(cancel96), .packet_cancel_link(link_cancel96),
    .packet_header(header96), .packet_sub0(sub96_0), .packet_sub1(sub96_1), .packet_sub2(sub96_2), .packet_sub3(sub96_3),
    .audio_underflow_event(under96), .audio_overflow_event(over96)
  );
  hdmi_pcm_packet_source #(.ENABLE_HDMI_AUDIO(1'b1), .USE_VIDEO_PROFILE_CLOCKS(1'b1),
    .AUDIO_SAMPLE_RATE_HZ(192_000),
    .FIFO_ADDR_WIDTH(FIFO_ADDR_WIDTH)) profile192 (
    .pixel_clk(pixel_clk), .audio_pcm_clk(audio_pcm_clk), .pixel_clock_hz(pixel_clock_hz),
    .h_total(h_total), .video_vic(video_vic),
    .pixel_aresetn(resetn), .audio_pcm_aresetn(resetn), .hdmi_mode_active(hdmi_mode_active),
    .vsync(vsync), .line_prepare(line_prepare), .packet_active(1'b0),
    .audio_pcm_tdata(audio_pcm_tdata), .audio_pcm_tvalid(audio_pcm_tvalid), .audio_pcm_tready(ready192),
    .hdmi_audio_enable(hdmi_audio_enable), .audio_mute(1'b0), .audio_gain_q15(17'd32768),
    .packet_ready(packet_ready), .packet_valid(valid192), .packet_cancel(cancel192), .packet_cancel_link(link_cancel192),
    .packet_header(header192), .packet_sub0(sub192_0), .packet_sub1(sub192_1), .packet_sub2(sub192_2), .packet_sub3(sub192_3),
    .audio_underflow_event(under192), .audio_overflow_event(over192)
  );

  always @(negedge pixel_clk) begin
    if (!resetn || !linegen_enable) begin
      line_prepare=1'b0;
      vsync=1'b0;
      line_phase=0;
    end else if (line_phase==0) begin
      line_prepare=1'b1;
      vsync=((line_number % 5)==0);
      line_number=line_number+1;
      line_count=line_count+1;
      line_phase=1;
    end else begin
      line_prepare=1'b0;
      vsync=1'b0;
      if (line_phase >= h_total-1) line_phase=0;
      else line_phase=line_phase+1;
    end
  end

  function automatic longint unsigned expected_sample_due(input integer cycles_in,
      input integer sample_rate, input logic [31:0] pclk, input logic [31:0] phase_start);
    expected_sample_due = (64'(cycles_in) * 64'(sample_rate) + 64'(phase_start)) / 64'(pclk);
  endfunction

  function automatic logic [19:0] expected_cts(input logic [31:0] pclk,
      input integer sample_rate, input integer n_value);
    logic [63:0] denominator, numerator;
    begin
      denominator=64'd128*64'(sample_rate);
      numerator=64'(pclk)*64'(n_value)+(denominator/2);
      expected_cts=20'(numerator/denominator);
    end
  endfunction

  task automatic fail(input string message);
    $fatal(1,"%s",message);
  endtask

  task automatic check_acr_payload(input logic [55:0] payload,
      input logic [31:0] pclk, input integer fs, input integer n_value, input string label);
    logic [19:0] cts;
    begin
      cts=expected_cts(pclk,fs,n_value);
      if (payload[7:0]!==8'h00 || payload[15:8]!=={4'b0000,cts[19:16]} ||
          payload[23:16]!==cts[15:8] || payload[31:24]!==cts[7:0] ||
          payload[39:32]!=={4'b0000,4'(n_value[19:16])} ||
          payload[47:40]!==n_value[15:8] || payload[55:48]!==n_value[7:0])
        $fatal(1,"%s N/CTS payload mismatch: got=%h expected CTS=%h N=%h",
               label,payload,cts,20'(n_value));
    end
  endtask

  task automatic record_acr(input integer profile, input string label);
    integer delta;
    begin
      case(profile)
        0: begin
          check_acr_payload(sub48_0,pixel_clock_hz,48_000,6_144,{label," 48k"});
          if (sub48_1!==sub48_0 || sub48_2!==sub48_0 || sub48_3!==sub48_0)
            $fatal(1,"48 kHz ACR subpackets differ");
          if (last_acr_line48>=0) begin
            delta=line_count-last_acr_line48;
            if (delta<cadence_min || delta>cadence_max)
              $fatal(1,"%s 48 kHz ACR interval %0d outside %0d..%0d",label,delta,cadence_min,cadence_max);
            interval_count48=interval_count48+1; interval_lines48=interval_lines48+delta;
          end
          last_acr_line48=line_count; acr_count48=acr_count48+1;
        end
        1: begin
          check_acr_payload(sub96_0,pixel_clock_hz,96_000,12_288,{label," 96k"});
          if (sub96_1!==sub96_0 || sub96_2!==sub96_0 || sub96_3!==sub96_0)
            $fatal(1,"96 kHz ACR subpackets differ");
          if (last_acr_line96>=0) begin
            delta=line_count-last_acr_line96;
            if (delta<cadence_min || delta>cadence_max)
              $fatal(1,"%s 96 kHz ACR interval %0d outside %0d..%0d",label,delta,cadence_min,cadence_max);
            interval_count96=interval_count96+1; interval_lines96=interval_lines96+delta;
          end
          last_acr_line96=line_count; acr_count96=acr_count96+1;
        end
        default: begin
          check_acr_payload(sub192_0,pixel_clock_hz,192_000,24_576,{label," 192k"});
          if (sub192_1!==sub192_0 || sub192_2!==sub192_0 || sub192_3!==sub192_0)
            $fatal(1,"192 kHz ACR subpackets differ");
          if (last_acr_line192>=0) begin
            delta=line_count-last_acr_line192;
            if (delta<cadence_min || delta>cadence_max)
              $fatal(1,"%s 192 kHz ACR interval %0d outside %0d..%0d",label,delta,cadence_min,cadence_max);
            interval_count192=interval_count192+1; interval_lines192=interval_lines192+delta;
          end
          last_acr_line192=line_count; acr_count192=acr_count192+1;
        end
      endcase
    end
  endtask

  task automatic check_infoframe(input integer profile, input string label);
    begin
      case(profile)
        0: begin
          if (header48[15:8]!==8'h01 || header48[23:16]!==8'h0A ||
              sub48_0[23:16]!==8'h0F || sub48_0[15:8]!==8'h01 || sub48_0[7:0]!==8'h61)
            $fatal(1,"%s 48 kHz Audio InfoFrame mismatch",label);
          info_count48=info_count48+1;
        end
        1: begin
          if (header96[15:8]!==8'h01 || header96[23:16]!==8'h0A ||
              sub96_0[23:16]!==8'h17 || sub96_0[15:8]!==8'h01 || sub96_0[7:0]!==8'h59)
            $fatal(1,"%s 96 kHz Audio InfoFrame mismatch",label);
          info_count96=info_count96+1;
        end
        default: begin
          if (header192[15:8]!==8'h01 || header192[23:16]!==8'h0A ||
              sub192_0[23:16]!==8'h1F || sub192_0[15:8]!==8'h01 || sub192_0[7:0]!==8'h51)
            $fatal(1,"%s 192 kHz Audio InfoFrame mismatch",label);
          info_count192=info_count192+1;
        end
      endcase
    end
  endtask

  always @(posedge pixel_clk) begin
    if (resetn && linegen_enable) begin
      if (sample_observe) begin
        if (profile48.g_hdmi_audio_enabled.sample_due) sample_due48=sample_due48+1;
        if (profile96.g_hdmi_audio_enabled.sample_due) sample_due96=sample_due96+1;
        if (profile192.g_hdmi_audio_enabled.sample_due) sample_due192=sample_due192+1;
      end
      if (valid48 && header48[7:0]==8'h01) record_acr(0,"active timing");
      if (valid96 && header96[7:0]==8'h01) record_acr(1,"active timing");
      if (valid192 && header192[7:0]==8'h01) record_acr(2,"active timing");
      if (valid48 && header48[7:0]==8'h84) check_infoframe(0,"active timing");
      if (valid96 && header96[7:0]==8'h84) check_infoframe(1,"active timing");
      if (valid192 && header192[7:0]==8'h84) check_infoframe(2,"active timing");
      if (valid48 && header48[7:0]==8'h82) begin
        if (sub48_0[39:32]!==video_vic || sub48_0[23:16]!==((video_vic==8'd1)?8'h18:8'h28))
          $fatal(1,"AVI VIC/aspect mismatch for 48 kHz source: vic=%0d PB2=%02h PB4=%02h",video_vic,sub48_0[23:16],sub48_0[39:32]);
        avi_count48=avi_count48+1;
      end
      if (valid96 && header96[7:0]==8'h82) begin
        if (sub96_0[39:32]!==video_vic || sub96_0[23:16]!==((video_vic==8'd1)?8'h18:8'h28))
          $fatal(1,"AVI VIC/aspect mismatch for 96 kHz source");
        avi_count96=avi_count96+1;
      end
      if (valid192 && header192[7:0]==8'h82) begin
        if (sub192_0[39:32]!==video_vic || sub192_0[23:16]!==((video_vic==8'd1)?8'h18:8'h28))
          $fatal(1,"AVI VIC/aspect mismatch for 192 kHz source");
        avi_count192=avi_count192+1;
      end
    end
  end

  task automatic run_mode(input integer mode_id, input logic [31:0] pclk,
      input logic [31:0] htotal, input logic [7:0] vic,
      input integer min_interval, input integer max_interval, input string label);
    longint unsigned expected_term_local, actual_term_local, tolerance_local;
    begin
      // Stop audio/packet collection while switching the two timing values.
      @(negedge pixel_clk); linegen_enable=1'b0; sample_observe=1'b0; hdmi_audio_enable=1'b0;
      repeat(8) @(posedge pixel_clk);
      @(negedge pixel_clk); pixel_clock_hz=pclk; h_total=htotal; video_vic=vic;
      cadence_min=min_interval; cadence_max=max_interval;
      repeat(8) @(posedge pixel_clk);
      if (profile48.g_hdmi_audio_enabled.profile_params_changed ||
          profile96.g_hdmi_audio_enabled.profile_params_changed ||
          profile192.g_hdmi_audio_enabled.profile_params_changed)
        fail({label," profile inputs did not settle in pixel domain"});

      @(negedge pixel_clk); hdmi_audio_enable=1'b1;
      cycles=0;
      while ((!profile48.g_hdmi_audio_enabled.pixel_audio_enable ||
              profile48.g_hdmi_audio_enabled.rd_flush_pending ||
              !profile96.g_hdmi_audio_enabled.pixel_audio_enable ||
              profile96.g_hdmi_audio_enabled.rd_flush_pending ||
              !profile192.g_hdmi_audio_enabled.pixel_audio_enable ||
              profile192.g_hdmi_audio_enabled.rd_flush_pending) && cycles<30) begin
        @(posedge pixel_clk); cycles=cycles+1;
      end
      if (cycles>=30) fail({label," audio enable/flush did not settle"});
      repeat(4) @(posedge pixel_clk);

      line_count=0; line_number=0; line_phase=0;
      last_acr_line48=-1; last_acr_line96=-1; last_acr_line192=-1;
      acr_count48=0; acr_count96=0; acr_count192=0;
      interval_count48=0; interval_count96=0; interval_count192=0;
      interval_lines48=0; interval_lines96=0; interval_lines192=0;
      info_count48=0; info_count96=0; info_count192=0;
      avi_count48=0; avi_count96=0; avi_count192=0;
      sample_due48=0; sample_due96=0; sample_due192=0;

      // The phase start term makes the exact count independent of the enable edge.
      @(negedge pixel_clk);
      phase_start48=profile48.g_hdmi_audio_enabled.sample_phase;
      phase_start96=profile96.g_hdmi_audio_enabled.sample_phase;
      phase_start192=profile192.g_hdmi_audio_enabled.sample_phase;
      sample_observe=1'b1; linegen_enable=1'b1;
      repeat(SAMPLE_PHASE_TEST_CYCLES) @(posedge pixel_clk);
      @(negedge pixel_clk); sample_observe=1'b0; linegen_enable=1'b0;

      expected48=expected_sample_due(SAMPLE_PHASE_TEST_CYCLES,48_000,pclk,phase_start48);
      expected96=expected_sample_due(SAMPLE_PHASE_TEST_CYCLES,96_000,pclk,phase_start96);
      expected192=expected_sample_due(SAMPLE_PHASE_TEST_CYCLES,192_000,pclk,phase_start192);
      if (sample_due48!=expected48 || sample_due96!=expected96 || sample_due192!=expected192)
        $fatal(1,"%s sample cadence mismatch got=%0d/%0d/%0d expected=%0d/%0d/%0d phase=%0d/%0d/%0d",
               label,sample_due48,sample_due96,sample_due192,expected48,expected96,expected192,
               phase_start48,phase_start96,phase_start192);
      if (acr_count48<5 || acr_count96<5 || acr_count192<5 ||
          interval_count48<4 || interval_count96<4 || interval_count192<4)
        $fatal(1,"%s did not cover four ACR line intervals",label);
      if (info_count48==0 || info_count96==0 || info_count192==0)
        $fatal(1,"%s missing Audio InfoFrame for one of the sample rates",label);
      if (avi_count48==0 || avi_count96==0 || avi_count192==0)
        $fatal(1,"%s missing AVI VIC profile for one of the sample rates",label);

      // The accumulated line intervals must agree with 1000 ACR packets/sec,
      // within one horizontal line of fractional rounding.
      expected_term_local=64'(interval_count48)*64'(pclk);
      actual_term_local=interval_lines48*64'd1000*64'(htotal);
      tolerance_local=64'd1000*64'(htotal);
      error_abs=(actual_term_local>expected_term_local) ?
        integer'(actual_term_local-expected_term_local) : integer'(expected_term_local-actual_term_local);
      if (error_abs>tolerance_local) $fatal(1,"%s 48 kHz ACR long-term line cadence mismatch",label);
      expected_term_local=64'(interval_count96)*64'(pclk);
      actual_term_local=interval_lines96*64'd1000*64'(htotal);
      error_abs=(actual_term_local>expected_term_local) ?
        integer'(actual_term_local-expected_term_local) : integer'(expected_term_local-actual_term_local);
      if (error_abs>tolerance_local) $fatal(1,"%s 96 kHz ACR long-term line cadence mismatch",label);
      expected_term_local=64'(interval_count192)*64'(pclk);
      actual_term_local=interval_lines192*64'd1000*64'(htotal);
      error_abs=(actual_term_local>expected_term_local) ?
        integer'(actual_term_local-expected_term_local) : integer'(expected_term_local-actual_term_local);
      if (error_abs>tolerance_local) $fatal(1,"%s 192 kHz ACR long-term line cadence mismatch",label);
      profile_rate_cov.sample(mode_id,48);
      profile_rate_cov.sample(mode_id,96);
      profile_rate_cov.sample(mode_id,192);
      $display("PROFILE_PASS: %s pclk=%0d htotal=%0d sample_due=%0d/%0d/%0d ACR_intervals=%0d/%0d/%0d",
               label,pclk,htotal,sample_due48,sample_due96,sample_due192,
               interval_count48,interval_count96,interval_count192);
    end
  endtask

  initial begin
    repeat(6) @(posedge pixel_clk);
    @(negedge pixel_clk); resetn=1; hdmi_audio_enable=1;
    repeat(12) @(posedge pixel_clk);
    run_mode(0,32'd25_178_571,32'd800,8'd1,31,32,"VGA 480p VIC1");
    run_mode(1,32'd74_250_000,32'd1650,8'd4,45,45,"720p60 VIC4");
    run_mode(2,32'd74_250_000,32'd2200,8'd34,33,34,"1080p30 VIC34");
    run_mode(3,32'd148_500_000,32'd2200,8'd16,67,68,"1080p60 VIC16");

    @(posedge pixel_clk); hdmi_mode_active=1'b0;
    repeat(8) @(posedge pixel_clk);
    if (!link_cancel48 || !link_cancel96 || !link_cancel192)
      fail("DVI switch did not request cancellation in all sample-rate profiles");
    if (valid48 || valid96 || valid192)
      fail("DVI mode offered HDMI packets in a sample-rate profile");
    if (!ready48 || !ready96 || !ready192)
      fail("PCM TREADY did not release when DVI disabled audio");
    if (profile_rate_cov.get_inst_coverage()<100.0)
      fail($sformatf("profile/sample-rate cross coverage incomplete: %0.2f%%",
                     profile_rate_cov.get_inst_coverage()));

    $display("FUNCTIONAL_COVERAGE_PASS: 4 video profiles x 3 PCM rates=12/12 bins");
    $display("TEST_PASS: tb_gba_hdmi_pcm_profile_rates, VGA/720p60/1080p30/1080p60 x 48/96/192 kHz");
    $finish;
  end
endmodule
