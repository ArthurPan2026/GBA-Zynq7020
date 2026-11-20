--------------------------------------------------------------------------------
-- @file proc_bus_gba.vhd
-- @module-contract
-- 职责: 处理器寄存器总线适配层，把外部配置访问映射到 core 内部寄存器协议。
-- 上游: GBA core 内部总线/寄存器/状态信号。
-- 下游: 相邻 CPU/GPU/APU/DMA/memorymux 子系统。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
-- 设计注意点: 承担 MiSTer GBA core 中一个局部硬件职责，并通过内部总线与其它子模块协作；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
-----------------------------------------------------------------
--------------- Proc Bus Package --------------------------------
-----------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

package pProc_bus_gba is

   constant proc_buswidth : integer := 32;
   constant proc_busadr   : integer := 28;
   
   constant proc_buscount : integer := 1;
   
   constant ACCESS_8BIT  : std_logic_vector(1 downto 0) := "00";
   constant ACCESS_16BIT : std_logic_vector(1 downto 0) := "01";
   constant ACCESS_32BIT : std_logic_vector(1 downto 0) := "10";
   
   type proc_bus_gb_type is record
      Din  : std_logic_vector(proc_buswidth-1 downto 0);
      Dout : std_logic_vector(proc_buswidth-1 downto 0);
      Adr  : std_logic_vector(proc_busadr-1 downto 0);
      rnw  : std_logic;
      ena  : std_logic;
      done : std_logic;
      acc  : std_logic_vector(1 downto 0);
      bEna : std_logic_vector(3 downto 0);
      rst  : std_logic;
   end record;
  
end package;


-----------------------------------------------------------------
--------------- Reg Map Package --------------------------------
-----------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

library work;
use work.pProc_bus_gba.all;

package pRegmap_gba is

   type regaccess_type is
   (
      readwrite,
      readonly,
      writeonly,
      writeDone -- writeonly, but does send back done, so it is not dead
   );

   type regmap_type is record
      Adr         : integer range 0 to (2**proc_busadr)-1;
      upper       : integer range 0 to proc_buswidth-1;
      lower       : integer range 0 to proc_buswidth-1;
      size        : integer range 0 to (2**proc_busadr)-1;
      default_val : integer;
      acccesstype : regaccess_type;
   end record;
   
end package;

-----------------------------------------------------------------
--------------- Reg Interface -----------------------------------
-----------------------------------------------------------------


library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;  

library work;
use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;

entity eProcReg_gba  is
   generic
   (
      Reg       : regmap_type;
      index     : integer := 0
   );
   port 
   (
      clk       : in    std_logic;
      proc_bus  : inout proc_bus_gb_type := ((others => 'Z'), (others => 'Z'), (others => 'Z'), 'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
      Din       : in    std_logic_vector(Reg.upper downto Reg.lower);
      Dout      : out   std_logic_vector(Reg.upper downto Reg.lower);
      written   : out   std_logic := '0';
      bEna      : out   std_logic_vector(3 downto 0) := "0000"
   );
end entity;

architecture arch of eProcReg_gba is

   signal Dout_buffer : std_logic_vector(Reg.upper downto Reg.lower) := std_logic_vector(to_unsigned(Reg.default_val,Reg.upper-Reg.lower+1));
    
   signal Adr : std_logic_vector(proc_bus.adr'left downto 0);
    
begin

   Adr <= std_logic_vector(to_unsigned(Reg.Adr + index, proc_bus.adr'length));

   greadwrite : if (Reg.acccesstype = readwrite or Reg.acccesstype = writeonly or Reg.acccesstype = writeDone) generate
   begin
   
      -- @process-purpose: 在 clk 时钟域维护处理器寄存器总线适配层的寄存器状态，使总线事件、内部状态机和对外输出在同一拍更新。
      -- @process-mechanism: (proc_bus.rst = '1') 作为有效时选择对应处理分支；默认分支清除单拍脉冲并保持寄存器，触发条件满足时在时钟沿锁存 written、bEna、Dout_buffer、Dout_buffer(i)，形成下游可采样的同步状态、单拍脉冲或握手响应。
      -- @process-result: 结果是 written、bEna、Dout_buffer、Dout_buffer(i) 等信号只在明确时钟沿变化，下游可以把它们视为同步有效的控制或数据边界。
      process (clk)
      begin
         if rising_edge(clk) then
         
            written <= '0';
            bEna <= "0000";
            
            if (proc_bus.rst = '1') then
            
               Dout_buffer <= std_logic_vector(to_unsigned(Reg.default_val,Reg.upper-Reg.lower+1));
            
            else
         
               if (proc_bus.Adr = Adr and proc_bus.rnw = '0' and proc_bus.ena = '1') then
                  for i in Reg.lower to Reg.upper loop
                     if ((proc_bus.bEna(0) = '1' and i < 8) or 
                     (proc_bus.bEna(1) = '1' and i >= 8 and i < 16) or 
                     (proc_bus.bEna(2) = '1' and i >= 16 and i < 24) or 
                     (proc_bus.bEna(3) = '1' and i >= 24)) then
                        Dout_buffer(i) <= proc_bus.Din(i);  
                        written        <= '1';
                        bEna           <= proc_bus.bEna;
                     end if;
                  end loop;
               end if;
             
            end if;
            
         end if;
      end process;
   end generate;
   
   Dout <= Dout_buffer;
   
   goutput : if (Reg.acccesstype = readwrite or Reg.acccesstype = readonly) generate
   begin
      goutputbit: for i in Reg.lower to Reg.upper generate
         proc_bus.Dout(i) <= Din(i) when proc_bus.Adr = Adr else 'Z';
      end generate;
   end generate;
   
   proc_bus.done <= '1' when Reg.lower = 0 and proc_bus.Adr = Adr and Reg.acccesstype /= writeonly else 
                    '0' when Reg.lower = 0 and proc_bus.Adr = Adr and Reg.acccesstype = writeonly else 
                    'Z';
   
   -- prevent simulation warnings
   proc_bus.Adr <= (others => 'Z');
   proc_bus.Din <= (others => 'Z');
   proc_bus.rnw <= 'Z';
   
   
end architecture;




