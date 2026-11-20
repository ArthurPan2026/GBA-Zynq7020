library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.std_logic_textio.all;
use std.textio.all;
use std.env.all;

library work;
use work.pProc_bus_gba.all;

entity tb_gba_top_full is
end entity;

architecture sim of tb_gba_top_full is
   constant CLK_PERIOD  : time := 10 ns;
   constant TEST_TIMEOUT : time := 40 ms;

   -- Match the current wrapper mapping.
   constant ROM_BASE_DW      : natural := 16#30000#;
   constant EEPROM_BASE_DW   : natural := 16#08000#;
   constant WRAM_BASE_DW     : natural := 16#20000#;
   constant EWRAM_WORDS     : natural := 65536;
   constant U32_MAX        : unsigned(31 downto 0) := (others => '1');
   constant ROM_WORDS        : natural := 262144; -- first 1 MiB of the actual ROM
   -- FPGAFlow exports XSim below a temporary project/simulation/xsim/xsim path.
   constant ROM_FILE_FLOW    : string := "../../../../../../../../../../build/sim/anwj_rom_1m.hex";
   constant ROM_FILE_XSIM    : string := "../../../../../../../build/sim/anwj_rom_1m.hex";
   constant ROM_FILE_BENCH   : string := "../../../../../../build/sim/anwj_rom_1m.hex";
   constant ROM_FILE_ROOT    : string := "build/sim/anwj_rom_1m.hex";
   constant ROM_FILE_LOCAL   : string := "anwj_rom_1m.hex";

   type rom_words_t is array (natural range <>) of std_logic_vector(31 downto 0);
   type ewram_words_t is array (0 to EWRAM_WORDS - 1) of std_logic_vector(31 downto 0);
   signal ewram_model : ewram_words_t := (others => (others => '0'));

   impure function load_rom_hex return rom_words_t is
      file f : text;
      variable open_status : file_open_status;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : rom_words_t(0 to ROM_WORDS - 1);
      variable loaded_words : natural := 0;
   begin
      -- FPGAFlow XSim runs below a temporary project/simulation/xsim/xsim
      -- directory. Keep the legacy project-root and build/sim invocations
      -- as fallbacks for manual Vivado runs.
      file_open(open_status, f, ROM_FILE_FLOW, read_mode);
      if open_status /= open_ok then
         file_open(open_status, f, ROM_FILE_XSIM, read_mode);
      end if;
      if open_status /= open_ok then
         file_open(open_status, f, ROM_FILE_BENCH, read_mode);
      end if;
      if open_status /= open_ok then
         file_open(open_status, f, ROM_FILE_ROOT, read_mode);
      end if;
      if open_status /= open_ok then
         file_open(open_status, f, ROM_FILE_LOCAL, read_mode);
      end if;

      if open_status /= open_ok then
         report "TEST_FAIL: unable to open build/sim/anwj_rom_1m.hex" severity failure;
         for i in mem'range loop
            mem(i) := x"E1A00000";
         end loop;
         return mem;
      end if;

      for i in mem'range loop
         if endfile(f) then
            mem(i) := x"E1A00000";
         else
            readline(f, l);
            hread(l, w);
            mem(i) := w;
            loaded_words := loaded_words + 1;
         end if;
      end loop;
      file_close(f);

      if loaded_words /= ROM_WORDS then
         report "TEST_FAIL: ANWJ ROM image word count mismatch (loaded " &
                integer'image(loaded_words) & ")" severity failure;
      end if;
      return mem;
   end function;

   impure function rom_word_at(mem : rom_words_t; dw_addr : unsigned(24 downto 0)) return std_logic_vector is
      variable idx : integer;
   begin
      idx := to_integer(dw_addr);
      if idx >= ROM_BASE_DW and idx < ROM_BASE_DW + ROM_WORDS then
         return mem(idx - ROM_BASE_DW);
      else
         -- Unmapped reads return a benign ARM NOP.
         return x"E1A00000";
      end if;
   end function;

   constant rom_mem : rom_words_t(0 to ROM_WORDS - 1) := load_rom_hex;

   signal clk100   : std_logic := '0';
   signal test_done : std_logic := '0';

   signal gba_on            : std_logic := '0';
   signal gba_lockspeed     : std_logic := '1';
   signal gba_cputurbo      : std_logic := '0';
   signal gba_flash_1m      : std_logic := '0';
   signal cycle_precalc     : std_logic_vector(15 downto 0) := x"0064";
   signal underclock        : std_logic_vector(1 downto 0) := "00";
   signal maxpakaddr        : std_logic_vector(24 downto 0) := std_logic_vector(to_unsigned(16#00200000#, 25));
   signal cycles_missing    : std_logic_vector(31 downto 0);
   signal cycles_vsync      : std_logic_vector(31 downto 0);
   signal sram_flash_enable : std_logic := '1';
   signal sram32k_mirror    : std_logic := '0';
   signal memory_remap      : std_logic := '0';
   signal inc_ss_header     : std_logic := '0';
   signal save_state        : std_logic := '0';
   signal load_state        : std_logic := '0';
   signal interframe_blend  : std_logic_vector(1 downto 0) := "00";
   signal maxpixels         : std_logic := '0';
   signal shade_mode        : std_logic_vector(2 downto 0) := "000";
   signal hdmode2x_bg       : std_logic := '0';
   signal hdmode2x_obj      : std_logic := '0';
   signal specialmodule     : std_logic := '0';
   signal solar_in          : std_logic_vector(2 downto 0) := "000";
   signal tilt              : std_logic := '0';
   signal rewind_on         : std_logic := '0';
   signal rewind_active     : std_logic := '0';
   signal savestate_number  : integer := 0;

   signal rtc_timestamp_new  : std_logic := '0';
   signal rtc_timestamp_in   : std_logic_vector(31 downto 0) := x"69E00000";
   signal rtc_timestamp_saved: std_logic_vector(31 downto 0) := x"69E00000";
   signal rtc_savedtime_in   : std_logic_vector(41 downto 0) := (others => '0');
   signal rtc_save_loaded    : std_logic := '1';
   signal rtc_timestamp_out  : std_logic_vector(31 downto 0);
   signal rtc_savedtime_out  : std_logic_vector(41 downto 0);
   signal rtc_inuse          : std_logic;

   signal cheat_clear        : std_logic := '0';
   signal cheats_enabled     : std_logic := '0';
   signal cheat_on           : std_logic := '0';
   signal cheat_in           : std_logic_vector(127 downto 0) := (others => '0');
   signal cheats_active      : std_logic;

   signal sdram_read_ena     : std_logic;
   signal sdram_read_done    : std_logic := '0';
   signal sdram_read_addr    : std_logic_vector(24 downto 0);
   signal sdram_read_data    : std_logic_vector(31 downto 0) := x"E1A00000";
   signal sdram_second_dword : std_logic_vector(31 downto 0) := x"E1A00000";

   signal bus_out_din   : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_out_dout  : std_logic_vector(31 downto 0);
   signal bus_out_adr   : std_logic_vector(25 downto 0);
   signal bus_out_rnw   : std_logic;
   signal bus_out_ena   : std_logic;
   signal bus_out_done  : std_logic := '1';

   -- Bounded counters and address snapshots for the external DWORD bus model.
   signal bus_out_rd_req_count    : unsigned(31 downto 0) := (others => '0');
   signal bus_out_rd_retire_count : unsigned(31 downto 0) := (others => '0');
   signal bus_out_wr_req_count    : unsigned(31 downto 0) := (others => '0');
   signal bus_out_wr_retire_count : unsigned(31 downto 0) := (others => '0');
   signal bus_out_first_rd_addr   : std_logic_vector(25 downto 0) := (others => '0');
   signal bus_out_last_rd_addr    : std_logic_vector(25 downto 0) := (others => '0');
   signal bus_out_first_wr_addr   : std_logic_vector(25 downto 0) := (others => '0');
   signal bus_out_last_wr_addr    : std_logic_vector(25 downto 0) := (others => '0');

   signal save_out_din    : std_logic_vector(63 downto 0) := (others => '0');
   signal save_out_dout   : std_logic_vector(63 downto 0);
   signal save_out_adr    : std_logic_vector(25 downto 0);
   signal save_out_rnw    : std_logic;
   signal save_out_ena    : std_logic;
   signal save_out_active : std_logic;
   signal save_out_be     : std_logic_vector(7 downto 0);
   signal save_out_done   : std_logic := '1';

   signal bios_wraddr : std_logic_vector(11 downto 0) := (others => '0');
   signal bios_wrdata : std_logic_vector(31 downto 0) := (others => '0');
   signal bios_wr     : std_logic := '0';

   signal save_eeprom : std_logic;
   signal save_sram   : std_logic;
   signal save_flash  : std_logic;
   signal load_done   : std_logic;

   signal key_a, key_b, key_select, key_start : std_logic := '0';
   signal key_right, key_left, key_up, key_down : std_logic := '0';
   signal key_r, key_l : std_logic := '0';
   signal analog_tilt_x : signed(7 downto 0) := (others => '0');
   signal analog_tilt_y : signed(7 downto 0) := (others => '0');
   signal rumble        : std_logic;

   signal gba_bus_addr      : std_logic_vector(27 downto 0) := (others => '0');
   signal gba_bus_rnw       : std_logic := '0';
   signal gba_bus_acc       : std_logic_vector(1 downto 0) := (others => '0');
   signal gba_bus_write_data: std_logic_vector(31 downto 0) := (others => '0');
   signal gba_bus_read_data : std_logic_vector(31 downto 0);
   signal gba_bus_written   : std_logic := '0';

   signal pixel_out_x    : integer range 0 to 239;
   signal pixel_out_y    : integer range 0 to 159;
   signal pixel_out_addr : integer range 0 to 38399;
   signal pixel_out_data : std_logic_vector(17 downto 0);
   signal pixel_out_we   : std_logic;

   signal largeimg_out_base  : std_logic_vector(31 downto 0);
   signal largeimg_out_addr   : std_logic_vector(25 downto 0) := (others => '0');
   signal largeimg_out_data   : std_logic_vector(63 downto 0);
   signal largeimg_out_req    : std_logic;
   signal largeimg_out_done   : std_logic := '1';
   signal largeimg_newframe   : std_logic := '1';
   signal largeimg_singlebuf  : std_logic := '0';

   signal sound_out_left  : std_logic_vector(15 downto 0);
   signal sound_out_right : std_logic_vector(15 downto 0);

   signal debug_cpu_pc     : std_logic_vector(31 downto 0);
signal debug_cpu_mixed  : std_logic_vector(31 downto 0);
signal debug_irq        : std_logic_vector(31 downto 0);
signal debug_irq_ext    : std_logic_vector(31 downto 0);
signal debug_dma        : std_logic_vector(31 downto 0);
   signal debug_mem        : std_logic_vector(31 downto 0);
   signal debug_internal   : std_logic_vector(31 downto 0);

   signal sdram_pending    : std_logic := '0';
   signal sdram_pending_addr : unsigned(24 downto 0) := (others => '0');
   signal seen_sdram_read   : std_logic := '0';

   signal prev_pc          : std_logic_vector(31 downto 0) := (others => '0');

   signal seen_thumb       : std_logic := '0';
   signal seen_halt        : std_logic := '0';
   signal seen_pc_4c8      : std_logic := '0';
   signal seen_pc_8075c    : std_logic := '0';
   signal seen_dma3_start  : std_logic := '0';
   signal seen_dma3_finish : std_logic := '0';
   signal seen_irq_pending : std_logic := '0';
   signal seen_pc_change    : std_logic := '0';
   signal inst_count        : integer := 0;

   function bit_to_char(b : std_logic) return character is
   begin
      if b = '1' then
         return '1';
      else
         return '0';
      end if;
   end function;

   function u32_to_hex(s : std_logic_vector(31 downto 0)) return string is
   begin
      return to_hstring(s);
   end function;

begin
   clk100 <= not clk100 after CLK_PERIOD / 2;

   dut : entity work.gba_top
      generic map (
         Softmap_GBA_Gamerom_ADDR => 16#30000#,
         Softmap_GBA_WRam_ADDR    => 16#20000#,
         Softmap_GBA_FLASH_ADDR   => 16#00000#,
         Softmap_GBA_EEPROM_ADDR  => 16#08000#,
         Softmap_SaveState_ADDR   => 16#4000000#,
         Softmap_Rewind_ADDR      => 16#2000000#,
         is_simu                  => '0',
         turbosound               => '0'
      )
      port map (
         clk100                => clk100,
         GBA_on                => gba_on,
         GBA_lockspeed         => gba_lockspeed,
         GBA_cputurbo          => gba_cputurbo,
         GBA_flash_1m          => gba_flash_1m,
         CyclePrecalc          => cycle_precalc,
         Underclock            => underclock,
         MaxPakAddr            => maxpakaddr,
         CyclesMissing         => cycles_missing,
         CyclesVsyncSpeed      => cycles_vsync,
         SramFlashEnable       => sram_flash_enable,
         Sram32KMirrorTest     => sram32k_mirror,
         memory_remap          => memory_remap,
         increaseSSHeaderCount => inc_ss_header,
         save_state            => save_state,
         load_state            => load_state,
         interframe_blend      => interframe_blend,
         maxpixels             => maxpixels,
         shade_mode            => shade_mode,
         hdmode2x_bg           => hdmode2x_bg,
         hdmode2x_obj          => hdmode2x_obj,
         specialmodule         => specialmodule,
         solar_in              => solar_in,
         tilt                  => tilt,
         rewind_on             => rewind_on,
         rewind_active         => rewind_active,
         savestate_number      => savestate_number,
         RTC_timestampNew      => rtc_timestamp_new,
         RTC_timestampIn       => rtc_timestamp_in,
         RTC_timestampSaved    => rtc_timestamp_saved,
         RTC_savedtimeIn       => rtc_savedtime_in,
         RTC_saveLoaded        => rtc_save_loaded,
         RTC_timestampOut      => rtc_timestamp_out,
         RTC_savedtimeOut      => rtc_savedtime_out,
         RTC_inuse             => rtc_inuse,
         cheat_clear           => cheat_clear,
         cheats_enabled        => cheats_enabled,
         cheat_on              => cheat_on,
         cheat_in              => cheat_in,
         cheats_active         => cheats_active,
         sdram_read_ena        => sdram_read_ena,
         sdram_read_done       => sdram_read_done,
         sdram_read_addr       => sdram_read_addr,
         sdram_read_data       => sdram_read_data,
         sdram_second_dword    => sdram_second_dword,
         bus_out_Din           => bus_out_din,
         bus_out_Dout          => bus_out_dout,
         bus_out_Adr           => bus_out_adr,
         bus_out_rnw           => bus_out_rnw,
         bus_out_ena           => bus_out_ena,
         bus_out_done          => bus_out_done,
         SAVE_out_Din          => save_out_din,
         SAVE_out_Dout         => save_out_dout,
         SAVE_out_Adr          => save_out_adr,
         SAVE_out_rnw          => save_out_rnw,
         SAVE_out_ena          => save_out_ena,
         SAVE_out_active       => save_out_active,
         SAVE_out_be           => save_out_be,
         SAVE_out_done         => save_out_done,
         bios_wraddr           => bios_wraddr,
         bios_wrdata           => bios_wrdata,
         bios_wr               => bios_wr,
         save_eeprom           => save_eeprom,
         save_sram             => save_sram,
         save_flash            => save_flash,
         load_done             => load_done,
         KeyA                  => key_a,
         KeyB                  => key_b,
         KeySelect             => key_select,
         KeyStart              => key_start,
         KeyRight              => key_right,
         KeyLeft               => key_left,
         KeyUp                 => key_up,
         KeyDown               => key_down,
         KeyR                  => key_r,
         KeyL                  => key_l,
         AnalogTiltX           => analog_tilt_x,
         AnalogTiltY           => analog_tilt_y,
         Rumble                => rumble,
         GBA_BusAddr           => gba_bus_addr,
         GBA_BusRnW            => gba_bus_rnw,
         GBA_BusACC            => gba_bus_acc,
         GBA_BusWriteData      => gba_bus_write_data,
         GBA_BusReadData       => gba_bus_read_data,
         GBA_Bus_written       => gba_bus_written,
         pixel_out_x           => pixel_out_x,
         pixel_out_y           => pixel_out_y,
         pixel_out_addr        => pixel_out_addr,
         pixel_out_data        => pixel_out_data,
         pixel_out_we          => pixel_out_we,
         largeimg_out_base     => largeimg_out_base,
         largeimg_out_addr     => largeimg_out_addr,
         largeimg_out_data     => largeimg_out_data,
         largeimg_out_req      => largeimg_out_req,
         largeimg_out_done     => largeimg_out_done,
         largeimg_newframe     => largeimg_newframe,
         largeimg_singlebuf    => largeimg_singlebuf,
         sound_out_left        => sound_out_left,
         sound_out_right       => sound_out_right,
         debug_cpu_pc          => debug_cpu_pc,
         debug_cpu_mixed       => debug_cpu_mixed,
         debug_cpu_r0          => open,
         debug_cpu_r1          => open,
         debug_cpu_r2          => open,
         debug_cpu_r4          => open,
         debug_cpu_cpuset      => open,
         debug_irq             => debug_irq,
         debug_irq_ext         => debug_irq_ext,
         debug_dma             => debug_dma,
         debug_dma_tr0         => open,
         debug_dma_tr1         => open,
         debug_dma_tr2         => open,
         debug_dma_tr3         => open,
         debug_dma_tr4         => open,
         debug_dma_tr5         => open,
         debug_dma_tr6         => open,
         debug_dma_tr7         => open,
         debug_dma_tr8         => open,
         debug_mem             => debug_mem,
         debug_vram_regs0      => open,
         debug_vram_regs1      => open,
         debug_vram_regs2      => open,
         debug_vram_regs3      => open,
         debug_vram_regs4      => open,
         debug_vram_hits       => open,
         debug_vram_ring0      => open,
         debug_vram_ring1      => open,
         debug_vram_ring2      => open,
         debug_vram_ring3      => open,
         debug_vram_dist0      => open,
         debug_vram_dist1      => open,
         debug_wait0           => open,
         debug_wait1           => open,
         debug_wait2           => open,
         debug_wait3           => open,
         debug_internal        => debug_internal
      );

   -- bus_out_Din is DUT write data. Return read data on bus_out_Dout and
   -- model the external EWRAM DWORD window at Softmap_GBA_WRam_ADDR.
   process(all)
      variable ewram_index : natural range 0 to EWRAM_WORDS - 1;
   begin
      bus_out_dout <= (others => '0');
      if bus_out_ena = '1' and bus_out_rnw = '1' then
         if unsigned(bus_out_adr) >= to_unsigned(WRAM_BASE_DW, bus_out_adr'length) and
            unsigned(bus_out_adr) < to_unsigned(WRAM_BASE_DW + EWRAM_WORDS, bus_out_adr'length) then
            ewram_index := to_integer(unsigned(bus_out_adr) -
                                      to_unsigned(WRAM_BASE_DW, bus_out_adr'length));
            bus_out_dout <= ewram_model(ewram_index);
         elsif unsigned(bus_out_adr) >= to_unsigned(EEPROM_BASE_DW, bus_out_adr'length) and
               unsigned(bus_out_adr) < to_unsigned(EEPROM_BASE_DW + 8192, bus_out_adr'length) then
            bus_out_dout <= x"FFFFFFFF";
         end if;
      end if;
   end process;

   -- Zero-wait external bus response. Count each request/retirement and keep
   -- first/last DWORD addresses; EWRAM writes are retained for later reads.
   process(clk100)
      variable ewram_index : natural range 0 to EWRAM_WORDS - 1;
   begin
      if rising_edge(clk100) then
         if bus_out_ena = '1' then
            if bus_out_rnw = '1' then
               if bus_out_rd_req_count = to_unsigned(0, bus_out_rd_req_count'length) then
                  bus_out_first_rd_addr <= bus_out_adr;
               end if;
               bus_out_last_rd_addr <= bus_out_adr;
               if bus_out_rd_req_count /= U32_MAX then
                  bus_out_rd_req_count <= bus_out_rd_req_count + 1;
               end if;
               if bus_out_done = '1' and bus_out_rd_retire_count /= U32_MAX then
                  bus_out_rd_retire_count <= bus_out_rd_retire_count + 1;
               end if;
            else
               if bus_out_wr_req_count = to_unsigned(0, bus_out_wr_req_count'length) then
                  bus_out_first_wr_addr <= bus_out_adr;
               end if;
               bus_out_last_wr_addr <= bus_out_adr;
               if bus_out_wr_req_count /= U32_MAX then
                  bus_out_wr_req_count <= bus_out_wr_req_count + 1;
               end if;
               if bus_out_done = '1' and bus_out_wr_retire_count /= U32_MAX then
                  bus_out_wr_retire_count <= bus_out_wr_retire_count + 1;
               end if;

               if unsigned(bus_out_adr) >= to_unsigned(WRAM_BASE_DW, bus_out_adr'length) and
                  unsigned(bus_out_adr) < to_unsigned(WRAM_BASE_DW + EWRAM_WORDS, bus_out_adr'length) then
                  ewram_index := to_integer(unsigned(bus_out_adr) -
                                            to_unsigned(WRAM_BASE_DW, bus_out_adr'length));
                  ewram_model(ewram_index) <= bus_out_din;
               end if;
            end if;
         end if;
      end if;
   end process;

   -- Nothing in this testbench blocks on the save-side handshake.
   save_out_din  <= (others => '0');
   save_out_done <= '1';
   bus_out_done   <= '1';

   -- Simple SDRAM model: one-cycle latency and real ROM contents from the GBA file.
   process(clk100)
      variable idx : integer;
   begin
      if rising_edge(clk100) then
         sdram_read_done <= '0';
         if sdram_pending = '1' then
            idx := to_integer(sdram_pending_addr);
            if idx >= ROM_BASE_DW and idx < ROM_BASE_DW + ROM_WORDS then
               sdram_read_data <= rom_mem(idx - ROM_BASE_DW);
               if (idx - ROM_BASE_DW + 1) < ROM_WORDS then
                  sdram_second_dword <= rom_mem(idx - ROM_BASE_DW + 1);
               else
                  sdram_second_dword <= x"E1A00000";
               end if;
            else
               sdram_read_data <= x"E1A00000";
               sdram_second_dword <= x"E1A00000";
            end if;
            sdram_read_done <= '1';
            sdram_pending <= '0';
         end if;

         if sdram_read_ena = '1' then
            seen_sdram_read <= '1';
            sdram_pending <= '1';
            sdram_pending_addr <= unsigned(sdram_read_addr);
            report "ROM_SDRAM_REQ addr=" & to_hstring(sdram_read_addr) &
                   " pc=" & to_hstring(debug_cpu_pc) &
                   " mem=" & to_hstring(debug_mem)
              severity note;
         end if;
      end if;
   end process;

   monitor : process(clk100)
      variable thumb_now   : std_logic;
      variable halt_now    : std_logic;
      variable pc_now      : std_logic_vector(31 downto 0);
      variable mixed_now   : std_logic_vector(31 downto 0);
      variable irq_now     : std_logic_vector(31 downto 0);
      variable dma_now     : std_logic_vector(31 downto 0);
      variable mem_now     : std_logic_vector(31 downto 0);
      variable internal_now: std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk100) then
         inst_count <= inst_count + 1;
         pc_now       := debug_cpu_pc;
         mixed_now    := debug_cpu_mixed;
         irq_now      := debug_irq;
         dma_now      := debug_dma;
         mem_now      := debug_mem;
         internal_now := debug_internal;
         thumb_now    := mixed_now(5);
         halt_now     := mixed_now(0);

         if (inst_count mod 50000) = 0 then
            report "TOP inst=" & integer'image(inst_count) &
                   " pc=" & to_hstring(pc_now) &
                   " mixed=" & to_hstring(mixed_now) &
                   " irq=" & to_hstring(irq_now) &
                   " dma=" & to_hstring(dma_now) &
                   " mem=" & to_hstring(mem_now) &
                   " int=" & to_hstring(internal_now)
              severity note;
         end if;

         if thumb_now = '1' then
            seen_thumb <= '1';
         end if;
         if halt_now = '1' then
            seen_halt <= '1';
         end if;
         if pc_now = x"080004C8" and seen_pc_4c8 = '0' then
            seen_pc_4c8 <= '1';
            report "KEY_PC reached 0x080004C8" severity note;
         end if;
         if pc_now = x"080004F2" and prev_pc /= pc_now then
            report "KEY_PC DMA3 setup path at 0x080004F2" severity note;
         end if;
         -- debug_dma[31]/[27] are sticky start/finish-valid for channel 3.
         if debug_dma(31) = '1' and seen_dma3_start = '0' then
            seen_dma3_start <= '1';
            report "DMA3_START: debug_dma=" & to_hstring(debug_dma) severity note;
         end if;
         if debug_dma(27) = '1' and seen_dma3_finish = '0' then
            seen_dma3_finish <= '1';
            report "DMA3_FINISH: debug_dma=" & to_hstring(debug_dma) severity note;
         end if;
         if (pc_now = x"0808075C" or pc_now = x"0808075D") and seen_pc_8075c = '0' then
            seen_pc_8075c <= '1';
            report "KEY_PC reached 0x0808075C" severity note;
         end if;
         if unsigned(irq_now(15 downto 0)) /= 0 then
            seen_irq_pending <= '1';
         end if;

         if pc_now /= prev_pc then
            seen_pc_change <= '1';
         end if;

         prev_pc       <= pc_now;
      end if;
   end process;

   stimulus : process
      variable wait_cycles : integer := 0;
   begin
      -- Install a two-word BIOS handoff shim while the core is off. The
      -- system test targets the real cartridge startup/IRQ path, while the
      -- Nintendo BIOS may spend a much longer variable interval in its own
      -- startup loop. LDR pc,[pc,#-4] at BIOS word 0 loads the literal at word
      -- 1 and transfers to the ROM entry point without changing the DUT.
      wait for 40 ns;
      bios_wraddr <= x"000";
      bios_wrdata <= x"E51FF004";
      bios_wr <= '1';
      wait until rising_edge(clk100);
      wait for 1 ns;
      bios_wraddr <= x"001";
      bios_wrdata <= x"08000000";
      wait until rising_edge(clk100);
      wait for 1 ns;
      bios_wr <= '0';
      wait for 24 ns;
      gba_on <= '1';

      -- DMA3 CNT_L=0 requests 65,536 words. Allow a bounded 3,500,000-clock
      -- budget (35 ms) for that startup transfer and the following ROM checkpoints.
      while wait_cycles < 3500000 loop
         wait for CLK_PERIOD;
         wait_cycles := wait_cycles + 1;
         if seen_dma3_finish = '1' and seen_pc_8075c = '1' and
            seen_thumb = '1' and seen_pc_4c8 = '1' then
            exit;
         end if;
      end loop;

      report "SUMMARY pc=" & to_hstring(debug_cpu_pc) &
             " mixed=" & to_hstring(debug_cpu_mixed) &
             " irq=" & to_hstring(debug_irq) &
             " dma=" & to_hstring(debug_dma) &
             " bus_rd_req=" & to_hstring(std_logic_vector(bus_out_rd_req_count)) &
             " bus_rd_retire=" & to_hstring(std_logic_vector(bus_out_rd_retire_count)) &
             " bus_rd_first=" & to_hstring(bus_out_first_rd_addr) &
             " bus_rd_last=" & to_hstring(bus_out_last_rd_addr) &
             " bus_wr_req=" & to_hstring(std_logic_vector(bus_out_wr_req_count)) &
             " bus_wr_retire=" & to_hstring(std_logic_vector(bus_out_wr_retire_count)) &
             " bus_wr_first=" & to_hstring(bus_out_first_wr_addr) &
             " bus_wr_last=" & to_hstring(bus_out_last_wr_addr) &
             " mem=" & to_hstring(debug_mem) &
             " int=" & to_hstring(debug_internal) &
             " seen_thumb=" & bit_to_char(seen_thumb) &
             " seen_halt=" & bit_to_char(seen_halt) &
             " seen_pc_4c8=" & bit_to_char(seen_pc_4c8) &
             " seen_pc_8075c=" & bit_to_char(seen_pc_8075c) &
             " seen_dma3_start=" & bit_to_char(seen_dma3_start) &
             " seen_dma3_finish=" & bit_to_char(seen_dma3_finish) &
             " irq_pending=" & bit_to_char(seen_irq_pending) &
             " pc_change=" & bit_to_char(seen_pc_change)
        severity note;

      if seen_pc_4c8 = '0' then
         assert false report "TEST_FAIL: did not reach the 0x080004C8 region" severity failure;
      end if;

      if seen_thumb = '0' then
         assert false report "TEST_FAIL: thumbmode never asserted during startup" severity failure;
      end if;

      if seen_pc_8075c = '0' then
         assert false report "TEST_FAIL: did not reach the 0x0808075C region" severity failure;
      end if;

      if seen_sdram_read = '0' then
         assert false report "TEST_FAIL: BIOS handoff did not request data from the ROM model" severity failure;
      end if;

      if seen_dma3_start = '0' then
         assert false report "TEST_FAIL: DMA3 never started" severity failure;
      end if;

      if seen_dma3_finish = '0' then
         assert false report "TEST_FAIL: DMA3 did not finish within 3500000 cycles" severity failure;
      end if;

      if seen_halt = '1' and seen_irq_pending = '0' then
         report "NOTE: HALT observed without any pending IRQ flags; this matches the board symptom." severity note;
      end if;

      test_done <= '1';
      report "TEST_PASS: tb_gba_top_full" severity note;
      finish;
   end process;

  watchdog : process
  begin
    wait for TEST_TIMEOUT;
    if test_done = '0' then
      assert false report "TEST_FAIL watchdog timeout in tb_gba_top_full.vhd" severity failure;
    end if;
    wait;
  end process;

end architecture;
