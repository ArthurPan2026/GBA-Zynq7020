--------------------------------------------------------------------------------
-- @file reggba_keypad.vhd
-- @module-contract
-- 职责: 寄存器映射包；GBA keypad 寄存器声明与地址映射集合。
-- 上游: 各外设模块和 proc_bus。
-- 下游: 编译期寄存器地址/位域常量。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
-- 设计注意点: 集中定义 GBA IO 寄存器地址、位域和默认值；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;

package pReg_gba_keypad is

   -- range 0x130 .. 0x133
   --   (                              adr      upper    lower    size   default   accesstype)                                     
   constant KEYINPUT : regmap_type := (16#130#,  15,       0,        1,        0,   readonly ); -- Key Status            2    R  
   constant KEYCNT   : regmap_type := (16#130#,  31,      16,        1,        0,   readwrite); -- Key Interrupt Control 2    R/W
   
end package;