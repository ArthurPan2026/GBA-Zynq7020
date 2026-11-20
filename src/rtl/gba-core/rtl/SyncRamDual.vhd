--------------------------------------------------------------------------------
-- @file SyncRamDual.vhd
-- @module-contract
-- 职责: 双口 RAM；双口同步 RAM 基础模块，为 GBA 内部存储提供并行访问端口。
-- 上游: core 内部存储读写端口。
-- 下游: Vivado BRAM/LUTRAM 推断。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
-- 设计注意点: 给 VRAM/OAM/palette/缓存类结构提供双口同步存储；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library xpm;
use xpm.vcomponents.all;

entity SyncRamDual is
   generic 
   (
      DATA_WIDTH : natural := 8;
      ADDR_WIDTH : natural := 6;
      -- 资源策略开关：
      -- "block"       -> 强制优先使用 BRAM（减少 LUT/LUTRAM 占用）
      -- "distributed" -> 强制分布式 RAM（仅在超小容量且 BRAM 紧张时考虑）
      -- "auto"        -> 交给综合器（不同版本/上下文结果可能波动）
      MEMORY_PRIMITIVE : string := "auto";
      -- "auto" preserves the primitive-dependent policy. Explicit values
      -- select the same-port read-during-write behavior for this instance.
      WRITE_MODE : string := "auto"
   );
   port 
   (
      clk        : in std_logic;
      
      addr_a     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain_a   : in std_logic_vector((DATA_WIDTH-1) downto 0);
      dataout_a  : out std_logic_vector((DATA_WIDTH -1) downto 0);
      we_a       : in std_logic := '1';
      re_a       : in std_logic := '1';
                 
      addr_b     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain_b   : in std_logic_vector((DATA_WIDTH-1) downto 0);
      dataout_b  : out std_logic_vector((DATA_WIDTH -1) downto 0);
      we_b       : in std_logic := '1';
      re_b       : in std_logic := '1'
   );
end;

architecture rtl of SyncRamDual is
   function get_write_mode(prim : string; requested : string) return string is
   begin
      if requested = "read_first" or requested = "write_first" or requested = "no_change" then
         return requested;
      end if;
      -- The behavioral implementation mirrors the original signal-array
      -- process, whose synchronous read observes the pre-write value.
      if prim = "behavioral" or prim = "distributed" or prim = "auto" then
         return "read_first";
      end if;
      return "write_first";
   end function;

   signal addra_slv : std_logic_vector(ADDR_WIDTH-1 downto 0);
   signal addrb_slv : std_logic_vector(ADDR_WIDTH-1 downto 0);
   signal ena       : std_logic;
   signal enb       : std_logic;
   signal wea       : std_logic_vector(0 downto 0);
   signal web       : std_logic_vector(0 downto 0);
   constant WRITE_MODE_SEL : string := get_write_mode(MEMORY_PRIMITIVE, WRITE_MODE);

begin

   addra_slv <= std_logic_vector(to_unsigned(addr_a, ADDR_WIDTH));
   addrb_slv <= std_logic_vector(to_unsigned(addr_b, ADDR_WIDTH));
   ena       <= we_a or re_a;
   enb       <= we_b or re_b;
   wea(0)    <= we_a;
   web(0)    <= we_b;

   GEN_XPM : if MEMORY_PRIMITIVE /= "behavioral" generate
   begin
   i_tdpram : xpm_memory_tdpram
   generic map (
      ADDR_WIDTH_A           => ADDR_WIDTH,
      ADDR_WIDTH_B           => ADDR_WIDTH,
      AUTO_SLEEP_TIME        => 0,
      BYTE_WRITE_WIDTH_A     => DATA_WIDTH,
      BYTE_WRITE_WIDTH_B     => DATA_WIDTH,
      CASCADE_HEIGHT         => 0,
      CLOCKING_MODE          => "common_clock",
      ECC_MODE               => "no_ecc",
      MEMORY_INIT_FILE       => "none",
      MEMORY_INIT_PARAM      => "",
      MEMORY_OPTIMIZATION    => "true",
      MEMORY_PRIMITIVE       => MEMORY_PRIMITIVE,
      MEMORY_SIZE            => DATA_WIDTH * (2 ** ADDR_WIDTH),
      MESSAGE_CONTROL        => 0,
      READ_DATA_WIDTH_A      => DATA_WIDTH,
      READ_DATA_WIDTH_B      => DATA_WIDTH,
      READ_LATENCY_A         => 1,
      READ_LATENCY_B         => 1,
      READ_RESET_VALUE_A     => "0",
      READ_RESET_VALUE_B     => "0",
      RST_MODE_A             => "SYNC",
      RST_MODE_B             => "SYNC",
      SIM_ASSERT_CHK         => 0,
      USE_EMBEDDED_CONSTRAINT=> 0,
      USE_MEM_INIT           => 1,
      WAKEUP_TIME            => "disable_sleep",
      WRITE_DATA_WIDTH_A     => DATA_WIDTH,
      WRITE_DATA_WIDTH_B     => DATA_WIDTH,
      WRITE_MODE_A           => WRITE_MODE_SEL,
      WRITE_MODE_B           => WRITE_MODE_SEL
   )
   port map (
      addra          => addra_slv,
      addrb          => addrb_slv,
      clka           => clk,
      clkb           => clk,
      dina           => datain_a,
      dinb           => datain_b,
      douta          => dataout_a,
      doutb          => dataout_b,
      ena            => ena,
      enb            => enb,
      injectdbiterra => '0',
      injectdbiterrb => '0',
      injectsbiterra => '0',
      injectsbiterrb => '0',
      regcea         => re_a,
      regceb         => re_b,
      rsta           => '0',
      rstb           => '0',
      sleep          => '0',
      wea            => wea,
      web            => web,
      dbiterra       => open,
      dbiterrb       => open,
      sbiterra       => open,
      sbiterrb       => open
   );

   end generate GEN_XPM;

   -- Explicit behavioral mapping retains deterministic two-port collision
   -- behavior: both reads see the pre-edge word and port B wins overlapping
   -- simultaneous writes because its assignment follows port A.
   GEN_BEHAVIORAL : if MEMORY_PRIMITIVE = "behavioral" generate
      subtype word_t is std_logic_vector(DATA_WIDTH-1 downto 0);
      type memory_t is array (0 to (2**ADDR_WIDTH)-1) of word_t;
      signal ram : memory_t;
   begin
      process(clk)
         variable old_a : word_t;
         variable old_b : word_t;
      begin
         if rising_edge(clk) then
            old_a := ram(addr_a);
            old_b := ram(addr_b);

            if we_a = '1' then
               ram(addr_a) <= datain_a;
            end if;
            if we_b = '1' then
               ram(addr_b) <= datain_b;
            end if;

            if re_a = '1' then
               if we_a = '1' and WRITE_MODE_SEL = "write_first" then
                  dataout_a <= datain_a;
               elsif we_a = '1' and WRITE_MODE_SEL = "no_change" then
                  null;
               else
                  dataout_a <= old_a;
               end if;
            end if;
            if re_b = '1' then
               if we_b = '1' and WRITE_MODE_SEL = "write_first" then
                  dataout_b <= datain_b;
               elsif we_b = '1' and WRITE_MODE_SEL = "no_change" then
                  null;
               else
                  dataout_b <= old_b;
               end if;
            end if;
         end if;
      end process;
   end generate GEN_BEHAVIORAL;

end rtl;
