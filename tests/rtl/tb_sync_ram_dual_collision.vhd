library ieee;
library mem;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_sync_ram_dual_collision is
end entity;

architecture sim of tb_sync_ram_dual_collision is
  constant CLK_PERIOD : time := 10 ns;
  signal clk : std_logic := '0';

  signal r_addr_a, r_addr_b : natural range 0 to 3 := 0;
  signal r_din_a, r_din_b : std_logic_vector(7 downto 0) := (others => '0');
  signal r_dout_a, r_dout_b : std_logic_vector(7 downto 0);
  signal r_we_a, r_we_b, r_re_a, r_re_b : std_logic := '0';

  signal w_addr_a, w_addr_b : natural range 0 to 3 := 0;
  signal w_din_a, w_din_b : std_logic_vector(7 downto 0) := (others => '0');
  signal w_dout_a, w_dout_b : std_logic_vector(7 downto 0);
  signal w_we_a, w_we_b, w_re_a, w_re_b : std_logic := '0';
begin
  clk <= not clk after CLK_PERIOD / 2;

  u_read_first : entity mem.SyncRamDual
    generic map (
      DATA_WIDTH => 8,
      ADDR_WIDTH => 2,
      MEMORY_PRIMITIVE => "behavioral",
      WRITE_MODE => "read_first"
    )
    port map (
      clk => clk,
      addr_a => r_addr_a, datain_a => r_din_a, dataout_a => r_dout_a,
      we_a => r_we_a, re_a => r_re_a,
      addr_b => r_addr_b, datain_b => r_din_b, dataout_b => r_dout_b,
      we_b => r_we_b, re_b => r_re_b
    );

  u_write_first : entity mem.SyncRamDual
    generic map (
      DATA_WIDTH => 8,
      ADDR_WIDTH => 2,
      MEMORY_PRIMITIVE => "behavioral",
      WRITE_MODE => "write_first"
    )
    port map (
      clk => clk,
      addr_a => w_addr_a, datain_a => w_din_a, dataout_a => w_dout_a,
      we_a => w_we_a, re_a => w_re_a,
      addr_b => w_addr_b, datain_b => w_din_b, dataout_b => w_dout_b,
      we_b => w_we_b, re_b => w_re_b
    );

  process
  begin
    -- Initialize the same locations on both independent RAM instances.
    wait until falling_edge(clk);
    r_addr_a <= 1; r_din_a <= x"12"; r_we_a <= '1';
    w_addr_a <= 2; w_din_a <= x"34"; w_we_a <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    r_we_a <= '0'; w_we_a <= '0';

    -- Same-address simultaneous writes are deterministic in behavioral mode:
    -- both reads observe the old word and port B wins the stored word.
    wait until falling_edge(clk);
    r_addr_a <= 1; r_addr_b <= 1;
    r_din_a <= x"AA"; r_din_b <= x"BB";
    r_we_a <= '1'; r_we_b <= '1'; r_re_a <= '1'; r_re_b <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    assert r_dout_a = x"12" and r_dout_b = x"12"
      report "read_first collision did not return the old word" severity failure;
    r_we_a <= '0'; r_we_b <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    assert r_dout_a = x"BB" and r_dout_b = x"BB"
      report "port B did not win an overlapping same-address write" severity failure;

    -- A separate instance keeps write_first semantics for the same port, while
    -- the other port still observes the pre-edge word during a cross-port write.
    wait until falling_edge(clk);
    w_addr_a <= 2; w_addr_b <= 2;
    w_din_a <= x"A5"; w_we_a <= '1'; w_re_a <= '1'; w_re_b <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    assert w_dout_a = x"A5" and w_dout_b = x"34"
      report "per-instance write_first/cross-port read semantics changed" severity failure;

    report "TEST_PASS: tb_sync_ram_dual_collision" severity note;
    finish;
    wait;
  end process;
  watchdog : process
  begin
    wait for 1 us;
    assert false report "TEST_FAIL watchdog timeout: tb_sync_ram_dual_collision" severity failure;
    wait;
  end process;
end architecture;
