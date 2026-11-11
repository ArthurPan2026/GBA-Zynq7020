library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

library work;
use work.pProc_bus_gba.all;

entity tb_cpu_anwj_step is
end entity;

architecture sim of tb_cpu_anwj_step is
   constant CLK_PERIOD : time := 10 ns;

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

   signal gb_bus_Adr  : std_logic_vector(31 downto 0);
   signal gb_bus_rnw  : std_logic;
   signal gb_bus_ena  : std_logic;
   signal gb_bus_acc  : std_logic_vector(1 downto 0);
   signal gb_bus_dout : std_logic_vector(31 downto 0);
   signal gb_bus_din  : std_logic_vector(31 downto 0) := (others => '0');
   signal gb_bus_done : std_logic := '0';

   signal wait_cnt_value  : unsigned(14 downto 0) := to_unsigned(100, 15);
   signal wait_cnt_update : std_logic := '0';
   signal underclock      : std_logic_vector(1 downto 0) := "00";

   signal bus_lowbits : std_logic_vector(1 downto 0);

   signal settle      : std_logic := '0';
   signal dma_on      : std_logic := '0';
   signal do_step     : std_logic := '1';
   signal done        : std_logic;
   signal cpu_idle    : std_logic;
   signal PC_in_BIOS  : std_logic;
   signal lastread    : std_logic_vector(31 downto 0);
   signal jump_out    : std_logic;

   signal new_cycles_out   : unsigned(7 downto 0);
   signal new_cycles_valid  : std_logic;

   signal dma_new_cycles   : std_logic := '0';
   signal dma_first_cycles : std_logic := '0';
   signal dma_dword_cycles : std_logic := '0';
   signal dma_toROM        : std_logic := '0';
   signal dma_init_cycles  : std_logic := '0';
   signal dma_cycles_adrup : std_logic_vector(3 downto 0) := (others => '0');

   signal IRP_in       : std_logic_vector(15 downto 0) := (others => '0');
   signal cpu_IRP      : std_logic := '0';
   signal new_halt     : std_logic := '0';

   signal DISPSTAT_debug  : std_logic_vector(31 downto 0) := (others => '0');
   signal debug_fifocount : integer := 0;

   signal timerdebug0 : std_logic_vector(31 downto 0) := (others => '0');
   signal timerdebug1 : std_logic_vector(31 downto 0) := (others => '0');
   signal timerdebug2 : std_logic_vector(31 downto 0) := (others => '0');
   signal timerdebug3 : std_logic_vector(31 downto 0) := (others => '0');

   signal debug_cpu_pc    : std_logic_vector(31 downto 0);
   signal debug_cpu_mixed  : std_logic_vector(31 downto 0);

   signal req_pending     : std_logic := '0';
   signal req_addr        : std_logic_vector(31 downto 0) := (others => '0');
   signal req_data        : std_logic_vector(31 downto 0) := (others => '0');
   signal pc_changed      : std_logic := '0';
   signal jump_seen       : std_logic := '0';
   signal cycles_seen     : std_logic := '0';

   function rom_word(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      case addr is
         when x"00000000" => return x"E51FF004"; -- BIOS shim loads the test ROM entry literal
         when x"00000004" => return x"08000000"; -- BIOS vector literal: test ROM entry
         when x"08000000" => return x"EA00002E"; -- b 0x080000c0
         when x"080000C0" => return x"E3A00012"; -- mov r0,#0x12
         when x"080000C4" => return x"E129F000"; -- msr cpsr_fc,r0
         when x"080000C8" => return x"E59FD028"; -- ldr sp,[pc,#0x28]
         when x"080000CC" => return x"E3A0001F"; -- mov r0,#0x1f
         when x"080000D0" => return x"E129F000"; -- msr cpsr_fc,r0
         when x"080000D4" => return x"E59FD018"; -- ldr sp,[pc,#0x18]
         when x"080000D8" => return x"E59F113C"; -- ldr r1,[pc,#0x13c]
         when x"080000DC" => return x"E28F0018"; -- add r0,pc,#0x18
         when x"080000E0" => return x"E5810000"; -- str r0,[r1]
         when x"080000E4" => return x"E59F1134"; -- ldr r1,[pc,#0x134]
         when x"080000E8" => return x"E1A0E00F"; -- mov lr,pc
         when x"080000EC" => return x"E12FFF11"; -- bx r1
         when x"080000F0" => return x"EAFFFFF2"; -- b 0x80000c0
         when x"080000F4" => return x"03007D00";
         when x"080000F8" => return x"03007FA0";
         when x"080000FC" => return x"E3A03301";
         when x"08000100" => return x"E2833C02";
         when x"08000104" => return x"E5932000";
         when x"08000108" => return x"E1A01802";
         when x"0800010C" => return x"E1A01821";
         when x"08000110" => return x"E14F0000";
         when x"08000114" => return x"E92D400B";
         when x"08000118" => return x"E0021822";
         when x"0800011C" => return x"E3A02000";
         when x"08000120" => return x"E2110001";
         when x"08000124" => return x"114C00B8";
         when x"08000128" => return x"1A00001F";
         when x"0800012C" => return x"E2822004";
         when x"08000130" => return x"E2110020";
         when x"08000134" => return x"1A000032";
         when x"08000138" => return x"E2822004";
         when x"0800013C" => return x"E2110080";
         when x"08000140" => return x"1A000019";
         when x"08000144" => return x"E2822004";
         when x"08000148" => return x"E2110040";
         when x"0800014C" => return x"1A000016";
         when x"08000150" => return x"E2822004";
         when x"08000154" => return x"E2110004";
         when x"08000158" => return x"1A000013";
         when x"0800015C" => return x"E2822004";
         when x"08000160" => return x"E2110002";
         when x"08000164" => return x"1A000010";
         when x"08000168" => return x"E2822004";
         when x"0800016C" => return x"E2110C01";
         when x"08000170" => return x"1A00000D";
         when x"08000174" => return x"E2822004";
         when x"08000178" => return x"E2110C02";
         when x"0800017C" => return x"1A00000A";
         when x"08000180" => return x"E2822004";
         when x"08000184" => return x"E2110B01";
         when x"08000188" => return x"1A000007";
         when x"0800018C" => return x"E2822004";
         when x"08000190" => return x"E2110B02";
         when x"08000194" => return x"1A000004";
         when x"08000198" => return x"E2822004";
         when x"0800019C" => return x"E2110A01";
         when x"080001A0" => return x"1A000001";
         when x"080001A4" => return x"E2822004";
         when x"080001A8" => return x"E2110A02";
         when x"080001AC" => return x"E1C300B2";
         when x"080001B0" => return x"E59F106C";
         when x"080001B4" => return x"E1C310B0";
         when x"080001B8" => return x"E10F3000";
         when x"080001BC" => return x"E3C330DF";
         when x"080001C0" => return x"E383301F";
         when x"080001C4" => return x"E129F003";
         when x"080001C8" => return x"E59F1058";
         when x"080001CC" => return x"E0811002";
         when x"080001D0" => return x"E5910000";
         when x"080001D4" => return x"E92D4000";
         when x"080001D8" => return x"E28FE000";
         when x"080001DC" => return x"E12FFF10";
         when x"080001E0" => return x"E8BD4000";
         when x"080001E4" => return x"E10F3000";
         when x"080001E8" => return x"E3C330DF";
         when x"080001EC" => return x"E3833092";
         when x"080001F0" => return x"E129F003";
         when x"080001F4" => return x"E8BD400B";
         when x"080001F8" => return x"E1C310B0";
         when x"080001FC" => return x"E169F000";
         when x"08000200" => return x"E12FFF1E";
         when x"08000204" => return x"E1C300B2";
         when x"08000208" => return x"E59F101C";
         when x"0800020C" => return x"E0811002";
         when x"08000210" => return x"E5910000";
         when x"08000214" => return x"E28DD010";
         when x"08000218" => return x"E12FFF10";
         when x"0800021C" => return x"03007FFC";
         when x"08000220" => return x"08000399";
         when x"08000224" => return x"00002004";
         when x"08000228" => return x"03003650";
         when x"0800022C" => return x"080862B8";
         when x"08000230" => return x"2700B5F0";
         when x"08000234" => return x"4D282600";
         when x"08000238" => return x"F8D8F002";
         when x"0800023C" => return x"21014827";
         when others      => return x"E1A00000"; -- ARM NOP
      end case;
   end function;

begin
   clk100 <= not clk100 after CLK_PERIOD/2;

   dut : entity work.gba_cpu
   generic map (
      is_simu => '0'
   )
   port map (
      clk100 => clk100,
      gb_on => gb_on,
      reset => reset,
      savestate_bus => savestate_bus,
      gb_bus_Adr => gb_bus_Adr,
      gb_bus_rnw => gb_bus_rnw,
      gb_bus_ena => gb_bus_ena,
      gb_bus_acc => gb_bus_acc,
      gb_bus_dout => gb_bus_dout,
      gb_bus_din => gb_bus_din,
      gb_bus_done => gb_bus_done,
      wait_cnt_value => wait_cnt_value,
      wait_cnt_update => wait_cnt_update,
      Underclock => underclock,
      bus_lowbits => bus_lowbits,
      settle => settle,
      dma_on => dma_on,
      do_step => do_step,
      done => done,
      CPU_bus_idle => cpu_idle,
      PC_in_BIOS => PC_in_BIOS,
      lastread => lastread,
      jump_out => jump_out,
      new_cycles_out => new_cycles_out,
      new_cycles_valid => new_cycles_valid,
      dma_new_cycles => dma_new_cycles,
      dma_first_cycles => dma_first_cycles,
      dma_dword_cycles => dma_dword_cycles,
      dma_toROM => dma_toROM,
      dma_init_cycles => dma_init_cycles,
      dma_cycles_adrup => dma_cycles_adrup,
      IRP_in => IRP_in,
      cpu_IRP => cpu_IRP,
      new_halt => new_halt,
      DISPSTAT_debug => DISPSTAT_debug,
      debug_fifocount => debug_fifocount,
      timerdebug0 => timerdebug0,
      timerdebug1 => timerdebug1,
      timerdebug2 => timerdebug2,
      timerdebug3 => timerdebug3,
      debug_cpu_pc => debug_cpu_pc,
      debug_cpu_mixed => debug_cpu_mixed
   );

   -- ROM/bus model: one cycle latency, enough for first branch and its target.
   process(clk100)
   begin
      if rising_edge(clk100) then
         gb_bus_done <= '0';
         if req_pending = '1' then
            gb_bus_done <= '1';
            gb_bus_din  <= req_data;
            req_pending <= '0';
         elsif gb_bus_ena = '1' then
            req_pending <= '1';
            req_addr <= gb_bus_Adr;
            req_data <= rom_word(gb_bus_Adr);
         end if;
      end if;
   end process;

   -- trace state changes so we can see if the branch actually commits.
   process(clk100)
   begin
      if rising_edge(clk100) then
         if debug_cpu_pc /= x"00000000" and pc_changed = '0' then
            pc_changed <= '1';
         end if;

         if jump_out = '1' then
            jump_seen <= '1';
            report "jump_out pulse: pc=" & to_hstring(debug_cpu_pc) &
                   " mixed=" & to_hstring(debug_cpu_mixed) &
                   " new_cycles=" & integer'image(to_integer(new_cycles_out))
              severity note;
         end if;

         if new_cycles_valid = '1' then
            cycles_seen <= '1';
            report "new_cycles_valid pulse: pc=" & to_hstring(debug_cpu_pc) &
                   " cycles=" & integer'image(to_integer(new_cycles_out)) &
                   " mixed=" & to_hstring(debug_cpu_mixed) &
                   " bus_done=" & std_logic'image(gb_bus_done)
              severity note;
         end if;
      end if;
   end process;

   stimulus : process
      variable wait_cycles : integer := 0;
   begin
      wait for 40 ns;
      reset <= '0';
      wait for 20 ns;
      gb_on <= '1';
      wait_cnt_update <= '1';
      wait for CLK_PERIOD;
      wait_cnt_update <= '0';

      -- 运行一段时间，观察是否能从 0x08000004 跳出。
      wait_cycles := 0;
      while wait_cycles < 3000 loop
         wait for CLK_PERIOD;
         wait_cycles := wait_cycles + 1;
         if jump_seen = '1' and cycles_seen = '1' and debug_cpu_pc = x"080000C0" then
            exit;
         end if;
      end loop;

      assert jump_seen = '1'
         report "FAIL: jump_out never pulsed; branch did not execute"
         severity failure;

      assert cycles_seen = '1'
         report "FAIL: new_cycles_valid never pulsed; do_step -> execute chain stalled"
         severity failure;

      assert debug_cpu_pc /= x"08000004"
         report "FAIL: PC remained fixed at 0x08000004"
         severity failure;

      report "PASS: CPU moved beyond 0x08000004, final PC=" & to_hstring(debug_cpu_pc)
         severity note;
      report "TEST_PASS: tb_cpu_anwj_step" severity note;
      finish;
   end process;

  watchdog : process
  begin
    wait for 5 ms;
    assert false report "TEST_FAIL watchdog timeout in tb_cpu_anwj_step.vhd" severity failure;
    wait;
  end process;

end architecture;

