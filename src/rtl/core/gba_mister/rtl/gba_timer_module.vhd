--------------------------------------------------------------------------------
-- @file gba_timer_module.vhd
-- @module-contract
-- 职责: 单路 Timer；单路 GBA 定时器状态机，处理预分频、级联、溢出和重装载。
-- 上游: timer 寄存器、新 CPU 周期和级联输入。
-- 下游: gba_timer 聚合器、IRQ、savestate。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 寄存器写入、new_cycles_valid、count-up 级联和溢出 tick/IRQ 构成定时器协议。
-- 设计注意点: 维护一个 GBA timer 的预分频、计数、溢出和重装；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

use work.pRegmap_gba.all;
use work.pProc_bus_gba.all;
use work.pReg_savestates.all;

entity gba_timer_module is
   generic
   (
      is_simu                : std_logic;
      index                  : integer;
      Reg_L                  : regmap_type;
      Reg_H_Prescaler        : regmap_type;
      Reg_H_Count_up         : regmap_type;
      Reg_H_Timer_IRQ_Enable : regmap_type;
      Reg_H_Timer_Start_Stop : regmap_type
   );
   port 
   (
      clk100              : in    std_logic; 
      gb_on               : in    std_logic;
      reset               : in    std_logic;      
      
      savestate_bus       : inout proc_bus_gb_type;
      loading_savestate   : in    std_logic;
      
      gb_bus              : inout proc_bus_gb_type := ((others => 'Z'), (others => 'Z'), (others => 'Z'), 'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
      
      new_cycles          : in    unsigned(7 downto 0);
      new_cycles_valid    : in    std_logic;
      countup_in          : in    std_logic;
      
      tick                : out   std_logic := '0';
      IRP_Timer           : out   std_logic := '0';
      
      debugout            : out   std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of gba_timer_module is

   signal L_Counter_Reload   : std_logic_vector(Reg_L                 .upper downto Reg_L                 .lower) := (others => '0');
   signal H_Prescaler        : std_logic_vector(Reg_H_Prescaler       .upper downto Reg_H_Prescaler       .lower) := (others => '0');
   signal H_Count_up         : std_logic_vector(Reg_H_Count_up        .upper downto Reg_H_Count_up        .lower) := (others => '0');
   signal H_Timer_IRQ_Enable : std_logic_vector(Reg_H_Timer_IRQ_Enable.upper downto Reg_H_Timer_IRQ_Enable.lower) := (others => '0');
   signal H_Timer_Start_Stop : std_logic_vector(Reg_H_Timer_Start_Stop.upper downto Reg_H_Timer_Start_Stop.lower) := (others => '0');
                                                                                                                                                    
   signal H_Timer_Start_Stop_written : std_logic;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   

   signal counter_readback : std_logic_vector(15 downto 0) := (others => '0');
   signal counter          : unsigned(16 downto 0) := (others => '0');
   signal prescalecounter  : unsigned(10 downto 0) := (others => '0');
   signal prescaleborder   : integer range 1 to 1024 := 1;
   signal timer_on         : std_logic := '0';
   signal timer_on_next    : std_logic := '0';
   
   -- savestate
   signal SAVESTATE_TIMER      : std_logic_vector(29 downto 0);
   signal SAVESTATE_TIMER_BACK : std_logic_vector(29 downto 0);
   
   
begin 

   SAVESTATE_TIMER_BACK(0)            <= timer_on;       
   SAVESTATE_TIMER_BACK(1)            <= timer_on_next;  
   SAVESTATE_TIMER_BACK(18 downto 2)  <= std_logic_vector(counter);        
   SAVESTATE_TIMER_BACK(29 downto 19) <= std_logic_vector(prescalecounter);

   -- @instance-group: eProcReg_gba 寄存器映射组：同类实例把 GBA MMIO 或 savestate 总线字段解包为本模块内部控制位、回读值和写入脉冲；实例名对应具体寄存器位域。
   iSAVESTATE_TIMER : entity work.eProcReg_gba generic map (REG_SAVESTATE_TIMER, index) port map (clk100, savestate_bus, SAVESTATE_TIMER_BACK, SAVESTATE_TIMER);


   iL_Counter_Reload   : entity work.eProcReg_gba generic map ( Reg_L                  ) port map  (clk100, gb_bus, counter_readback   , L_Counter_Reload  );  
   iH_Prescaler        : entity work.eProcReg_gba generic map ( Reg_H_Prescaler        ) port map  (clk100, gb_bus, H_Prescaler        , H_Prescaler       );  
   iH_Count_up         : entity work.eProcReg_gba generic map ( Reg_H_Count_up         ) port map  (clk100, gb_bus, H_Count_up         , H_Count_up        );   
   iH_Timer_IRQ_Enable : entity work.eProcReg_gba generic map ( Reg_H_Timer_IRQ_Enable ) port map  (clk100, gb_bus, H_Timer_IRQ_Enable , H_Timer_IRQ_Enable);  
   iH_Timer_Start_Stop : entity work.eProcReg_gba generic map ( Reg_H_Timer_Start_Stop ) port map  (clk100, gb_bus, H_Timer_Start_Stop , H_Timer_Start_Stop , H_Timer_Start_Stop_written );  
   
   debugout <= x"00" & H_Timer_Start_Stop & H_Timer_IRQ_Enable & "000" & H_Count_up & H_Prescaler & counter_readback;
   
   -- @process-purpose: 在 clk100 时钟域维护单路 Timer 的寄存器状态，使总线事件、内部状态机和对外输出在同一拍更新。
   -- @process-mechanism: reset/读档时从 SAVESTATE_TIMER 恢复开关、计数器和预分频器；运行时写 H_Timer_Start_Stop 会决定是否按 L_Counter_Reload 重装；随后按 H_Prescaler 产生 1/64/256/1024 分频，new_cycles_valid 或 countup_in 维护 counter，溢出后产生 tick/IRQ。
   -- @process-result: 结果是下游只需要消费 tick、IRQ 或 ready 等同步输出，不必重新理解内部计数、等待或重装细节。
   process (clk100)
   begin
      if rising_edge(clk100) then
      
         tick      <= '0';
         IRP_Timer <= '0';

         if (reset = '1') then
      
            timer_on         <= SAVESTATE_TIMER(0);
            timer_on_next    <= SAVESTATE_TIMER(1);
            counter          <= unsigned(SAVESTATE_TIMER(18 downto 2));
            prescalecounter  <= unsigned(SAVESTATE_TIMER(29 downto 19));
      
         elsif (gb_on = '1') then
         
            -- set_settings
            if (H_Timer_Start_Stop_written = '1' and loading_savestate = '0') then
               if (H_Timer_Start_Stop = "1" and timer_on = '0') then
                  counter         <= '0' & unsigned(L_Counter_Reload);
                  prescalecounter <= (others => '0');
               end if;
               timer_on_next <= H_Timer_Start_Stop(H_Timer_Start_Stop'left);
            end if;
            
            case (to_integer(unsigned(H_Prescaler))) is
               when 0 => prescaleborder <= 1;
               when 1 => prescaleborder <= 64;
               when 2 => prescaleborder <= 256;
               when 3 => prescaleborder <= 1024;
               when others => null;
            end case;

            --work
            
            if (new_cycles_valid = '1') then
               timer_on <= timer_on_next;
               if (timer_on_next = '1' and new_cycles >= 2) then
                  if ((H_Count_up = "0" or index = 0)) then
                     if (H_Prescaler = "00") then
                        counter <= counter + new_cycles - 2;
                     else
                        prescalecounter <= prescalecounter + new_cycles - 2;
                     end if;
                  end if;
               end if;
            end if;
         
            if (timer_on = '1' and timer_on_next = '1') then
               if (H_Count_up = "1" and countup_in = '1') then
                  counter <= counter + 1;
               elsif ((H_Count_up = "0" or index = 0) and new_cycles_valid = '1') then
                  if (H_Prescaler = "00") then
                     counter <= counter + new_cycles;
                  else
                     prescalecounter <= prescalecounter + new_cycles;
                  end if;
               elsif (prescalecounter >= prescaleborder) then
                  prescalecounter <= prescalecounter - prescaleborder;
                  counter <= counter + 1;
               elsif (counter(16) = '1') then
                  counter <= counter - 16#10000# + unsigned(L_Counter_Reload);
                  tick    <= '1';
                  if (H_Timer_IRQ_Enable = "1") then
                     IRP_Timer <= '1';
                  end if;
               end if;
            end if;
            
         end if;
         
         counter_readback <= std_logic_vector(counter(15 downto 0));
      
      end if;
   end process;
  

end architecture;





