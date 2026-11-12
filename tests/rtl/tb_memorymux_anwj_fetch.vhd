library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

library work;
use work.pProc_bus_gba.all;

entity tb_memorymux_anwj_fetch is
end entity;

architecture sim of tb_memorymux_anwj_fetch is
   constant CLK_PERIOD : time := 10 ns;
   constant CACHE_CLEAR_SETTLE : time := 85 us;
   constant TEST_TIMEOUT : time := 5 ms;

   signal clk100 : std_logic := '0';
   signal gb_on  : std_logic := '0';
   signal reset  : std_logic := '1';

   signal savestate_bus : proc_bus_gb_type := (
      Din  => (others => '0'),
      Dout => (others => '0'),
      Adr  => (others => '0'),
      rnw  => '0',
      ena  => '0',
      done => '0',
      acc  => (others => '0'),
      bEna => (others => '0'),
      rst  => '0'
   );

   signal sdram_read_ena     : std_logic;
   signal sdram_read_done    : std_logic := '0';
   signal sdram_read_addr    : std_logic_vector(24 downto 0);
   signal sdram_read_data    : std_logic_vector(31 downto 0) := x"EA00002E";
   signal sdram_second_dword : std_logic_vector(31 downto 0) := x"E3A00012";

   signal bus_out_Din  : std_logic_vector(31 downto 0);
   signal bus_out_Dout : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_out_Adr  : std_logic_vector(25 downto 0);
   signal bus_out_rnw  : std_logic;
   signal bus_out_ena  : std_logic;
   signal bus_out_done : std_logic := '0';

   signal gb_bus_out : proc_bus_gb_type := (
      Din  => (others => '0'),
      Dout => (others => '0'),
      Adr  => (others => '0'),
      rnw  => '0',
      ena  => '0',
      done => '0',
      acc  => (others => '0'),
      bEna => (others => '0'),
      rst  => '0'
   );

   signal mem_bus_Adr    : std_logic_vector(31 downto 0) := (others => '0');
   signal mem_bus_rnw    : std_logic := '0';
   signal mem_bus_ena    : std_logic := '0';
   signal mem_bus_acc    : std_logic_vector(1 downto 0) := ACCESS_32BIT;
   signal mem_bus_dout   : std_logic_vector(31 downto 0) := (others => '0');
   signal mem_bus_din    : std_logic_vector(31 downto 0);
   signal mem_bus_done   : std_logic;
   signal mem_bus_unread : std_logic;

   signal bios_wraddr : std_logic_vector(11 downto 0) := (others => '0');
   signal bios_wrdata : std_logic_vector(31 downto 0) := (others => '0');
   signal bios_wr     : std_logic := '0';

   signal bus_lowbits : std_logic_vector(1 downto 0) := "00";

   signal dma_soon : std_logic := '0';
   signal settle   : std_logic;

   signal save_eeprom : std_logic;
   signal save_sram   : std_logic;
   signal save_flash  : std_logic;

   signal new_cycles       : unsigned(7 downto 0) := (others => '0');
   signal new_cycles_valid : std_logic := '0';

   signal PC_in_BIOS      : std_logic := '0';
   signal lastread        : std_logic_vector(31 downto 0) := (others => '0');
   signal lastread_dma    : std_logic_vector(31 downto 0) := (others => '0');
   signal last_access_dma : std_logic := '0';

   signal dma_eepromcount   : unsigned(16 downto 0) := (others => '0');
   signal flash_1m          : std_logic := '0';
   signal MaxPakAddr        : std_logic_vector(24 downto 0) := std_logic_vector(to_unsigned(16#200000#, 25));
   signal SramFlashEnable   : std_logic := '1';
   signal memory_remap      : std_logic := '0';

   signal bitmapdrawmode : std_logic := '0';

   signal VRAM_Lo_addr    : integer range 0 to 16383;
   signal VRAM_Lo_datain  : std_logic_vector(31 downto 0);
   signal VRAM_Lo_dataout : std_logic_vector(31 downto 0) := (others => '0');
   signal VRAM_Lo_we      : std_logic;
   signal VRAM_Lo_be      : std_logic_vector(3 downto 0);
   signal VRAM_Hi_addr    : integer range 0 to 8191;
   signal VRAM_Hi_datain  : std_logic_vector(31 downto 0);
   signal VRAM_Hi_dataout : std_logic_vector(31 downto 0) := (others => '0');
   signal VRAM_Hi_we      : std_logic;
   signal VRAM_Hi_be      : std_logic_vector(3 downto 0);
   signal vram_blocked    : std_logic := '0';
   signal video_mem_clear_busy : std_logic;
   signal vram_cycle      : std_logic;

   signal OAMRAM_PROC_addr    : integer range 0 to 255;
   signal OAMRAM_PROC_datain  : std_logic_vector(31 downto 0);
   signal OAMRAM_PROC_dataout : std_logic_vector(31 downto 0) := (others => '0');
   signal OAMRAM_PROC_we      : std_logic_vector(3 downto 0);

   signal PALETTE_BG_addr    : integer range 0 to 128;
   signal PALETTE_BG_datain  : std_logic_vector(31 downto 0);
   signal PALETTE_BG_dataout : std_logic_vector(31 downto 0) := (others => '0');
   signal PALETTE_BG_we      : std_logic_vector(3 downto 0);
   signal PALETTE_OAM_addr    : integer range 0 to 128;
   signal PALETTE_OAM_datain  : std_logic_vector(31 downto 0);
   signal PALETTE_OAM_dataout : std_logic_vector(31 downto 0) := (others => '0');
   signal PALETTE_OAM_we      : std_logic_vector(3 downto 0);

   signal specialmodule : std_logic := '0';
   signal GPIO_readEna  : std_logic;
   signal GPIO_done     : std_logic := '0';
   signal GPIO_Din      : std_logic_vector(3 downto 0) := (others => '0');
   signal GPIO_Dout     : std_logic_vector(3 downto 0);
   signal GPIO_writeEna : std_logic;
   signal GPIO_addr     : std_logic_vector(1 downto 0);

   signal tilt        : std_logic := '0';
   signal AnalogTiltX : signed(7 downto 0) := (others => '0');
   signal AnalogTiltY : signed(7 downto 0) := (others => '0');

   signal debug_mem : std_logic_vector(31 downto 0);

   signal rd_pipe : std_logic_vector(2 downto 0) := (others => '0');
   signal seen_sdram_req : std_logic := '0';
   signal mem_done_count : integer range 0 to 15 := 0;
begin
   clk100 <= not clk100 after CLK_PERIOD/2;

   dut : entity work.gba_memorymux
   generic map (
      is_simu               => '1',
      Softmap_GBA_Gamerom_ADDR => 0,
      Softmap_GBA_WRam_ADDR    => 0,
      Softmap_GBA_FLASH_ADDR   => 0,
      Softmap_GBA_EEPROM_ADDR  => 0
   )
   port map (
      clk100 => clk100,
      gb_on  => gb_on,
      reset  => reset,
      savestate_bus => savestate_bus,
      sdram_read_ena => sdram_read_ena,
      sdram_read_done => sdram_read_done,
      sdram_read_addr => sdram_read_addr,
      sdram_read_data => sdram_read_data,
      sdram_second_dword => sdram_second_dword,
      bus_out_Din => bus_out_Din,
      bus_out_Dout => bus_out_Dout,
      bus_out_Adr => bus_out_Adr,
      bus_out_rnw => bus_out_rnw,
      bus_out_ena => bus_out_ena,
      bus_out_done => bus_out_done,
      gb_bus_out => gb_bus_out,
      mem_bus_Adr => mem_bus_Adr,
      mem_bus_rnw => mem_bus_rnw,
      mem_bus_ena => mem_bus_ena,
      mem_bus_acc => mem_bus_acc,
      mem_bus_dout => mem_bus_dout,
      mem_bus_din => mem_bus_din,
      mem_bus_done => mem_bus_done,
      mem_bus_unread => mem_bus_unread,
      bios_wraddr => bios_wraddr,
      bios_wrdata => bios_wrdata,
      bios_wr => bios_wr,
      bus_lowbits => bus_lowbits,
      dma_soon => dma_soon,
      settle => settle,
      save_eeprom => save_eeprom,
      save_sram => save_sram,
      save_flash => save_flash,
      new_cycles => new_cycles,
      new_cycles_valid => new_cycles_valid,
      PC_in_BIOS => PC_in_BIOS,
      lastread => lastread,
      lastread_dma => lastread_dma,
      last_access_dma => last_access_dma,
      dma_eepromcount => dma_eepromcount,
      flash_1m => flash_1m,
      MaxPakAddr => MaxPakAddr,
      SramFlashEnable => SramFlashEnable,
      memory_remap => memory_remap,
      bitmapdrawmode => bitmapdrawmode,
      VRAM_Lo_addr => VRAM_Lo_addr,
      VRAM_Lo_datain => VRAM_Lo_datain,
      VRAM_Lo_dataout => VRAM_Lo_dataout,
      VRAM_Lo_we => VRAM_Lo_we,
      VRAM_Lo_be => VRAM_Lo_be,
      VRAM_Hi_addr => VRAM_Hi_addr,
      VRAM_Hi_datain => VRAM_Hi_datain,
      VRAM_Hi_dataout => VRAM_Hi_dataout,
      VRAM_Hi_we => VRAM_Hi_we,
      VRAM_Hi_be => VRAM_Hi_be,
      vram_blocked => vram_blocked,
      video_mem_clear_blocked => '0', video_mem_clear_bus_active => '0',
      video_mem_clear_busy => video_mem_clear_busy,
      vram_cycle => vram_cycle,
      OAMRAM_PROC_addr => OAMRAM_PROC_addr,
      OAMRAM_PROC_datain => OAMRAM_PROC_datain,
      OAMRAM_PROC_dataout => OAMRAM_PROC_dataout,
      OAMRAM_PROC_we => OAMRAM_PROC_we,
      PALETTE_BG_addr => PALETTE_BG_addr,
      PALETTE_BG_datain => PALETTE_BG_datain,
      PALETTE_BG_dataout => PALETTE_BG_dataout,
      PALETTE_BG_we => PALETTE_BG_we,
      PALETTE_OAM_addr => PALETTE_OAM_addr,
      PALETTE_OAM_datain => PALETTE_OAM_datain,
      PALETTE_OAM_dataout => PALETTE_OAM_dataout,
      PALETTE_OAM_we => PALETTE_OAM_we,
      specialmodule => specialmodule,
      GPIO_readEna => GPIO_readEna,
      GPIO_done => GPIO_done,
      GPIO_Din => GPIO_Din,
      GPIO_Dout => GPIO_Dout,
      GPIO_writeEna => GPIO_writeEna,
      GPIO_addr => GPIO_addr,
      tilt => tilt,
      AnalogTiltX => AnalogTiltX,
      AnalogTiltY => AnalogTiltY,
      debug_mem => debug_mem
   );

   -- 简单 SDRAM 应答模型：检测到请求后 2 拍回包。
   process(clk100)
   begin
      if rising_edge(clk100) then
         rd_pipe <= rd_pipe(1 downto 0) & sdram_read_ena;
         sdram_read_done <= rd_pipe(2);
         if sdram_read_ena = '1' then
            seen_sdram_req <= '1';
            -- 按地址返回不同假数据，方便后续扩展观察。
            if sdram_read_addr(7 downto 0) = x"00" then
               sdram_read_data <= x"EA00002E";
               sdram_second_dword <= x"E3A00012";
            else
               sdram_read_data <= x"E12FFF1E";
               sdram_second_dword <= x"E3A00000";
            end if;
         end if;
         if mem_bus_done = '1' then
            if mem_done_count < 15 then
               mem_done_count <= mem_done_count + 1;
            end if;
         end if;
      end if;
   end process;

   stimulus : process
   begin
      -- 复位窗口
      wait for 80 ns;
      reset <= '0';
      wait until video_mem_clear_busy = '0';
      wait for 20 ns;
      gb_on <= '1';
      -- CLEARCACHE advances only while gb_on is high; wait for all 8192 entries.
      wait for CACHE_CLEAR_SETTLE;
      report "INFO: cache initialization complete; starting ROM fetches" severity note;

      -- 请求在下降沿建立，保持到本笔事务自己的完成脉冲。
      wait until falling_edge(clk100);
      mem_bus_Adr <= x"08000000";
      mem_bus_rnw <= '1';
      mem_bus_acc <= ACCESS_32BIT;
      mem_bus_ena <= '1';
      wait until mem_bus_done = '1' for 20 us;
      assert mem_bus_done = '1'
         report "FAIL: first ROM fetch timed out"
         severity failure;
      mem_bus_ena <= '0';

      -- 给 memorymux 一个完整的空闲时钟，再提交下一笔请求。
      wait until rising_edge(clk100);
      wait until falling_edge(clk100);
      mem_bus_Adr <= x"080000C0";
      mem_bus_ena <= '1';
      wait until mem_bus_done = '1' for 20 us;
      assert mem_bus_done = '1'
         report "FAIL: second ROM fetch timed out"
         severity failure;
      mem_bus_ena <= '0';

      -- 观察返回后是否出现重复完成脉冲。
      wait for 20 us;

      assert seen_sdram_req = '1'
         report "FAIL: no SDRAM request after cache initialization; ROM miss did not reach backing memory"
         severity failure;

      assert mem_done_count >= 2
         report "FAIL: second fetch (0x080000C0) did not complete"
         severity failure;

      report "PASS: first ROM fetch completed. debug_state=" &
             integer'image(to_integer(unsigned(debug_mem(7 downto 0))))
             severity note;
      report "TEST_PASS: tb_memorymux_anwj_fetch" severity note;
      finish;
   end process;

  watchdog : process
  begin
    -- Covers cache initialization plus both bounded SDRAM handshakes.
    wait for TEST_TIMEOUT;
    assert false report "TEST_FAIL watchdog timeout in tb_memorymux_anwj_fetch.vhd" severity failure;
    wait;
  end process;

end architecture;
