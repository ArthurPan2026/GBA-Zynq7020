--------------------------------------------------------------------------------
-- @file gba_reservedregs.vhd
-- @module-contract
-- 职责: 保留寄存器占位模块，为未实现或固定响应地址提供稳定读值。
-- 上游: GBA core 内部总线/寄存器/状态信号。
-- 下游: 相邻 CPU/GPU/APU/DMA/memorymux 子系统。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
-- 设计注意点: 承担 MiSTer GBA core 中一个局部硬件职责，并通过内部总线与其它子模块协作；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

use work.pProc_bus_gba.all;

entity gba_reservedregs is
   port 
   (
      clk100  : in    std_logic;  
      gb_bus  : inout proc_bus_gb_type := ((others => 'Z'), (others => 'Z'), (others => 'Z'), 'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z')
   );
end entity;

architecture arch of gba_reservedregs is

   signal addr : unsigned(27 downto 0);
   
begin 

   addr <= unsigned(gb_bus.Adr);

   gb_bus.done <=  '0' when (addr  = 16#58#                   ) else 
                   '0' when (addr  = 16#5C#                   ) else 
                   '0' when (addr  = 16#8C#                   ) else 
                   '0' when (addr  = 16#A8#                   ) else 
                   '0' when (addr  = 16#AC#                   ) else 
                   '0' when (addr >= 16#E0# and addr <= 16#FC#) else
                   'Z';
   
end architecture;





