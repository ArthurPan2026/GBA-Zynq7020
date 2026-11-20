--------------------------------------------------------------------------------
-- @file gba_statemanager.vhd
-- @module-contract
-- 职责: 状态寄存器访问调度器，为 savestate 子系统提供统一编号读写窗口。
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

entity gba_statemanager is
   generic
   (
      Softmap_SaveState_ADDR   : integer; -- count:  524288    -- 512 Kbyte Data for Savestate
      Softmap_Rewind_ADDR      : integer  -- count:  524288*64 -- 64*512 Kbyte Data for Savestates
   );
   port 
   (
      clk100              : in    std_logic; 
      gb_on               : in    std_logic;

      rewind_on           : in    std_logic;
      rewind_active       : in    std_logic;
      
      savestate_number    : in    integer;
      save                : in    std_logic;  
      load                : in    std_logic;
      
      sleep_rewind        : out   std_logic := '0';
      vsync               : in    std_logic;  
      
      request_savestate   : out   std_logic := '0';
      request_loadstate   : out   std_logic := '0';
      request_address     : out   integer;
      request_busy        : in    std_logic
   );
end entity;

architecture arch of gba_statemanager is

   constant SAVESTATESIZE : integer := 16#20000#; -- 131072 Dwords = 512kbyte
   constant REWIND_COUNT  : integer := 64;
   constant TIME_CAPTURE  : integer := 100000000; -- 1 second    sim 1000000;
   constant TIME_REWIND   : integer := 50000000;  -- 500ms       sim 1200000;

   signal save_1         : std_logic := '0';
   signal load_1         : std_logic := '0';
   signal save_buffer    : std_logic := '0';
   signal load_buffer    : std_logic := '0';
   
   signal rewind_enabled : std_logic := '0';
   signal rewind_load_next : std_logic := '0';
   
   signal timer_rewind   : integer range 0 to TIME_CAPTURE := 0;
   signal rewind_slow    : integer range 0 to TIME_REWIND := 0;
   signal savestatecount : integer range 0 to REWIND_COUNT := 0;
   signal savestatepos   : integer range 0 to REWIND_COUNT - 1 := 0;
   
   signal vsync_counter  : integer range 0 to 2 := 0;

begin 
   
   -- @process-purpose: 在 clk100 时钟域维护savestate 状态访问调度器的寄存器状态，使总线事件、内部状态机和对外输出在同一拍更新。
   -- @process-mechanism: (rewind_on = '0' or gb_on = '0') 时先回到初始/安全状态；(save = '1' and save_1 = '0')、(load = '1' and load_1 = '0') 作为有效时选择对应处理分支；默认分支清除单拍脉冲并保持寄存器，触发条件满足时在时钟沿锁存 request_savestate、request_loadstate、rewind_load_next、save_1、save_buffer、load_1，形成下游可采样的同步状态、单拍脉冲或握手响应。
   -- @process-result: 结果是 request_savestate、request_loadstate、rewind_load_next、save_1、save_buffer、load_1 等信号只在明确时钟沿变化，下游可以把它们视为同步有效的控制或数据边界。
   process (clk100)
   begin
      if rising_edge(clk100) then
      
         request_savestate <= '0';
         request_loadstate <= '0';
         rewind_load_next  <= '0';
      
         save_1 <= save; 
         if (save = '1' and save_1 = '0') then
            save_buffer <= '1';
         end if;
         
         load_1 <= load;
         if (load = '1' and load_1 = '0') then
            load_buffer <= '1';
         end if;
         
         if (rewind_on = '0' or gb_on = '0') then
            rewind_enabled <= '0';
         end if;
         
         if (rewind_active = '0') then
            rewind_slow <= 0;
         elsif (rewind_slow < TIME_REWIND) then
            rewind_slow <= rewind_slow + 1;
         end if;
         
         if (rewind_active = '1') then
            timer_rewind <= 0;
         elsif (timer_rewind < TIME_CAPTURE) then
            timer_rewind <= timer_rewind + 1;
         end if;
         
         if (vsync_counter < 2 and vsync = '1') then
            vsync_counter <= vsync_counter + 1;
         end if;
         
         sleep_rewind <= '0';
         if (vsync_counter = 2 and rewind_active = '1') then
            sleep_rewind <= '1';
         end if;
         
         if (gb_on = '1' and request_busy = '0') then
            
            if (save_buffer = '1') then
               request_address   <= Softmap_SaveState_ADDR + (savestate_number * SAVESTATESIZE);
               request_savestate <= '1';
               save_buffer       <= '0';
            elsif (load_buffer = '1') then
               request_address   <= Softmap_SaveState_ADDR + (savestate_number * SAVESTATESIZE);
               request_loadstate <= '1';
               load_buffer       <= '0';
            elsif (rewind_enabled = '0' and rewind_on = '1') then
               request_address   <= Softmap_Rewind_ADDR;
               request_savestate <= '1';
               rewind_enabled    <= '1';
               timer_rewind      <= 0;
               savestatecount    <= 1;
               savestatepos      <= 1;
            elsif (rewind_enabled = '1' and timer_rewind = TIME_CAPTURE) then
               request_address   <= Softmap_Rewind_ADDR + (savestatepos * SAVESTATESIZE);
               request_savestate <= '1';
               timer_rewind      <= 0;
               if (savestatecount < REWIND_COUNT) then
                  savestatecount <= savestatecount + 1;
               end if;
               if (savestatepos < (REWIND_COUNT - 1)) then
                  savestatepos <= savestatepos + 1;
               else
                  savestatepos <= 0;
               end if;
            elsif (rewind_enabled = '1' and rewind_slow = TIME_REWIND) then
               if (savestatecount > 1) then
                  savestatecount <= savestatecount - 1;
                  if (savestatepos > 0) then
                     savestatepos <= savestatepos - 1;
                  else
                     savestatepos <= REWIND_COUNT - 1;
                  end if;
                  rewind_load_next <= '1';
               end if;
               rewind_slow <= 0;
            elsif (rewind_load_next = '1') then
               request_address   <= Softmap_Rewind_ADDR + (savestatepos * SAVESTATESIZE);
               request_loadstate <= '1';
               vsync_counter     <= 0;
            end if;
            
         end if;

      end if;
   end process;
  

end architecture;





