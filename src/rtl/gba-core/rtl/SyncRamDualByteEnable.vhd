--------------------------------------------------------------------------------
-- @file SyncRamDualByteEnable.vhd
-- @module-contract
-- 职责: 带字节使能 RAM；带字节使能的双口 RAM VHDL 包装层，实例化 SystemVerilog RAM core。
-- 上游: memorymux/GPU/APU 等存储实例。
-- 下游: Vivado BRAM 推断。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
-- 设计注意点: 封装可综合双口 RAM，并支持按字节写入；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity SyncRamDualByteEnable is
   generic 
   (
      is_simu     : std_logic;
      is_cyclone5 : std_logic := '0';
      BYTE_WIDTH  : natural := 8;
      ADDR_WIDTH  : natural := 6;
      BYTES       : natural := 4;
      MEMORY_PRIMITIVE : string := "block";
      WRITE_MODE : string := "write_first"
   );
   port 
   (
      clk        : in std_logic;
      
      addr_a     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain_a0  : in std_logic_vector((BYTE_WIDTH-1) downto 0);
      datain_a1  : in std_logic_vector((BYTE_WIDTH-1) downto 0);
      datain_a2  : in std_logic_vector((BYTE_WIDTH-1) downto 0);
      datain_a3  : in std_logic_vector((BYTE_WIDTH-1) downto 0);
      dataout_a  : out std_logic_vector((BYTES*BYTE_WIDTH-1) downto 0);
      we_a       : in std_logic := '1';
      be_a       : in  std_logic_vector (BYTES - 1 downto 0);
		            
      addr_b     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain_b0  : in std_logic_vector((BYTE_WIDTH-1) downto 0);
      datain_b1  : in std_logic_vector((BYTE_WIDTH-1) downto 0);
      datain_b2  : in std_logic_vector((BYTE_WIDTH-1) downto 0);
      datain_b3  : in std_logic_vector((BYTE_WIDTH-1) downto 0);
      dataout_b  : out std_logic_vector((BYTES*BYTE_WIDTH-1) downto 0);
      we_b       : in std_logic := '1';
      be_b       : in  std_logic_vector (BYTES - 1 downto 0)
   );
end;

architecture rtl of SyncRamDualByteEnable is
   constant DATA_WIDTH : natural := BYTES * BYTE_WIDTH;

   -- Convert public VHDL option strings to the packed byte representation
   -- used by the SystemVerilog XPM adapter (up to eleven ASCII characters).
   function pack_xpm_text(value : string) return std_logic_vector is
      variable packed : std_logic_vector(8*11-1 downto 0) := (others => '0');
      variable char_offset : natural := 0;
      variable byte_index : natural;
   begin
      assert value'length <= 11
         report "XPM option text exceeds eleven characters"
         severity failure;
      if value'length <= 11 then
         for index in value'range loop
            byte_index := value'length - 1 - char_offset;
            packed(byte_index*8+7 downto byte_index*8) :=
               std_logic_vector(to_unsigned(character'pos(value(index)), 8));
            char_offset := char_offset + 1;
         end loop;
      end if;
      return packed;
   end function pack_xpm_text;

   signal addra_slv : std_logic_vector(ADDR_WIDTH - 1 downto 0);
   signal addrb_slv : std_logic_vector(ADDR_WIDTH - 1 downto 0);
   signal dina_slv  : std_logic_vector(DATA_WIDTH - 1 downto 0);
   signal dinb_slv  : std_logic_vector(DATA_WIDTH - 1 downto 0);
   signal douta_slv : std_logic_vector(DATA_WIDTH - 1 downto 0);
   signal doutb_slv : std_logic_vector(DATA_WIDTH - 1 downto 0);

   component SyncRamDualByteEnable_core is
      generic
      (
         BYTE_WIDTH : integer := 8;
         ADDR_WIDTH : integer := 6;
         BYTES      : integer := 4;
         MEMORY_PRIMITIVE : std_logic_vector(8*11-1 downto 0) := (others => '0');
         WRITE_MODE : std_logic_vector(8*11-1 downto 0) := (others => '0')
      );
      port
      (
         clk       : in  std_logic;
         addr_a    : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
         datain_a  : in  std_logic_vector(BYTES * BYTE_WIDTH - 1 downto 0);
         dataout_a : out std_logic_vector(BYTES * BYTE_WIDTH - 1 downto 0);
         we_a      : in  std_logic;
         be_a      : in  std_logic_vector(BYTES - 1 downto 0);
         addr_b    : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
         datain_b  : in  std_logic_vector(BYTES * BYTE_WIDTH - 1 downto 0);
         dataout_b : out std_logic_vector(BYTES * BYTE_WIDTH - 1 downto 0);
         we_b      : in  std_logic;
         be_b      : in  std_logic_vector(BYTES - 1 downto 0)
      );
   end component;
begin

   -- Existing interface exposes four byte lanes, so BYTES must remain 4.
   assert BYTES = 4
      report "SyncRamDualByteEnable supports BYTES=4 only"
      severity failure;

   addra_slv <= std_logic_vector(to_unsigned(addr_a, ADDR_WIDTH));
   addrb_slv <= std_logic_vector(to_unsigned(addr_b, ADDR_WIDTH));

   dina_slv(BYTE_WIDTH * 1 - 1 downto BYTE_WIDTH * 0) <= datain_a0;
   dina_slv(BYTE_WIDTH * 2 - 1 downto BYTE_WIDTH * 1) <= datain_a1;
   dina_slv(BYTE_WIDTH * 3 - 1 downto BYTE_WIDTH * 2) <= datain_a2;
   dina_slv(BYTE_WIDTH * 4 - 1 downto BYTE_WIDTH * 3) <= datain_a3;

   dinb_slv(BYTE_WIDTH * 1 - 1 downto BYTE_WIDTH * 0) <= datain_b0;
   dinb_slv(BYTE_WIDTH * 2 - 1 downto BYTE_WIDTH * 1) <= datain_b1;
   dinb_slv(BYTE_WIDTH * 3 - 1 downto BYTE_WIDTH * 2) <= datain_b2;
   dinb_slv(BYTE_WIDTH * 4 - 1 downto BYTE_WIDTH * 3) <= datain_b3;

   dataout_a <= douta_slv;
   dataout_b <= doutb_slv;

   i_core : SyncRamDualByteEnable_core
   generic map
   (
      BYTE_WIDTH => BYTE_WIDTH,
      ADDR_WIDTH => ADDR_WIDTH,
      BYTES      => BYTES,
      MEMORY_PRIMITIVE => pack_xpm_text(MEMORY_PRIMITIVE),
      WRITE_MODE => pack_xpm_text(WRITE_MODE)
   )
   port map
   (
      clk       => clk,
      addr_a    => addra_slv,
      datain_a  => dina_slv,
      dataout_a => douta_slv,
      we_a      => we_a,
      be_a      => be_a,
      addr_b    => addrb_slv,
      datain_b  => dinb_slv,
      dataout_b => doutb_slv,
      we_b      => we_b,
      be_b      => be_b
   );

end rtl;
