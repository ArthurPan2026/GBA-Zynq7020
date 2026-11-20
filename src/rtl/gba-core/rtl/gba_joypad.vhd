--------------------------------------------------------------------------------
-- @file gba_joypad.vhd
-- @module-contract
-- 职责: 按键外设；GBA 按键寄存器与中断检测逻辑，映射物理/PS 控制输入。
-- 上游: 配置管理器合并后的按键位。
-- 下游: IO 寄存器读值和 keypad IRQ。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
-- 设计注意点: 把外部按键映射成 GBA KEYINPUT/KEYCNT 行为；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

use work.pProc_bus_gba.all;
use work.pReg_gba_keypad.all;

entity gba_joypad is
   port 
   (
      clk100     : in    std_logic;  
      gb_bus     : inout proc_bus_gb_type := ((others => 'Z'), (others => 'Z'), (others => 'Z'), 'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
      IRP_Joypad : out   std_logic := '0';
                 
      KeyA       : in std_logic;
      KeyB       : in std_logic;
      KeySelect  : in std_logic;
      KeyStart   : in std_logic;
      KeyRight   : in std_logic;
      KeyLeft    : in std_logic;
      KeyUp      : in std_logic;
      KeyDown    : in std_logic;
      KeyR       : in std_logic;
      KeyL       : in std_logic;
      
      cpu_done   : in std_logic
   );
end entity;

architecture arch of gba_joypad is

   signal REG_KEYINPUT  : std_logic_vector(KEYINPUT.upper downto KEYINPUT.lower) := (others => '0');
   signal REG_KEYCNT    : std_logic_vector(KEYCNT  .upper downto KEYCNT  .lower) := (others => '0');

   signal debug_cnt : integer := 0;
   
   signal Keys    : std_logic_vector(KEYINPUT.upper downto KEYINPUT.lower) := (others => '0');
   signal Keys_1  : std_logic_vector(KEYINPUT.upper downto KEYINPUT.lower) := (others => '0');
   
   signal REG_KEYCNT_1 : std_logic_vector(KEYCNT  .upper downto KEYCNT  .lower) := (others => '0');

begin 

   -- @instance-group: eProcReg_gba 寄存器映射组：同类实例把 GBA MMIO 或 savestate 总线字段解包为本模块内部控制位、回读值和写入脉冲；实例名对应具体寄存器位域。
   iReg_KEYINPUT  : entity work.eProcReg_gba generic map (KEYINPUT) port map  (clk100, gb_bus, REG_KEYINPUT);  
   iReg_KEYCNT    : entity work.eProcReg_gba generic map (KEYCNT  ) port map  (clk100, gb_bus, REG_KEYCNT, REG_KEYCNT);  

   REG_KEYINPUT <= Keys;
   
   -- @process-purpose: 在 clk100 时钟域维护按键外设的寄存器状态，使总线事件、内部状态机和对外输出在同一拍更新。
   -- @process-mechanism: (Keys_1 /= Keys or REG_KEYCNT_1 /= REG_KEYCNT)、(REG_KEYCNT(30) = '1')、(REG_KEYCNT(31) = '1') 作为有效时选择对应处理分支；默认分支清除单拍脉冲并保持寄存器，触发条件满足时在时钟沿锁存 IRP_Joypad、Keys_1、REG_KEYCNT_1、Keys(0)、Keys(1)、Keys(2)，形成下游可采样的同步状态、单拍脉冲或握手响应。
   -- @process-result: 结果是按键比较和 KEYCNT 条件被压成稳定的 IRP_Joypad，IRQ 控制器不需要重新比较按键组合。
   process (clk100)
   begin
      if rising_edge(clk100) then

         IRP_Joypad <= '0';
         
         Keys_1       <= Keys;
         REG_KEYCNT_1 <= REG_KEYCNT;
         
         Keys(0) <= not KeyA; 
         Keys(1) <= not KeyB;
         Keys(2) <= not KeySelect;
         Keys(3) <= not KeyStart;
         Keys(4) <= not KeyRight;
         Keys(5) <= not KeyLeft;
         Keys(6) <= not KeyUp;
         Keys(7) <= not KeyDown;
         Keys(8) <= not KeyR;
         Keys(9) <= not KeyL;
         
         if (Keys_1 /= Keys or REG_KEYCNT_1 /= REG_KEYCNT) then
            if (REG_KEYCNT(30) = '1') then
               if (REG_KEYCNT(31) = '1') then -- logical and
                  if ((not Keys(9 downto 0)) = REG_KEYCNT(25 downto 16)) then
                     IRP_Joypad <= '1';
                  end if;
               else -- logical or
                  if (unsigned((not Keys(9 downto 0)) and REG_KEYCNT(25 downto 16)) /= 0) then
                     IRP_Joypad <= '1';
                  end if;
               end if;
            end if;
         end if;
         
         -- debug only
         --if (cpu_done = '1') then
         --   debug_cnt <= debug_cnt + 1;
         --   
         --   if (debug_cnt =       0) then REG_KEYINPUT(3) <= '1'; end if;
         --   if (debug_cnt = 3000000) then REG_KEYINPUT(3) <= '0'; end if;
         --   if (debug_cnt = 3100000) then REG_KEYINPUT(3) <= '1'; end if;
         --   if (debug_cnt = 4000000) then REG_KEYINPUT(3) <= '0'; end if;
         --   
         --end if;

      
      end if;
   end process; 
    

end architecture;





