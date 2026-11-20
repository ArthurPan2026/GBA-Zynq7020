--------------------------------------------------------------------------------
-- @file SyncRamDualNotPow2.vhd
-- @module-contract
-- 职责: 双口 RAM；非 2 的幂深度双口 RAM 封装，对超界地址进行保护性屏蔽。
-- 上游: core 内部存储读写端口。
-- 下游: Vivado BRAM/LUTRAM 推断。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
-- 设计注意点: 给 VRAM/OAM/palette/缓存类结构提供双口同步存储；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity SyncRamDualNotPow2 is
   generic 
   (
      DATA_WIDTH : natural;
      DATA_COUNT : natural
   );
   port 
   (
      clk        : in std_logic;
      
      addr_a     : in natural range 0 to DATA_COUNT - 1;
      datain_a   : in std_logic_vector((DATA_WIDTH-1) downto 0);
      dataout_a  : out std_logic_vector((DATA_WIDTH -1) downto 0);
      we_a       : in std_logic := '1';
      re_a       : in std_logic := '1';
                 
      addr_b     : in natural range 0 to DATA_COUNT - 1;
      datain_b   : in std_logic_vector((DATA_WIDTH-1) downto 0);
      dataout_b  : out std_logic_vector((DATA_WIDTH -1) downto 0);
      we_b       : in std_logic := '1';
      re_b       : in std_logic := '1'
   );
end;

architecture rtl of SyncRamDualNotPow2 is

   -- Build a 2-D array type for the RAM
   subtype word_t is std_logic_vector((DATA_WIDTH-1) downto 0);
   type memory_t is array(0 to DATA_COUNT-1) of word_t;

   -- Declare the RAM 
   signal ram : memory_t := (others => (others => '0'));

begin

   -- Port A
   -- @process-purpose: 在 clk 时钟域维护双口 RAM的寄存器状态，使总线事件、内部状态机和对外输出在同一拍更新。
   -- @process-mechanism: (re_a = '1')、(re_b = '1') 作为有效时选择对应处理分支；默认分支清除单拍脉冲并保持寄存器，触发条件满足时在时钟沿锁存 ram(addr_a)、dataout_a、ram(addr_b)、dataout_b，形成下游可采样的同步状态、单拍脉冲或握手响应。
   -- @process-result: 结果是 ram(addr_a)、dataout_a、ram(addr_b)、dataout_b 等信号只在明确时钟沿变化，下游可以把它们视为同步有效的控制或数据边界。
   process(clk)
   begin
      if(rising_edge(clk)) then 
   
         if(we_a = '1') then
            ram(addr_a) <= datain_a;
         end if;
         if (re_a = '1') then
            dataout_a <= ram(addr_a);
         end if;
   
         if(we_b = '1') then
            ram(addr_b) <= datain_b;
         end if;
         if (re_b = '1') then
            dataout_b <= ram(addr_b);
         end if;
         
      end if;
   end process;

end rtl;
