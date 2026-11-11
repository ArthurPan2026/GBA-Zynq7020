library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

library work;
use work.pProc_bus_gba.all;

entity tb_comprehensive_ddr is
end entity;

architecture sim of tb_comprehensive_ddr is
   constant CLK_PERIOD : time := 10 ns;

   -- Simulation control
   signal clk     : std_logic := '0';
   signal rst_n   : std_logic := '0';
   signal gb_on   : std_logic := '0';
   signal sim_done: std_logic := '0';

   -- ============================================================
   -- DDRAM interface between ddram_mux and ddr_axi_backend
   -- ============================================================
   signal DDRAM_BUSY       : std_logic;
   signal DDRAM_BURSTCNT   : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR       : std_logic_vector(28 downto 0);
   signal DDRAM_DOUT       : std_logic_vector(63 downto 0);
   signal DDRAM_DOUT_READY : std_logic;
   signal DDRAM_DONE       : std_logic;
   signal DDRAM_RD         : std_logic;
   signal DDRAM_DIN        : std_logic_vector(63 downto 0);
   signal DDRAM_BE         : std_logic_vector(7 downto 0);
   signal DDRAM_WE         : std_logic;
   signal CFG_ROM_DDR_SAFE : std_logic := '0';

   -- ============================================================
   -- AXI4 interface
   -- ============================================================
   signal M_AXI_AWADDR  : std_logic_vector(31 downto 0);
   signal M_AXI_AWLEN   : std_logic_vector(7 downto 0);
   signal M_AXI_AWSIZE  : std_logic_vector(2 downto 0);
   signal M_AXI_AWBURST : std_logic_vector(1 downto 0);
   signal M_AXI_AWVALID : std_logic;
   signal M_AXI_AWREADY : std_logic := '0';
   signal M_AXI_WDATA   : std_logic_vector(63 downto 0);
   signal M_AXI_WSTRB   : std_logic_vector(7 downto 0);
   signal M_AXI_WLAST   : std_logic;
   signal M_AXI_WVALID  : std_logic;
   signal M_AXI_WREADY  : std_logic := '0';
   signal M_AXI_BRESP   : std_logic_vector(1 downto 0) := "00";
   signal M_AXI_BVALID  : std_logic := '0';
   signal M_AXI_BREADY  : std_logic;
   signal M_AXI_ARADDR  : std_logic_vector(31 downto 0);
   signal M_AXI_ARLEN   : std_logic_vector(7 downto 0);
   signal M_AXI_ARSIZE  : std_logic_vector(2 downto 0);
   signal M_AXI_ARBURST : std_logic_vector(1 downto 0);
   signal M_AXI_ARVALID : std_logic;
   signal M_AXI_ARREADY : std_logic;
   signal M_AXI_RDATA   : std_logic_vector(63 downto 0);
   signal M_AXI_RRESP   : std_logic_vector(1 downto 0);
   signal M_AXI_RLAST   : std_logic;
   signal M_AXI_RVALID  : std_logic;
   signal M_AXI_RREADY  : std_logic;
   signal ERR_VEC       : std_logic_vector(31 downto 0);
   signal ERR_PULSE     : std_logic;
   signal FATAL_FAULT   : std_logic;
   signal MEM_CMD_VALID : std_logic := '0';
   signal MEM_CMD_PAYLOAD : std_logic_vector(63 downto 0) := (others => '0');
   signal MEM_CMD_READY : std_logic;
   signal MEM_ACCEPT_NEW : std_logic;
   signal MEM_STATUS : std_logic_vector(4 downto 0);
   signal MEM_ERROR : std_logic_vector(3 downto 0);
   signal MEM_ERROR_ADDR : std_logic_vector(27 downto 0);
   signal ROM_EPOCH : std_logic_vector(31 downto 0);

   -- ============================================================
   -- ddram_mux ports
   -- ============================================================
   signal ch1_addr     : std_logic_vector(27 downto 1);
   signal ch1_dout     : std_logic_vector(63 downto 0);
   signal ch1_din      : std_logic_vector(15 downto 0) := (others => '0');
   signal ch1_req      : std_logic;
   signal ch1_rnw      : std_logic := '1';
   signal ch1_ready    : std_logic;

   signal ch2_addr     : std_logic_vector(27 downto 1) := (others => '0');
   signal ch2_dout     : std_logic_vector(31 downto 0);
   signal ch2_din      : std_logic_vector(31 downto 0) := (others => '0');
   signal ch2_req      : std_logic := '0';
   signal ch2_rnw      : std_logic := '1';
   signal ch2_ready    : std_logic;

   signal ch3_addr     : std_logic_vector(25 downto 1) := (others => '0');
   signal ch3_dout     : std_logic_vector(15 downto 0);
   signal ch3_din      : std_logic_vector(15 downto 0) := (others => '0');
   signal ch3_req      : std_logic := '0';
   signal ch3_rnw      : std_logic := '1';
   signal ch3_ready    : std_logic;

   signal ch4_addr     : std_logic_vector(27 downto 1) := (others => '0');
   signal ch4_dout     : std_logic_vector(63 downto 0);
   signal ch4_din      : std_logic_vector(63 downto 0) := (others => '0');
   signal ch4_req      : std_logic := '0';
   signal ch4_rnw      : std_logic := '1';
   signal ch4_be       : std_logic_vector(7 downto 0) := (others => '0');
   signal ch4_ready    : std_logic;

   signal ch5_addr     : std_logic_vector(27 downto 1) := (others => '0');
   signal ch5_dout     : std_logic_vector(63 downto 0);
   signal ch5_din      : std_logic_vector(63 downto 0) := (others => '0');
   signal ch5_req      : std_logic := '0';
   signal ch5_rnw      : std_logic := '1';
   signal ch5_ready    : std_logic;

   -- ============================================================
   -- memorymux signals
   -- ============================================================
   signal savestate_bus : proc_bus_gb_type := (
      Din => (others => '0'),  Dout => (others => '0'),
      Adr => (others => '0'),  rnw => '0',
      ena => '0',  done => '0',
      acc => (others => '0'),  bEna => (others => '0'),
      rst => '0'
   );

   signal sdram_read_ena     : std_logic;
   signal sdram_read_done    : std_logic := '0';
   signal sdram_read_addr    : std_logic_vector(24 downto 0);
   signal sdram_read_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_second_dword : std_logic_vector(31 downto 0) := (others => '0');

   signal bus_out_Din  : std_logic_vector(31 downto 0);
   signal bus_out_Dout : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_out_Adr  : std_logic_vector(25 downto 0);
   signal bus_out_rnw  : std_logic;
   signal bus_out_ena  : std_logic;
   signal bus_out_done : std_logic := '0';

   signal gb_bus_out : proc_bus_gb_type := (
      Din => (others => '0'),  Dout => (others => '0'),
      Adr => (others => '0'),  rnw => '0',
      ena => '0',  done => '1',
      acc => (others => '0'),  bEna => (others => '0'),
      rst => '0'
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
   signal dma_soon    : std_logic := '0';
   signal settle      : std_logic;

   signal save_eeprom : std_logic;  signal save_sram  : std_logic;
   signal save_flash  : std_logic;

   signal new_cycles       : unsigned(7 downto 0) := (others => '0');
   signal new_cycles_valid : std_logic := '0';

   signal PC_in_BIOS      : std_logic := '0';
   signal lastread        : std_logic_vector(31 downto 0) := (others => '0');
   signal lastread_dma    : std_logic_vector(31 downto 0) := (others => '0');
   signal last_access_dma : std_logic := '0';
   signal dma_eepromcount : unsigned(16 downto 0) := (others => '0');
   signal flash_1m        : std_logic := '0';
   signal MaxPakAddr      : std_logic_vector(24 downto 0) := (others => '1');
   signal SramFlashEnable : std_logic := '1';
   signal Sram32KMirrorTest : std_logic := '0';
   signal memory_remap    : std_logic := '0';
   signal bitmapdrawmode  : std_logic := '0';

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
   signal vram_cycle      : std_logic;

   signal OAMRAM_PROC_addr    : integer range 0 to 255;
   signal OAMRAM_PROC_datain  : std_logic_vector(31 downto 0);
   signal OAMRAM_PROC_dataout : std_logic_vector(31 downto 0) := (others => '0');
   signal OAMRAM_PROC_we      : std_logic_vector(3 downto 0);

   signal PALETTE_BG_addr    : integer range 0 to 128;
   signal PALETTE_BG_datain  : std_logic_vector(31 downto 0);
   signal PALETTE_BG_dataout : std_logic_vector(31 downto 0) := (others => '0');
   signal PALETTE_BG_we      : std_logic_vector(3 downto 0);
   signal PALETTE_OAM_addr   : integer range 0 to 128;
   signal PALETTE_OAM_datain  : std_logic_vector(31 downto 0);
   signal PALETTE_OAM_dataout : std_logic_vector(31 downto 0) := (others => '0');
   signal PALETTE_OAM_we      : std_logic_vector(3 downto 0);

   signal specialmodule : std_logic := '0';
   signal GPIO_readEna  : std_logic;   signal GPIO_done : std_logic := '0';
   signal GPIO_Din      : std_logic_vector(3 downto 0) := (others => '0');
   signal GPIO_Dout     : std_logic_vector(3 downto 0);
   signal GPIO_writeEna : std_logic;   signal GPIO_addr : std_logic_vector(1 downto 0);
   signal tilt          : std_logic := '0';
   signal AnalogTiltX   : signed(7 downto 0) := (others => '0');
   signal AnalogTiltY   : signed(7 downto 0) := (others => '0');
   signal debug_mem     : std_logic_vector(31 downto 0);

   -- ============================================================
   -- AXI memory model
   -- ============================================================
   constant AXI_MEM_DEPTH : natural := 8192;
   type axi_mem_t is array (0 to AXI_MEM_DEPTH - 1) of std_logic_vector(63 downto 0);

   impure function init_axi_mem return axi_mem_t is
      variable mem : axi_mem_t;
   begin
      for i in mem'range loop
         -- Data pattern: each 64-bit line encodes its index
         -- upper 32 = 0xDCBAiiii, lower 32 = 0xABCDiiii (where iiii = index[15:0])
         mem(i) := x"DCBA" & std_logic_vector(to_unsigned(i mod 65536, 16)) &
                   x"ABCD" & std_logic_vector(to_unsigned(i mod 65536, 16));
      end loop;
      return mem;
   end function;

   signal axi_mem : axi_mem_t := init_axi_mem;

   -- AXI read pipeline
   constant AXI_RD_LATENCY : natural := 4;
   signal rd_pipe_addr     : std_logic_vector(31 downto 0) := (others => '0');
   signal rd_pipe_len      : unsigned(7 downto 0) := (others => '0');
   signal rd_pipe_valid    : std_logic := '0';
   signal rd_pipe_beat     : unsigned(7 downto 0) := (others => '0');
   signal rd_pipe_active   : std_logic := '0';
   type rd_lat_t is array (0 to AXI_RD_LATENCY) of std_logic;
   signal rd_lat_pipe      : rd_lat_t := (others => '0');

   -- Error injection
   signal inject_axi_stall : std_logic := '0';

   -- dword pipeline for memorymux
   signal dout_upper_pipe  : std_logic_vector(31 downto 0) := (others => '0');

   signal pass_count  : integer := 0;
   signal fail_count  : integer := 0;

   -- ============================================================
   -- ddram_mux component declaration (SV module)
   -- ============================================================
   component ddram_mux is
      port (
         DDRAM_CLK        : in  std_logic;
         rst_n            : in  std_logic;
         DDRAM_BUSY       : in  std_logic;
         DDRAM_BURSTCNT   : out std_logic_vector(7 downto 0);
         DDRAM_ADDR       : out std_logic_vector(28 downto 0);
         DDRAM_DOUT       : in  std_logic_vector(63 downto 0);
         DDRAM_DOUT_READY : in  std_logic;
         DDRAM_DONE       : in  std_logic;
         DDRAM_RD         : out std_logic;
         DDRAM_DIN        : out std_logic_vector(63 downto 0);
         DDRAM_BE         : out std_logic_vector(7 downto 0);
         DDRAM_WE         : out std_logic;
         CFG_ROM_DDR_SAFE : in  std_logic;
         MEM_CMD_VALID    : in  std_logic;
         MEM_CMD_PAYLOAD  : in  std_logic_vector(63 downto 0);
         MEM_CMD_ACK_ENABLE : in std_logic;
         MEM_CMD_READY    : out std_logic;
         MEM_ACCEPT_NEW   : out std_logic;
         ch4_write_done   : out std_logic;
         DDRAM_ERR_PULSE  : in  std_logic;
         DDRAM_ERR_VEC    : in  std_logic_vector(31 downto 0);
         DDRAM_FATAL_FAULT: in  std_logic;
         MEM_STATUS       : out std_logic_vector(4 downto 0);
         MEM_ERROR        : out std_logic_vector(3 downto 0);
         MEM_ERROR_ADDR   : out std_logic_vector(27 downto 0);
         ROM_EPOCH        : out std_logic_vector(31 downto 0);
         ch1_addr         : in  std_logic_vector(27 downto 1);
         ch1_dout         : out std_logic_vector(63 downto 0);
         ch1_din          : in  std_logic_vector(15 downto 0);
         ch1_req          : in  std_logic;
         ch1_rnw          : in  std_logic;
         ch1_ready        : out std_logic;
         ch2_addr         : in  std_logic_vector(27 downto 1);
         ch2_dout         : out std_logic_vector(31 downto 0);
         ch2_din          : in  std_logic_vector(31 downto 0);
         ch2_req          : in  std_logic;
         ch2_rnw          : in  std_logic;
         ch2_ready        : out std_logic;
         ch3_addr         : in  std_logic_vector(25 downto 1);
         ch3_dout         : out std_logic_vector(15 downto 0);
         ch3_din          : in  std_logic_vector(15 downto 0);
         ch3_req          : in  std_logic;
         ch3_rnw          : in  std_logic;
         ch3_ready        : out std_logic;
         ch4_addr         : in  std_logic_vector(27 downto 1);
         ch4_dout         : out std_logic_vector(63 downto 0);
         ch4_din          : in  std_logic_vector(63 downto 0);
         ch4_req          : in  std_logic;
         ch4_rnw          : in  std_logic;
         ch4_be           : in  std_logic_vector(7 downto 0);
         ch4_ready        : out std_logic;
         ch5_addr         : in  std_logic_vector(27 downto 1);
         ch5_dout         : out std_logic_vector(63 downto 0);
         ch5_din          : in  std_logic_vector(63 downto 0);
         ch5_req          : in  std_logic;
         ch5_rnw          : in  std_logic;
         ch5_ready        : out std_logic
      );
   end component;

   -- ============================================================
   -- ddr_axi_backend component declaration (SV module)
   -- ============================================================
   component ddr_axi_backend_sv is
      generic (
         G_DDR_BASE : std_logic_vector(31 downto 0) := x"10000000";
         G_WATCHDOG_LIMIT : std_logic_vector(19 downto 0) := x"186A0";
         G_DRAIN_TIMEOUT : std_logic_vector(19 downto 0) := x"186A0"
      );
      port (
         clk             : in  std_logic;
         rst_n           : in  std_logic;
         DDRAM_BUSY      : out std_logic;
         DDRAM_BURSTCNT  : in  std_logic_vector(7 downto 0);
         DDRAM_ADDR      : in  std_logic_vector(28 downto 0);
         DDRAM_DOUT      : out std_logic_vector(63 downto 0);
         DDRAM_DOUT_READY: out std_logic;
         DDRAM_DONE      : out std_logic;
         DDRAM_RD        : in  std_logic;
         DDRAM_DIN       : in  std_logic_vector(63 downto 0);
         DDRAM_BE        : in  std_logic_vector(7 downto 0);
         DDRAM_WE        : in  std_logic;
         M_AXI_AWADDR    : out std_logic_vector(31 downto 0);
         M_AXI_AWLEN     : out std_logic_vector(7 downto 0);
         M_AXI_AWSIZE    : out std_logic_vector(2 downto 0);
         M_AXI_AWBURST   : out std_logic_vector(1 downto 0);
         M_AXI_AWVALID   : out std_logic;
         M_AXI_AWREADY   : in  std_logic;
         M_AXI_WDATA     : out std_logic_vector(63 downto 0);
         M_AXI_WSTRB     : out std_logic_vector(7 downto 0);
         M_AXI_WLAST     : out std_logic;
         M_AXI_WVALID    : out std_logic;
         M_AXI_WREADY    : in  std_logic;
         M_AXI_BRESP     : in  std_logic_vector(1 downto 0);
         M_AXI_BVALID    : in  std_logic;
         M_AXI_BREADY    : out std_logic;
         M_AXI_ARADDR    : out std_logic_vector(31 downto 0);
         M_AXI_ARLEN     : out std_logic_vector(7 downto 0);
         M_AXI_ARSIZE    : out std_logic_vector(2 downto 0);
         M_AXI_ARBURST   : out std_logic_vector(1 downto 0);
         M_AXI_ARVALID   : out std_logic;
         M_AXI_ARREADY   : in  std_logic;
         M_AXI_RDATA     : in  std_logic_vector(63 downto 0);
         M_AXI_RRESP     : in  std_logic_vector(1 downto 0);
         M_AXI_RLAST     : in  std_logic;
         M_AXI_RVALID    : in  std_logic;
         M_AXI_RREADY    : out std_logic;
         ERR_VEC         : out std_logic_vector(31 downto 0);
         ERR_PULSE       : out std_logic;
         FATAL_FAULT     : out std_logic
      );
   end component;

begin
   clk   <= not clk after CLK_PERIOD/2 when sim_done = '0' else '0';
   rst_n <= '0', '1' after 80 ns;

   -- ============================================================
   -- ddr_axi_backend
   -- ============================================================
   i_axi_backend: ddr_axi_backend_sv
      generic map (
         G_DDR_BASE => x"00000000",
         G_WATCHDOG_LIMIT => x"00010",
         G_DRAIN_TIMEOUT => x"00040"
      )
      port map (
         clk => clk,  rst_n => rst_n,
         DDRAM_BUSY => DDRAM_BUSY,
         DDRAM_BURSTCNT => DDRAM_BURSTCNT,
         DDRAM_ADDR => DDRAM_ADDR,
         DDRAM_DOUT => DDRAM_DOUT,
         DDRAM_DOUT_READY => DDRAM_DOUT_READY,
         DDRAM_DONE => DDRAM_DONE,
         DDRAM_RD => DDRAM_RD,
         DDRAM_DIN => DDRAM_DIN,
         DDRAM_BE => DDRAM_BE,
         DDRAM_WE => DDRAM_WE,
         M_AXI_AWADDR => M_AXI_AWADDR,
         M_AXI_AWLEN => M_AXI_AWLEN,
         M_AXI_AWSIZE => M_AXI_AWSIZE,
         M_AXI_AWBURST => M_AXI_AWBURST,
         M_AXI_AWVALID => M_AXI_AWVALID,
         M_AXI_AWREADY => M_AXI_AWREADY,
         M_AXI_WDATA => M_AXI_WDATA,
         M_AXI_WSTRB => M_AXI_WSTRB,
         M_AXI_WLAST => M_AXI_WLAST,
         M_AXI_WVALID => M_AXI_WVALID,
         M_AXI_WREADY => M_AXI_WREADY,
         M_AXI_BRESP => M_AXI_BRESP,
         M_AXI_BVALID => M_AXI_BVALID,
         M_AXI_BREADY => M_AXI_BREADY,
         M_AXI_ARADDR => M_AXI_ARADDR,
         M_AXI_ARLEN => M_AXI_ARLEN,
         M_AXI_ARSIZE => M_AXI_ARSIZE,
         M_AXI_ARBURST => M_AXI_ARBURST,
         M_AXI_ARVALID => M_AXI_ARVALID,
         M_AXI_ARREADY => M_AXI_ARREADY,
         M_AXI_RDATA => M_AXI_RDATA,
         M_AXI_RRESP => M_AXI_RRESP,
         M_AXI_RLAST => M_AXI_RLAST,
         M_AXI_RVALID => M_AXI_RVALID,
         M_AXI_RREADY => M_AXI_RREADY,
         ERR_VEC => ERR_VEC,
         ERR_PULSE => ERR_PULSE,
         FATAL_FAULT => FATAL_FAULT
      );

   -- ============================================================
   -- ddram_mux
   -- ============================================================
   i_ddram_mux: ddram_mux
      port map (
         DDRAM_CLK => clk,
         rst_n => rst_n,
         DDRAM_BUSY => DDRAM_BUSY,
         DDRAM_BURSTCNT => DDRAM_BURSTCNT,
         DDRAM_ADDR => DDRAM_ADDR,
         DDRAM_DOUT => DDRAM_DOUT,
         DDRAM_DOUT_READY => DDRAM_DOUT_READY,
         DDRAM_DONE => DDRAM_DONE,
         DDRAM_RD => DDRAM_RD,
         DDRAM_DIN => DDRAM_DIN,
         DDRAM_BE => DDRAM_BE,
         DDRAM_WE => DDRAM_WE,
         CFG_ROM_DDR_SAFE => CFG_ROM_DDR_SAFE,
         MEM_CMD_VALID => MEM_CMD_VALID,
         MEM_CMD_PAYLOAD => MEM_CMD_PAYLOAD,
         MEM_CMD_ACK_ENABLE => '1',
         MEM_CMD_READY => MEM_CMD_READY,
         ch4_write_done => open,
         MEM_ACCEPT_NEW => MEM_ACCEPT_NEW,
         DDRAM_ERR_PULSE => ERR_PULSE,
         DDRAM_ERR_VEC => ERR_VEC,
         DDRAM_FATAL_FAULT => FATAL_FAULT,
         MEM_STATUS => MEM_STATUS,
         MEM_ERROR => MEM_ERROR,
         MEM_ERROR_ADDR => MEM_ERROR_ADDR,
         ROM_EPOCH => ROM_EPOCH,
         ch1_addr => ch1_addr,
         ch1_dout => ch1_dout,
         ch1_din  => ch1_din,
         ch1_req  => ch1_req,
         ch1_rnw  => ch1_rnw,
         ch1_ready => ch1_ready,
         ch2_addr => ch2_addr,  ch2_dout => ch2_dout,
         ch2_din  => ch2_din,   ch2_req  => ch2_req,
         ch2_rnw  => ch2_rnw,   ch2_ready => ch2_ready,
         ch3_addr => ch3_addr,  ch3_dout => ch3_dout,
         ch3_din  => ch3_din,   ch3_req  => ch3_req,
         ch3_rnw  => ch3_rnw,   ch3_ready => ch3_ready,
         ch4_addr => ch4_addr,  ch4_dout => ch4_dout,
         ch4_din  => ch4_din,   ch4_req  => ch4_req,
         ch4_rnw  => ch4_rnw,   ch4_be => ch4_be,
         ch4_ready => ch4_ready,
         ch5_addr => ch5_addr,  ch5_dout => ch5_dout,
         ch5_din  => ch5_din,   ch5_req  => ch5_req,
         ch5_rnw  => ch5_rnw,   ch5_ready => ch5_ready
      );

   -- ============================================================
   -- Address/data conversion: memorymux <-> ddram_mux
   -- ch1_addr maps 27:1 from the 25-bit DWORD sdram_read_addr
   -- ============================================================
   ch1_addr <= "00" & sdram_read_addr(24 downto 1) & "0";
   ch1_req  <= sdram_read_ena;
   ch1_rnw  <= '1';  -- always read for gamepak

   -- sdram_read_done = ch1_ready (first beat arrival)
   sdram_read_done <= ch1_ready;

   -- Data extraction with correct dword timing:
   -- sdram_read_data: first dword, valid same cycle as ch1_ready
   -- sdram_second_dword: second dword, valid 1 cycle AFTER ch1_ready
   sdram_read_data <= ch1_dout(31 downto 0);

   process(clk)
   begin
      if rising_edge(clk) then
         if ch1_ready = '1' then
            dout_upper_pipe <= ch1_dout(63 downto 32);
         end if;
      end if;
   end process;
   sdram_second_dword <= dout_upper_pipe;

   -- ============================================================
   -- gba_memorymux
   -- ============================================================
   i_memorymux: entity work.gba_memorymux
      generic map (
         is_simu => '1',
         Softmap_GBA_Gamerom_ADDR => 0,
         Softmap_GBA_WRam_ADDR => 0,
         Softmap_GBA_FLASH_ADDR => 0,
         Softmap_GBA_EEPROM_ADDR => 0
      )
      port map (
         clk100 => clk,  gb_on => gb_on,  reset => '0',
         savestate_bus => savestate_bus,
         sdram_read_ena => sdram_read_ena,
         sdram_read_done => sdram_read_done,
         sdram_read_addr => sdram_read_addr,
         sdram_read_data => sdram_read_data,
         sdram_second_dword => sdram_second_dword,
         bus_out_Din => bus_out_Din,  bus_out_Dout => bus_out_Dout,
         bus_out_Adr => bus_out_Adr,  bus_out_rnw => bus_out_rnw,
         bus_out_ena => bus_out_ena,  bus_out_done => bus_out_done,
         gb_bus_out => gb_bus_out,
         mem_bus_Adr => mem_bus_Adr,  mem_bus_rnw => mem_bus_rnw,
         mem_bus_ena => mem_bus_ena,  mem_bus_acc => mem_bus_acc,
         mem_bus_dout => mem_bus_dout, mem_bus_din => mem_bus_din,
         mem_bus_done => mem_bus_done, mem_bus_unread => mem_bus_unread,
         bios_wraddr => bios_wraddr,  bios_wrdata => bios_wrdata,
         bios_wr => bios_wr,  bus_lowbits => bus_lowbits,
         dma_soon => dma_soon,  settle => settle,
         save_eeprom => save_eeprom,  save_sram => save_sram,
         save_flash => save_flash,
         new_cycles => new_cycles,  new_cycles_valid => new_cycles_valid,
         PC_in_BIOS => PC_in_BIOS,
         lastread => lastread,  lastread_dma => lastread_dma,
         last_access_dma => last_access_dma,
         dma_eepromcount => dma_eepromcount,
         flash_1m => flash_1m,  MaxPakAddr => MaxPakAddr,
         SramFlashEnable => SramFlashEnable,
         memory_remap => memory_remap,
         bitmapdrawmode => bitmapdrawmode,
         VRAM_Lo_addr => VRAM_Lo_addr,  VRAM_Lo_datain => VRAM_Lo_datain,
         VRAM_Lo_dataout => VRAM_Lo_dataout,  VRAM_Lo_we => VRAM_Lo_we,
         VRAM_Lo_be => VRAM_Lo_be,  VRAM_Hi_addr => VRAM_Hi_addr,
         VRAM_Hi_datain => VRAM_Hi_datain,
         VRAM_Hi_dataout => VRAM_Hi_dataout,
         VRAM_Hi_we => VRAM_Hi_we,  VRAM_Hi_be => VRAM_Hi_be,
         vram_blocked => vram_blocked,  vram_cycle => vram_cycle,
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
         GPIO_readEna => GPIO_readEna,  GPIO_done => GPIO_done,
         GPIO_Din => GPIO_Din,  GPIO_Dout => GPIO_Dout,
         GPIO_writeEna => GPIO_writeEna,  GPIO_addr => GPIO_addr,
         tilt => tilt,  AnalogTiltX => AnalogTiltX,
         AnalogTiltY => AnalogTiltY,  debug_mem => debug_mem
      );

   -- ============================================================
   -- AXI4 Read Slave Model
   -- ============================================================
   M_AXI_ARREADY <= '1';  -- always ready to accept addresses

   process(clk)
      variable mem_idx : integer;
   begin
      if rising_edge(clk) then
         if rst_n = '0' then
            rd_pipe_valid  <= '0';
            rd_pipe_active <= '0';
            rd_lat_pipe    <= (others => '0');
            M_AXI_RVALID   <= '0';
            M_AXI_RDATA    <= (others => '0');
            M_AXI_RRESP    <= "00";
            M_AXI_RLAST    <= '0';
         else
            -- Default: deassert RVALID unless regenerated
            M_AXI_RVALID <= '0';

            -- Latch AR request
            rd_lat_pipe(0) <= M_AXI_ARVALID and M_AXI_ARREADY;
            for i in 0 to AXI_RD_LATENCY - 1 loop
               rd_lat_pipe(i+1) <= rd_lat_pipe(i);
            end loop;

            -- Capture AR on handshake
            if M_AXI_ARVALID = '1' and M_AXI_ARREADY = '1' then
               rd_pipe_addr  <= M_AXI_ARADDR;
               rd_pipe_len   <= unsigned(M_AXI_ARLEN);
               rd_pipe_valid <= '1';
            end if;

            -- After latency, start sending beats
            if rd_lat_pipe(AXI_RD_LATENCY) = '1' and rd_pipe_valid = '1' then
               rd_pipe_active <= '1';
               rd_pipe_beat   <= (others => '0');
               rd_pipe_valid  <= '0';
            end if;

            -- Send data beats
            if rd_pipe_active = '1' then
               if inject_axi_stall = '0' or rd_pipe_beat = 0 then
                  mem_idx := to_integer(
                     (unsigned(rd_pipe_addr) + (rd_pipe_beat * 8)) mod AXI_MEM_DEPTH);

                  M_AXI_RVALID <= '1';
                  M_AXI_RDATA  <= axi_mem(mem_idx);
                  M_AXI_RRESP  <= "00";

                  if rd_pipe_beat = rd_pipe_len then
                     M_AXI_RLAST    <= '1';
                     rd_pipe_active <= '0';
                  else
                     M_AXI_RLAST    <= '0';
                     rd_pipe_beat   <= rd_pipe_beat + 1;
                  end if;
               end if;
               -- When inject_axi_stall=1 and beat > 0: drop RVALID (stall mid-burst)
            end if;
         end if;
      end if;
   end process;

   -- ============================================================
   -- Test Sequencer
   -- ============================================================
   stimulus: process
      procedure wait_cycles(n : natural) is
      begin
         for i in 1 to n loop wait for CLK_PERIOD; end loop;
      end procedure;

      -- Expected data: ddr_axi_backend maps sdram_dword*2 to AXI mem index
      -- So expected lower 32 bits = 0xABCD(dword_addr * 2)
      function expected_low32(rom_word_addr : integer) return std_logic_vector is
         variable idx : integer;
      begin
         idx := (rom_word_addr * 2) mod 65536;
         return x"ABCD" & std_logic_vector(to_unsigned(idx, 16));
      end function;

      -- Store recorded cache data for hit verification
      type data_rec_t is array (0 to 63) of std_logic_vector(31 downto 0);
      variable recorded_data : data_rec_t := (others => (others => '0'));
      variable data_valid    : std_logic_vector(63 downto 0) := (others => '0');

      procedure do_rom_read_verify(
         rom_byte_addr : in integer;
         label_str     : in string;
         acc           : in std_logic_vector(1 downto 0) := ACCESS_32BIT
      ) is
         variable result   : std_logic_vector(31 downto 0);
         variable sdram_dw : integer;
         variable expect   : std_logic_vector(31 downto 0);
         variable ok       : boolean;
         variable wait_cnt : integer := 0;
         variable rec_idx  : integer;
      begin
         sdram_dw := rom_byte_addr / 4;
         expect := expected_low32(sdram_dw);

         report "--- " & label_str & ": ROM byte=0x" & to_hstring(
            std_logic_vector(to_unsigned(rom_byte_addr, 32))) &
            " dword=" & integer'image(sdram_dw) & " ---" severity note;

         mem_bus_Adr <= std_logic_vector(to_unsigned(16#08000000# + rom_byte_addr, 32));
         mem_bus_rnw <= '1';
         mem_bus_acc <= acc;
         mem_bus_ena <= '1';
         dma_soon <= '0';

         wait_cnt := 0;
         while mem_bus_done = '0' and wait_cnt < 5000 loop
            wait for CLK_PERIOD;
            wait_cnt := wait_cnt + 1;
         end loop;
         mem_bus_ena <= '0';

         if wait_cnt >= 5000 then
            report "FAIL " & label_str & ": timeout" severity error;
            fail_count <= fail_count + 1;
         else
            result := mem_bus_din;

            if acc = ACCESS_32BIT then
               ok := (result = expect);
            elsif acc = ACCESS_16BIT then
               ok := (result(15 downto 0) = expect(15 downto 0));
            else
               ok := true;
            end if;

            if ok then
               report "PASS " & label_str & " data=0x" & to_hstring(result) severity note;
               pass_count <= pass_count + 1;
            else
               report "FAIL " & label_str & " got=0x" & to_hstring(result) &
                      " expected=0x" & to_hstring(expect) severity error;
               fail_count <= fail_count + 1;
            end if;

            -- Record data for cache hit verification
            rec_idx := sdram_dw;
            if rec_idx < 64 then
               recorded_data(rec_idx) := result;
               data_valid(rec_idx) := '1';
            end if;
         end if;

         wait for CLK_PERIOD * 10;
      end procedure;

      procedure do_rom_read_hit(
         rom_byte_addr : in integer;
         label_str     : in string
      ) is
         variable result   : std_logic_vector(31 downto 0);
         variable sdram_dw : integer;
         variable expect   : std_logic_vector(31 downto 0);
         variable ok       : boolean;
         variable wait_cnt : integer := 0;
         variable rec_idx  : integer;
      begin
         sdram_dw := rom_byte_addr / 4;
         rec_idx  := sdram_dw;

         if rec_idx < 64 and data_valid(rec_idx) = '1' then
            expect := recorded_data(rec_idx);
         else
            expect := expected_low32(sdram_dw);
         end if;

         report "--- " & label_str & ": ROM byte=0x" & to_hstring(
            std_logic_vector(to_unsigned(rom_byte_addr, 32))) &
            " (expect cache hit) ---" severity note;

         mem_bus_Adr <= std_logic_vector(to_unsigned(16#08000000# + rom_byte_addr, 32));
         mem_bus_rnw <= '1';
         mem_bus_acc <= ACCESS_32BIT;
         mem_bus_ena <= '1';

         wait_cnt := 0;
         while mem_bus_done = '0' and wait_cnt < 5000 loop
            wait for CLK_PERIOD;
            wait_cnt := wait_cnt + 1;
         end loop;
         mem_bus_ena <= '0';

         if wait_cnt >= 5000 then
            report "FAIL " & label_str & ": timeout" severity error;
            fail_count <= fail_count + 1;
         else
            result := mem_bus_din;
            ok := (result = expect);
            if ok then
               report "PASS " & label_str & " data=0x" & to_hstring(result) severity note;
               pass_count <= pass_count + 1;
            else
               report "FAIL " & label_str & " got=0x" & to_hstring(result) &
                      " expected=0x" & to_hstring(expect) severity error;
               fail_count <= fail_count + 1;
            end if;
         end if;

         wait for CLK_PERIOD * 10;
      end procedure;

      procedure do_dma_bypass_read(
         rom_byte_addr : in integer;
         label_str     : in string
      ) is
         variable result   : std_logic_vector(31 downto 0);
         variable sdram_dw : integer;
         variable wait_cnt : integer := 0;
         variable rec_idx  : integer;
      begin
         sdram_dw := rom_byte_addr / 4;

         report "--- " & label_str & ": DMA bypass ROM byte=0x" & to_hstring(
            std_logic_vector(to_unsigned(rom_byte_addr, 32))) & " ---" severity note;

         mem_bus_Adr <= std_logic_vector(to_unsigned(16#08000000# + rom_byte_addr, 32));
         mem_bus_rnw <= '1';
         mem_bus_acc <= ACCESS_32BIT;
         mem_bus_ena <= '1';
         dma_soon <= '1';  -- triggers cache_bypass

         wait_cnt := 0;
         while mem_bus_done = '0' and wait_cnt < 5000 loop
            wait for CLK_PERIOD;
            wait_cnt := wait_cnt + 1;
         end loop;
         mem_bus_ena <= '0';
         dma_soon <= '0';

         if wait_cnt >= 5000 then
            report "FAIL " & label_str & ": timeout" severity error;
            fail_count <= fail_count + 1;
         else
            result := mem_bus_din;
            report "PASS " & label_str & " data=0x" & to_hstring(result) severity note;
            pass_count <= pass_count + 1;

            rec_idx := sdram_dw;
            if rec_idx < 64 then
               recorded_data(rec_idx) := result;
               data_valid(rec_idx) := '1';
            end if;
         end if;
         wait for CLK_PERIOD * 10;
      end procedure;

   begin
      report "===== Comprehensive DDR Chain Simulation =====" severity note;
      wait until rst_n = '1';
      wait for CLK_PERIOD * 10;

      -- Initialize: gb_on rising edge triggers cache CLEARCACHE
      gb_on <= '1';
      wait for 50 us;  -- CLEARCACHE ~4096 cycles = ~41us, 50us has margin

      -- ==============================================
      -- T1: Cache miss -> DDR fill (addr 0)
      -- ==============================================
      do_rom_read_verify(16#0000#, "T1_miss_addr0");

      -- ==============================================
      -- T2: Cache hit (same address)
      -- ==============================================
      do_rom_read_hit(16#0000#, "T2_hit_addr0");

      -- ==============================================
      -- T3: Different cache line (addr 0x20)
      -- ==============================================
      do_rom_read_verify(16#0020#, "T3_miss_addr20");

      -- ==============================================
      -- T4: Verify addr 0 still cached
      -- ==============================================
      do_rom_read_hit(16#0000#, "T4_hit_addr0_again");

      -- ==============================================
      -- T5: Verify addr 0x20 still cached
      -- ==============================================
      do_rom_read_hit(16#0020#, "T5_hit_addr20_again");

      -- ==============================================
      -- T6: Sequential reads (prefetch exercise)
      -- ==============================================
      do_rom_read_verify(16#0040#, "T6a_seq_addr40");
      do_rom_read_verify(16#0050#, "T6b_seq_addr50");

      -- ==============================================
      -- T7: DMA bypass (cache_bypass=1, should NOT cache)
      -- ==============================================
      do_dma_bypass_read(16#0080#, "T7_bypass_addr80");

      -- After bypass, addr 0x80 should miss (NOT in cache)
      do_rom_read_verify(16#0080#, "T7b_remiss_addr80");

      -- ==============================================
      -- T7c: Mini-cache coherence test (regression for DMA bypass tag/data mismatch)
      -- Step 1: populate mini-cache with addr 0x00 data via read through SDRAM
      -- Step 2: DMA bypass read of addr 0x20 (should NOT touch mini-cache with fix)
      -- Step 3: 16-bit read of addr 0x00 → mini-cache hits → must return step 1 data
      -- ==============================================
      do_rom_read_verify(16#0000#, "T7c_step1_populate_mcache");
      do_dma_bypass_read(16#0020#, "T7c_step2_dma_bypass");
      -- 16-bit read forces mini-cache hit path (not gamepak cache)
      do_rom_read_verify(16#0000#, "T7c_step3_16bit_mcache_hit", ACCESS_16BIT);

      -- ==============================================
      -- T8: DDR_SAFE mode (burst=1)
      -- ==============================================
      report "--- T8: Enabling DDR_SAFE mode ---" severity note;
      CFG_ROM_DDR_SAFE <= '1';
      wait for CLK_PERIOD * 20;
      do_rom_read_verify(16#00C0#, "T8_safe_mode");

      -- Disable DDR_SAFE for remaining tests
      CFG_ROM_DDR_SAFE <= '0';
      wait for CLK_PERIOD * 20;

      -- ==============================================
      -- AXI timeout, late-response, and recovery behavior are covered by
      -- tb_ddr_axi_backend_fault_drain and tb_ddram_lifecycle. This in-system
      -- scenario changed DDR_SAFE and cleared sequential history before fault
      -- injection, making the next request single-beat rather than stallable.
      -- ==============================================
      -- T10: Post-mode data check
      -- ==============================================
      -- ==============================================
      do_rom_read_verify(16#0120#, "T10_post_mode");

      -- ==============================================
      -- T11: 16-bit read
      -- ==============================================
      report "--- T11: 16-bit access ---" severity note;
      do_rom_read_verify(16#0140#, "T11_16bit", ACCESS_16BIT);

      -- ==============================================
      -- T12: Multiple reads to exercise prefetch pipeline
      -- ==============================================
      for i in 0 to 7 loop
         do_rom_read_verify(16#0200# + i * 16, "T12_seq" & integer'image(i));
      end loop;

      -- ==============================================
      -- Summary
      -- ==============================================
      report " " severity note;
      report "===== SIMULATION COMPLETE =====" severity note;
      report "PASS: " & integer'image(pass_count) severity note;
      report "FAIL: " & integer'image(fail_count) severity note;

      if fail_count > 0 then
         report "*** SOME TESTS FAILED ***" severity failure;
      else
         report "ALL TESTS PASSED" severity note;
         report "TEST_PASS: tb_comprehensive_ddr" severity note;
      end if;

      sim_done <= '1';
      finish;
   end process;


  watchdog : process
  begin
    wait for 20 ms;
    assert false report "TEST_FAIL watchdog timeout in tb_comprehensive_ddr.vhd" severity failure;
    wait;
  end process;

end architecture;
