--------------------------------------------------------------------------------
-- @file reggba_system.vhd
-- @module-contract
-- 职责: 寄存器映射包；GBA 系统控制/中断/等待状态寄存器声明集合。
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

package pReg_gba_system is

   -- range 0x200 .. 0x800
   --   (                             adr      upper    lower    size   default   accesstype)                                     
   constant IRP_IE  : regmap_type := (16#200#,  15,      0,        1,        0,   readwrite); -- Interrupt Enable Register
   constant IRP_IF  : regmap_type := (16#200#,  31,     16,        1,        0,   readwrite); -- Interrupt Request Flags / IRQ Acknowledge  
   
   constant WAITCNT : regmap_type := (16#204#,  14,      0,        1,        0,   readwrite); -- Game Pak Waitstate Control  
   constant ISCGB   : regmap_type := (16#204#,  15,     15,        1,        0,   readwrite); -- is CGB = 1, GBA = 0

   constant IME     : regmap_type := (16#208#,  31,      0,        1,        0,   readwrite); -- Interrupt Master Enable Register  
   
   constant POSTFLG : regmap_type := (16#300#,   7,      0,        1,        0,   readwrite); -- Undocumented - Post Boot Flag  
   constant HALTCNT : regmap_type := (16#300#,  15,      8,        1,        0,   writeonly); -- Undocumented - Power Down Control

 --constant ?       : regmap_type := (16#410#,  15,      0,        1,        0,   readwrite); -- Undocumented - Purpose Unknown / Bug ??? 0FFh  
 
   constant MemCtrl : regmap_type := (16#800#,  31,      0,        1,        0,   readwrite); -- Undocumented - Internal Memory Control (R/W) -- Mirrors of 4000800h (repeated each 64K) 
      
   
end package;