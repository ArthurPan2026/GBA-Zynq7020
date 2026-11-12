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

  -- XPM mapping comparison for the 3-bit GPU OBJ settings line buffer.
  signal x_addr_a, x_addr_b : natural range 0 to 255 := 0;
  signal x_din_a, x_din_b : std_logic_vector(2 downto 0) := (others => '0');
  signal x_block_dout_a, x_block_dout_b : std_logic_vector(2 downto 0);
  signal x_dist_dout_a, x_dist_dout_b : std_logic_vector(2 downto 0);
  signal x_we_a, x_we_b, x_re_a, x_re_b : std_logic := '0';
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

  u_xpm_block : entity mem.SyncRamDual
    generic map (
      DATA_WIDTH => 3,
      ADDR_WIDTH => 8,
      MEMORY_PRIMITIVE => "block",
      WRITE_MODE => "write_first"
    )
    port map (
      clk => clk,
      addr_a => x_addr_a, datain_a => x_din_a, dataout_a => x_block_dout_a,
      we_a => x_we_a, re_a => x_re_a,
      addr_b => x_addr_b, datain_b => x_din_b, dataout_b => x_block_dout_b,
      we_b => x_we_b, re_b => x_re_b
    );

  u_xpm_distributed : entity mem.SyncRamDual
    generic map (
      DATA_WIDTH => 3,
      ADDR_WIDTH => 8,
      MEMORY_PRIMITIVE => "distributed",
      -- XPM distributed RAM rejects write_first; this is the wrapper default.
      WRITE_MODE => "read_first"
    )
    port map (
      clk => clk,
      addr_a => x_addr_a, datain_a => x_din_a, dataout_a => x_dist_dout_a,
      we_a => x_we_a, re_a => x_re_a,
      addr_b => x_addr_b, datain_b => x_din_b, dataout_b => x_dist_dout_b,
      we_b => x_we_b, re_b => x_re_b
    );

  process
  begin
    -- Initialize both primitive mappings to the same word.
    wait until falling_edge(clk);
    x_addr_a <= 7; x_din_a <= "001"; x_we_a <= '1';
    x_re_a <= '0'; x_re_b <= '0'; x_we_b <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    x_we_a <= '0';
    wait until falling_edge(clk);
    x_addr_b <= 7; x_re_b <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    assert x_block_dout_b = "001" and x_dist_dout_b = "001"
      report "XPM block/distributed initialization read mismatch" severity failure;

    -- Probe the same-tick A-write/B-read collision. Report outputs instead of
    -- asserting equivalence because BRAM write-first collisions are undefined
    -- on 7 Series hardware; the line-buffer merge must ignore this cycle.
    wait until falling_edge(clk);
    x_addr_a <= 7; x_addr_b <= 7; x_din_a <= "101";
    x_we_a <= '1'; x_re_a <= '0'; x_re_b <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    report "XPM A-write/B-read outputs: block=" & to_hstring(x_block_dout_b) &
           " distributed=" & to_hstring(x_dist_dout_b) severity note;
    x_we_a <= '0';

    -- The next non-collision read must return the new word in both mappings.
    wait until rising_edge(clk); wait for 1 ns;
    assert x_block_dout_b = "101" and x_dist_dout_b = "101"
      report "XPM post-write read mismatch" severity failure;

    -- Probe the unsupported dual-write case and report its result. GPU settings
    -- buffers use we_b='0', so this is not a reachable production operation.
    wait until falling_edge(clk);
    x_din_a <= "010"; x_din_b <= "110";
    x_we_a <= '1'; x_we_b <= '1'; x_re_a <= '1'; x_re_b <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    x_we_a <= '0'; x_we_b <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    report "XPM dual-write outputs: block A/B=" & to_hstring(x_block_dout_a) & "/" &
           to_hstring(x_block_dout_b) & " distributed A/B=" &
           to_hstring(x_dist_dout_a) & "/" & to_hstring(x_dist_dout_b) severity note;

    -- Model the safe merge phase: writes finish with B disabled, then B reads.
    wait until falling_edge(clk);
    x_addr_a <= 8; x_addr_b <= 8; x_din_a <= "111";
    x_we_a <= '1'; x_we_b <= '0'; x_re_a <= '0'; x_re_b <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    x_we_a <= '0';
    wait until falling_edge(clk);
    x_re_b <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    assert x_block_dout_b = "111" and x_dist_dout_b = "111"
      report "XPM gated post-draw read mismatch" severity failure;
    report "TEST_PASS: tb_sync_ram_dual_xpm_mapping" severity note;

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
