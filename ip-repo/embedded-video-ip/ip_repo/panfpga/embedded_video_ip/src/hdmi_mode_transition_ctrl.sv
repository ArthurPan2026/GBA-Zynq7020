`timescale 1ns/1ps
// Standalone fail-safe mode transition controller for a VGA and a shared HD clock profile.
// Timing/clock IP programming is performed by the surrounding top-level controller.
module hdmi_mode_transition_ctrl #(
  parameter int unsigned LOCK_STABLE_CYCLES = 8,
  parameter int unsigned LOCK_TIMEOUT_CYCLES = 2_000_000,
  parameter int unsigned VSYNC_TIMEOUT_CYCLES = 4_000_000,
  parameter int unsigned CONFIG_TIMEOUT_CYCLES = 2_000_000
) (
  input  logic       clk,
  input  logic       aresetn,
  input  logic       mode_commit,
  input  logic [1:0] mode_req,
  input  logic       mode_error_clear,
  input  logic       mode_config_ready,
  input  logic       pixel_vsync_async,
  input  logic [1:0] clock_locked,

  output logic       clock_profile_sel, // 0 = VGA clock, 1 = shared HD clock
  output logic [1:0] timing_profile,    // 0 = VIC1, 1 = VIC4, 2 = VIC34
  output logic       mode_busy,
  output logic [1:0] mode_active,       // Updated only after the new profile emits VSYNC
  output logic       mode_error,        // Sticky until mode_error_clear
  output logic       pixel_reset_hold,
  output logic       force_dvi_safe,
  output logic       audio_allow
);
  localparam int unsigned LOCK_STABLE_WIDTH =
      (LOCK_STABLE_CYCLES > 1) ? $clog2(LOCK_STABLE_CYCLES + 1) : 1;
  localparam int unsigned LOCK_TIMER_WIDTH =
      (LOCK_TIMEOUT_CYCLES > 1) ? $clog2(LOCK_TIMEOUT_CYCLES + 1) : 1;
  localparam int unsigned VSYNC_TIMER_WIDTH =
      (VSYNC_TIMEOUT_CYCLES > 1) ? $clog2(VSYNC_TIMEOUT_CYCLES + 1) : 1;
  localparam int unsigned CONFIG_TIMER_WIDTH =
      (CONFIG_TIMEOUT_CYCLES > 1) ? $clog2(CONFIG_TIMEOUT_CYCLES + 1) : 1;

  typedef enum logic [2:0] {
    ST_BOOT_LOCK,
    ST_BOOT_VSYNC,
    ST_IDLE,
    ST_WAIT_FRAME,
    ST_WAIT_LOCK,
    ST_WAIT_CONFIG,
    ST_WAIT_VSYNC,
    ST_FAILED
  } state_t;

  state_t state;
  logic [1:0] pending_mode;

  (* ASYNC_REG = "TRUE" *) logic pixel_vsync_meta;
  (* ASYNC_REG = "TRUE" *) logic pixel_vsync_sync;
  logic pixel_vsync_prev;
  logic pixel_vsync_rise;

  (* ASYNC_REG = "TRUE" *) logic [1:0] clock_locked_meta;
  (* ASYNC_REG = "TRUE" *) logic [1:0] clock_locked_sync;

  logic [LOCK_STABLE_WIDTH-1:0] lock_stable_count;
  logic [LOCK_TIMER_WIDTH-1:0] lock_timer;
  logic [VSYNC_TIMER_WIDTH-1:0] vsync_timer;
  logic [CONFIG_TIMER_WIDTH-1:0] config_timer;

  function automatic logic mode_is_valid(input logic [1:0] mode_value);
    mode_is_valid = (mode_value != 2'd3);
  endfunction

  function automatic logic mode_clock_profile(input logic [1:0] mode_value);
    mode_clock_profile = (mode_value == 2'd0) ? 1'b0 : 1'b1;
  endfunction

  assign pixel_vsync_rise = pixel_vsync_sync && !pixel_vsync_prev;
  assign mode_busy = (state != ST_IDLE) && (state != ST_FAILED);

  always_comb begin
    pixel_reset_hold = 1'b1;
    force_dvi_safe = 1'b1;
    audio_allow = 1'b0;
    case (state)
      ST_BOOT_LOCK, ST_WAIT_LOCK, ST_WAIT_CONFIG, ST_FAILED: begin
        pixel_reset_hold = 1'b1;
      end
      ST_BOOT_VSYNC, ST_WAIT_VSYNC: begin
        pixel_reset_hold = 1'b0;
        force_dvi_safe = 1'b1;
      end
      ST_IDLE: begin
        pixel_reset_hold = 1'b0;
        force_dvi_safe = 1'b0;
        audio_allow = 1'b1;
      end
      ST_WAIT_FRAME: begin
        // Keep the current frame clocked while suppressing new audio packets.
        pixel_reset_hold = 1'b0;
        force_dvi_safe = 1'b0;
      end
      default: begin
        pixel_reset_hold = 1'b1;
        force_dvi_safe = 1'b1;
        audio_allow = 1'b0;
      end
    endcase
  end

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      pixel_vsync_meta <= 1'b0;
      pixel_vsync_sync <= 1'b0;
      pixel_vsync_prev <= 1'b0;
      clock_locked_meta <= 2'b00;
      clock_locked_sync <= 2'b00;
    end else begin
      pixel_vsync_meta <= pixel_vsync_async;
      pixel_vsync_sync <= pixel_vsync_meta;
      pixel_vsync_prev <= pixel_vsync_sync;
      clock_locked_meta <= clock_locked;
      clock_locked_sync <= clock_locked_meta;
    end
  end

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      state <= ST_BOOT_LOCK;
      pending_mode <= 2'd0;
      clock_profile_sel <= 1'b0;
      timing_profile <= 2'd0;
      mode_active <= 2'd0;
      mode_error <= 1'b0;
      lock_stable_count <= '0;
      lock_timer <= '0;
      vsync_timer <= '0;
      config_timer <= '0;
    end else begin
      if (mode_error_clear)
        mode_error <= 1'b0;

      case (state)
        ST_BOOT_LOCK: begin
          if (clock_locked_sync[0]) begin
            if (lock_stable_count >= LOCK_STABLE_WIDTH'(LOCK_STABLE_CYCLES - 1)) begin
              lock_stable_count <= '0;
              lock_timer <= '0;
              vsync_timer <= '0;
              state <= ST_BOOT_VSYNC;
            end else begin
              lock_stable_count <= lock_stable_count + 1'b1;
              if (lock_timer >= LOCK_TIMER_WIDTH'(LOCK_TIMEOUT_CYCLES - 1)) begin
                lock_stable_count <= '0;
                state <= ST_FAILED;
                mode_error <= 1'b1;
              end else begin
                lock_timer <= lock_timer + 1'b1;
              end
            end
          end else begin
            lock_stable_count <= '0;
            if (lock_timer >= LOCK_TIMER_WIDTH'(LOCK_TIMEOUT_CYCLES - 1)) begin
              state <= ST_FAILED;
              mode_error <= 1'b1;
            end else begin
              lock_timer <= lock_timer + 1'b1;
            end
          end
          if (mode_commit)
            mode_error <= 1'b1;
        end

        ST_BOOT_VSYNC: begin
          if (!clock_locked_sync[0]) begin
            state <= ST_FAILED;
            mode_error <= 1'b1;
            vsync_timer <= '0;
          end else if (pixel_vsync_rise) begin
            state <= ST_IDLE;
            vsync_timer <= '0;
          end
          // The PS application starts VDMA after programmable logic has booted.
          // Keep the pixel domain released and the link DVI-safe until its first frame.
          if (mode_commit)
            mode_error <= 1'b1;
        end

        ST_IDLE: begin
          lock_stable_count <= '0;
          lock_timer <= '0;
          vsync_timer <= '0;
          if (!clock_locked_sync[clock_profile_sel]) begin
            state <= ST_FAILED;
            mode_error <= 1'b1;
          end else if (mode_commit) begin
            if (!mode_is_valid(mode_req)) begin
              mode_error <= 1'b1;
            end else if ((mode_req != mode_active) ||
                         (timing_profile != mode_req) ||
                         (clock_profile_sel != mode_clock_profile(mode_req))) begin
              pending_mode <= mode_req;
              vsync_timer <= '0;
              state <= ST_WAIT_FRAME;
            end
          end
        end

        ST_WAIT_FRAME: begin
          if (mode_commit)
            mode_error <= 1'b1; // Reject new requests while the current transition is in flight.
          if (!clock_locked_sync[clock_profile_sel]) begin
            state <= ST_FAILED;
            mode_error <= 1'b1;
            vsync_timer <= '0;
          end else if (pixel_vsync_rise) begin
            // The current frame has ended: mask HDMI packets and hold pixel-domain logic.
            clock_profile_sel <= mode_clock_profile(pending_mode);
            lock_stable_count <= '0;
            lock_timer <= '0;
            state <= ST_WAIT_LOCK;
          end else if (vsync_timer >= VSYNC_TIMER_WIDTH'(VSYNC_TIMEOUT_CYCLES - 1)) begin
            state <= ST_FAILED;
            mode_error <= 1'b1;
            vsync_timer <= '0;
          end else begin
            vsync_timer <= vsync_timer + 1'b1;
          end
        end

        ST_WAIT_LOCK: begin
          if (mode_commit)
            mode_error <= 1'b1;
          if (clock_locked_sync[clock_profile_sel]) begin
            if (lock_stable_count >= LOCK_STABLE_WIDTH'(LOCK_STABLE_CYCLES - 1)) begin
              // Publish timing only after the selected clock is stable.
              timing_profile <= pending_mode;
              lock_stable_count <= '0;
              lock_timer <= '0;
              vsync_timer <= '0;
              config_timer <= '0;
              state <= ST_WAIT_CONFIG;
            end else begin
              lock_stable_count <= lock_stable_count + 1'b1;
              if (lock_timer >= LOCK_TIMER_WIDTH'(LOCK_TIMEOUT_CYCLES - 1)) begin
                lock_stable_count <= '0;
                state <= ST_FAILED;
                mode_error <= 1'b1;
              end else begin
                lock_timer <= lock_timer + 1'b1;
              end
            end
          end else begin
            lock_stable_count <= '0;
            if (lock_timer >= LOCK_TIMER_WIDTH'(LOCK_TIMEOUT_CYCLES - 1)) begin
              state <= ST_FAILED;
              mode_error <= 1'b1;
            end else begin
              lock_timer <= lock_timer + 1'b1;
            end
          end
        end

        ST_WAIT_CONFIG: begin
          // Keep reset and DVI-safe asserted until the upstream scaler/AXI profile
          // has committed geometry for the timing_profile selected above.
          if (mode_commit)
            mode_error <= 1'b1;
          if (!clock_locked_sync[clock_profile_sel]) begin
            state <= ST_FAILED;
            mode_error <= 1'b1;
            config_timer <= '0;
          end else if (mode_config_ready) begin
            config_timer <= '0;
            vsync_timer <= '0;
            state <= ST_WAIT_VSYNC;
          end else if (config_timer >= CONFIG_TIMER_WIDTH'(CONFIG_TIMEOUT_CYCLES - 1)) begin
            state <= ST_FAILED;
            mode_error <= 1'b1;
            config_timer <= '0;
          end else begin
            config_timer <= config_timer + 1'b1;
          end
        end

        ST_WAIT_VSYNC: begin
          if (mode_commit)
            mode_error <= 1'b1;
          if (!clock_locked_sync[clock_profile_sel]) begin
            state <= ST_FAILED;
            mode_error <= 1'b1;
            vsync_timer <= '0;
          end else if (pixel_vsync_rise) begin
            mode_active <= pending_mode;
            state <= ST_IDLE;
            vsync_timer <= '0;
          end else if (vsync_timer >= VSYNC_TIMER_WIDTH'(VSYNC_TIMEOUT_CYCLES - 1)) begin
            state <= ST_FAILED;
            mode_error <= 1'b1;
            vsync_timer <= '0;
          end else begin
            vsync_timer <= vsync_timer + 1'b1;
          end
        end

        ST_FAILED: begin
          // Remain reset and DVI-safe after an error. A valid commit retries from
          // this already-held state without waiting for a VSYNC that may be absent.
          if (mode_commit) begin
            if (mode_is_valid(mode_req)) begin
              pending_mode <= mode_req;
              clock_profile_sel <= mode_clock_profile(mode_req);
              lock_stable_count <= '0;
              lock_timer <= '0;
              vsync_timer <= '0;
              state <= ST_WAIT_LOCK;
            end else begin
              mode_error <= 1'b1;
            end
          end
        end

        default: begin
          state <= ST_FAILED;
          mode_error <= 1'b1;
        end
      endcase
    end
  end
endmodule
