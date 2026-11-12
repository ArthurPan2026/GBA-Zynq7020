library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_cache_dword_timing is
end entity;

architecture sim of tb_cache_dword_timing is
   constant CLK_PERIOD : time := 10 ns;
   constant CACHE_SIZE : integer := 4096;
   constant SIZEBASEBITS : integer := 23;
   constant DDR_LATENCY : integer := 4;

   signal clk          : std_logic := '0';
   signal gb_on        : std_logic := '0';
   signal read_enable  : std_logic := '0';
   signal read_addr    : std_logic_vector(SIZEBASEBITS-1 downto 0) := (others => '0');
   signal read_data    : std_logic_vector(31 downto 0);
   signal read_done    : std_logic;
   signal read_full    : std_logic_vector(63 downto 0);

   signal mem_read_ena   : std_logic;
   signal mem_read_done  : std_logic := '0';
   signal mem_read_addr  : std_logic_vector(24 downto 0);
   signal mem_read_data  : std_logic_vector(31 downto 0) := (others => '0');
   signal mem_read_data2 : std_logic_vector(31 downto 0) := (others => '0');

   signal rena_pipe       : std_logic_vector(DDR_LATENCY downto 0) := (others => '0');
   signal ddr_latch0      : std_logic_vector(31 downto 0) := (others => '0');
   signal ddr_latch1      : std_logic_vector(31 downto 0) := (others => '0');
   signal ddr_req_count   : integer := 0;
begin
   clk <= not clk after CLK_PERIOD/2;

   dut : entity work.cache
   generic map (
      SIZE => CACHE_SIZE, SIZEBASEBITS => SIZEBASEBITS,
      BITWIDTH => 32, Softmap_GBA_Gamerom_ADDR => 0
   )
   port map (
      clk => clk, gb_on => gb_on,
      read_enable => read_enable, read_addr => read_addr,
      read_data => read_data, read_done => read_done, read_full => read_full,
      mem_read_ena => mem_read_ena, mem_read_done => mem_read_done,
      mem_read_addr => mem_read_addr,
      mem_read_data => mem_read_data, mem_read_data2 => mem_read_data2
   );

   -- DDR model: realistic AXI timing
   process(clk)
   begin
      if rising_edge(clk) then
         rena_pipe <= rena_pipe(DDR_LATENCY-1 downto 0) & mem_read_ena;
         mem_read_done <= rena_pipe(DDR_LATENCY);

         if mem_read_ena = '1' then
            ddr_req_count <= ddr_req_count + 1;
            case mem_read_addr(3 downto 0) is
               when x"0" => ddr_latch0 <= x"DEAD0000"; ddr_latch1 <= x"BEEF0000";
               when x"4" => ddr_latch0 <= x"CAFE0004"; ddr_latch1 <= x"F00D0004";
               when x"8" => ddr_latch0 <= x"12340008"; ddr_latch1 <= x"56780008";
               when others => ddr_latch0 <= x"AAAAAAAA"; ddr_latch1 <= x"BBBBBBBB";
            end case;
            report "[DDR] req#" & integer'image(ddr_req_count+1) &
                   " addr=0x" & to_hstring(mem_read_addr) severity note;
         end if;

         mem_read_data <= ddr_latch0;  -- 1 cycle delay from ddr_latch0 update

         if mem_read_done = '1' then
            mem_read_data2 <= ddr_latch1;  -- valid 1 cycle AFTER done
            report "[DDR] done#" & integer'image(ddr_req_count) &
                   " data=0x" & to_hstring(ddr_latch0) &
                   " data2=0x" & to_hstring(ddr_latch1) severity note;
         end if;
      end if;
   end process;

   process
      variable continuous_hit_count : integer := 0;

      procedure do_cache_read(addr_val : integer; label_str : string) is

      begin
         report "=== " & label_str & ": addr=" & integer'image(addr_val) & " ===" severity note;
         read_addr <= std_logic_vector(to_unsigned(addr_val, SIZEBASEBITS));
         read_enable <= '1';
         -- Hold the request until the cache's hit/done handshake is observed.
         for wait_cycle in 0 to 63 loop
            wait until rising_edge(clk);
            wait for 1 ns;
            exit when read_done = '1';
         end loop;
         read_enable <= '0';
         if read_done /= '1' then
            assert false report "TEST_FAIL: " & label_str & " cache read timed out" severity failure;
         end if;
         wait for CLK_PERIOD;
         report "[" & label_str & "] read_data=0x" & to_hstring(read_data) &
                " full=0x" & to_hstring(read_full(63 downto 32)) & "_" & to_hstring(read_full(31 downto 0)) severity note;
      end procedure;
   begin
      gb_on <= '0'; read_enable <= '0'; read_addr <= (others => '0');
      wait for 80 ns;
      gb_on <= '1';
      wait for CACHE_SIZE * CLK_PERIOD + 1 us;  -- CLEARCACHE done

      -- T1: addr 0 (miss, first fill)
      do_cache_read(0, "T1");
      assert read_data = x"DEAD0000" report "TEST_FAIL T1" severity failure;
      assert ddr_req_count = 2 report "TEST_FAIL T1: miss should fetch both dwords" severity failure;

      -- T2: addr 4 (miss, different cache line)
      do_cache_read(4, "T2");
      assert read_data = x"CAFE0004" report "TEST_FAIL T2" severity failure;
      assert ddr_req_count = 4 report "TEST_FAIL T2: second miss should add two dword reads" severity failure;

      -- T3: addr 0 (hit, verify cache intact)
      do_cache_read(0, "T3");
      assert read_data = x"DEAD0000" report "TEST_FAIL T3" severity failure;
      assert ddr_req_count = 4 report "TEST_FAIL T3: cached hit issued DDR reads" severity failure;

      -- T4: addr 1 (hit, upper half of addr-0 line)
      do_cache_read(1, "T4");
      assert read_data = x"BEEF0000" report "TEST_FAIL T4" severity failure;
      assert ddr_req_count = 4 report "TEST_FAIL T4: upper-half hit issued DDR reads" severity failure;

      -- T5: first access to address 8 fills a new line.
      do_cache_read(8, "T5_miss");
      assert read_data = x"12340008" report "TEST_FAIL T5: miss data mismatch" severity failure;
      assert ddr_req_count = 6 report "TEST_FAIL T5: new line should fetch both dwords" severity failure;

      -- T6: repeat address 8 and require a cache hit.
      do_cache_read(8, "T6_repeat");
      assert read_data = x"12340008" report "TEST_FAIL T6: cached read data mismatch" severity failure;
      assert ddr_req_count = 6 report "TEST_FAIL T6: repeated hit issued DDR reads" severity failure;

      -- T7: a one-cycle hit request must retain the synchronous BRAM result
      -- through READCACHE_OUT after read_enable has already fallen.
      read_enable <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;
      read_addr <= std_logic_vector(to_unsigned(8, SIZEBASEBITS));
      read_enable <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      assert read_done = '1' report "TEST_FAIL T7: one-cycle hit request missed" severity failure;
      assert read_data = x"12340008" report "TEST_FAIL T7: one-cycle hit data mismatch" severity failure;
      read_enable <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;
      assert read_done = '0' report "TEST_FAIL T7: one-cycle hit done did not clear" severity failure;
      assert ddr_req_count = 6 report "TEST_FAIL T7: one-cycle hit issued DDR reads" severity failure;

      -- T8: keep read_enable asserted across consecutive hit windows. Each
      -- accepted IDLE request must refresh both ways before READCACHE_OUT.
      read_addr <= std_logic_vector(to_unsigned(8, SIZEBASEBITS));
      read_enable <= '1';
      continuous_hit_count := 0;
      for cycle in 0 to 5 loop
         wait until rising_edge(clk);
         wait for 1 ns;
         if read_done = '1' then
            continuous_hit_count := continuous_hit_count + 1;
            assert read_data = x"12340008" report "TEST_FAIL T8: continuous hit data mismatch" severity failure;
         end if;
      end loop;
      read_enable <= '0';
      assert continuous_hit_count = 3 report "TEST_FAIL T8: expected three consecutive hit windows" severity failure;
      assert ddr_req_count = 6 report "TEST_FAIL T8: continuous hits issued DDR reads" severity failure;

      report "ALL TESTS DONE" severity note;
      report "TEST_PASS: tb_cache_dword_timing" severity note;
      finish;
   end process;

  watchdog : process
  begin
    wait for 5 ms;
    assert false report "TEST_FAIL watchdog timeout in tb_cache_dword_timing.vhd" severity failure;
    wait;
  end process;

end architecture;
