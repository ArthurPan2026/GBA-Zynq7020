--------------------------------------------------------------------------------
-- @file gba_gpu_timing.vhd
-- @module-contract
-- 职责: PPU 时序发生器；GBA PPU 时序发生器，产生 HBlank/VBlank、行列计数和显示节拍。
-- 上游: core 时钟、显示寄存器。
-- 下游: GPU drawer、IRQ、frame tick。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 像素/行/帧节拍、VRAM/OAM/调色板访问和缓冲区切换必须保持确定延迟关系。
-- 设计注意点: 产生 GBA 扫描线、HBlank/VBlank 和像素时序，是渲染流水线的时间基准；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

use work.pProc_bus_gba.all;
use work.pReg_gba_display.all;

use work.pReg_savestates.all;

entity gba_gpu_timing is
   generic
   (
      is_simu : std_logic
   );
   port 
   (
      clk100               : in  std_logic;  
      gb_on                : in  std_logic;
      reset                : in  std_logic;
      lockspeed            : in  std_logic;
      
      savestate_bus        : inout proc_bus_gb_type;
      
      gb_bus               : inout proc_bus_gb_type := ((others => 'Z'), (others => 'Z'), (others => 'Z'), 'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
                           
      new_cycles           : in  unsigned(7 downto 0);
      new_cycles_valid     : in  std_logic;
                           
      IRP_HBlank           : out std_logic := '0';
      IRP_VBlank           : out std_logic := '0';
      IRP_LCDStat          : out std_logic := '0';
      
      vram_block_mode      : in  std_logic;
      vram_blocked         : out std_logic := '0';
      
      videodma_start       : out std_logic := '0';
      videodma_stop        : out std_logic := '0';
      
      line_trigger         : out std_logic := '0';                              
      hblank_trigger       : out std_logic := '0';                              
      vblank_trigger       : out std_logic := '0';                              
      drawline             : out std_logic := '0';                       
      refpoint_update      : out std_logic := '0';                       
      newline_invsync      : out std_logic := '0';                       
      linecounter_drawer   : out unsigned(7 downto 0);
      pixelpos             : out integer range 0 to 511;
      
      DISPSTAT_debug       : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of gba_gpu_timing is
   
   signal REG_DISPSTAT_V_Blank_flag         : std_logic_vector(DISPSTAT_V_Blank_flag        .upper downto DISPSTAT_V_Blank_flag        .lower) := (others => '0');
   signal REG_DISPSTAT_H_Blank_flag         : std_logic_vector(DISPSTAT_H_Blank_flag        .upper downto DISPSTAT_H_Blank_flag        .lower) := (others => '0');
   signal REG_DISPSTAT_V_Counter_flag       : std_logic_vector(DISPSTAT_V_Counter_flag      .upper downto DISPSTAT_V_Counter_flag      .lower) := (others => '0');
   signal REG_DISPSTAT_V_Blank_IRQ_Enable   : std_logic_vector(DISPSTAT_V_Blank_IRQ_Enable  .upper downto DISPSTAT_V_Blank_IRQ_Enable  .lower) := (others => '0');
   signal REG_DISPSTAT_H_Blank_IRQ_Enable   : std_logic_vector(DISPSTAT_H_Blank_IRQ_Enable  .upper downto DISPSTAT_H_Blank_IRQ_Enable  .lower) := (others => '0');
   signal REG_DISPSTAT_V_Counter_IRQ_Enable : std_logic_vector(DISPSTAT_V_Counter_IRQ_Enable.upper downto DISPSTAT_V_Counter_IRQ_Enable.lower) := (others => '0');
   signal REG_DISPSTAT_V_Count_Setting      : std_logic_vector(DISPSTAT_V_Count_Setting     .upper downto DISPSTAT_V_Count_Setting     .lower) := (others => '0');
   signal REG_VCOUNT                        : std_logic_vector(VCOUNT                       .upper downto VCOUNT                       .lower) := (others => '0');
   
   type tGPUState is
   (
      VISIBLE,
      HBLANK,
      VBLANK,
      VBLANKHBLANK
   );
   attribute fsm_encoding : string;
   signal gpustate : tGPUState;
   attribute fsm_encoding of gpustate : signal is "one_hot";
   
   signal linecounter : unsigned(7 downto 0)  := (others => '0');
   signal cycles      : unsigned(11 downto 0) := (others => '0');
   signal drawsoon    : std_logic := '0';
   
   -- savestate
   signal SAVESTATE_GPU      : std_logic_vector(24 downto 0);
   signal SAVESTATE_GPU_BACK : std_logic_vector(24 downto 0);
   
begin 
   
   SAVESTATE_GPU_BACK(11 downto  0) <= std_logic_vector(cycles);
   SAVESTATE_GPU_BACK(19 downto 12) <= std_logic_vector(linecounter);
   SAVESTATE_GPU_BACK(21 downto 20) <= std_logic_vector(to_unsigned(tGPUState'POS(gpustate), 2));
   SAVESTATE_GPU_BACK(22 downto 22) <= REG_DISPSTAT_V_Counter_flag;
   SAVESTATE_GPU_BACK(23 downto 23) <= REG_DISPSTAT_H_Blank_flag;  
   SAVESTATE_GPU_BACK(24 downto 24) <= REG_DISPSTAT_V_Blank_flag;  
   
   -- @instance-group: eProcReg_gba 寄存器映射组：同类实例把 GBA MMIO 或 savestate 总线字段解包为本模块内部控制位、回读值和写入脉冲；实例名对应具体寄存器位域。
   iSAVESTATE_GPU : entity work.eProcReg_gba generic map (REG_SAVESTATE_GPU) port map (clk100, savestate_bus, SAVESTATE_GPU_BACK , SAVESTATE_GPU);
   
   
   iREG_DISPSTAT_V_Blank_flag         : entity work.eProcReg_gba generic map (DISPSTAT_V_Blank_flag        ) port map  (clk100, gb_bus, REG_DISPSTAT_V_Blank_flag  ); 
   iREG_DISPSTAT_H_Blank_flag         : entity work.eProcReg_gba generic map (DISPSTAT_H_Blank_flag        ) port map  (clk100, gb_bus, REG_DISPSTAT_H_Blank_flag  ); 
   iREG_DISPSTAT_V_Counter_flag       : entity work.eProcReg_gba generic map (DISPSTAT_V_Counter_flag      ) port map  (clk100, gb_bus, REG_DISPSTAT_V_Counter_flag); 
   iREG_DISPSTAT_V_Blank_IRQ_Enable   : entity work.eProcReg_gba generic map (DISPSTAT_V_Blank_IRQ_Enable  ) port map  (clk100, gb_bus, REG_DISPSTAT_V_Blank_IRQ_Enable   , REG_DISPSTAT_V_Blank_IRQ_Enable   ); 
   iREG_DISPSTAT_H_Blank_IRQ_Enable   : entity work.eProcReg_gba generic map (DISPSTAT_H_Blank_IRQ_Enable  ) port map  (clk100, gb_bus, REG_DISPSTAT_H_Blank_IRQ_Enable   , REG_DISPSTAT_H_Blank_IRQ_Enable   ); 
   iREG_DISPSTAT_V_Counter_IRQ_Enable : entity work.eProcReg_gba generic map (DISPSTAT_V_Counter_IRQ_Enable) port map  (clk100, gb_bus, REG_DISPSTAT_V_Counter_IRQ_Enable , REG_DISPSTAT_V_Counter_IRQ_Enable ); 
   iREG_DISPSTAT_V_Count_Setting      : entity work.eProcReg_gba generic map (DISPSTAT_V_Count_Setting     ) port map  (clk100, gb_bus, REG_DISPSTAT_V_Count_Setting      , REG_DISPSTAT_V_Count_Setting      ); 
   iREG_VCOUNT                        : entity work.eProcReg_gba generic map (VCOUNT                       ) port map  (clk100, gb_bus, REG_VCOUNT); 
   
   linecounter_drawer <= linecounter;
   
   REG_VCOUNT(23 downto 16) <= std_logic_vector(linecounter);

   DISPSTAT_debug <= REG_VCOUNT &
                     REG_DISPSTAT_V_Count_Setting &
                     "00" &
                     REG_DISPSTAT_V_Counter_IRQ_Enable &
                     REG_DISPSTAT_H_Blank_IRQ_Enable &
                     REG_DISPSTAT_V_Blank_IRQ_Enable &
                     REG_DISPSTAT_V_Counter_flag &
                     REG_DISPSTAT_H_Blank_flag &
                     REG_DISPSTAT_V_Blank_flag;
   
   -- @process-purpose: 在 clk100 时钟域维护PPU 时序发生器的寄存器状态，使总线事件、内部状态机和对外输出在同一拍更新。
   -- @process-mechanism: 状态机以 VISIBLE、HBLANK、VBLANK、VBLANKHBLANK 等分支表示处理阶段；(reset = '1') 时先回到初始/安全状态；(gb_on = '1') 作为有效时选择对应处理分支；各分支只在本拍时钟沿提交 IRP_HBlank、IRP_VBlank、IRP_LCDStat、drawline、refpoint_update、line_trigger，使上游触发、内部等待和结果回写在波形上能按状态阶段定位。
   -- @process-result: 结果是 GPU 下游绘制模块获得稳定的行/帧触发和 LCD 中断脉冲，渲染调度可按 GBA 时序推进。
   process (clk100)
   begin
      if rising_edge(clk100) then
      
         IRP_HBlank      <= '0';
         IRP_VBlank      <= '0';
         IRP_LCDStat     <= '0';
                     
         drawline        <= '0';
         refpoint_update <= '0';
         line_trigger    <= '0';
         hblank_trigger  <= '0';
         vblank_trigger  <= '0';
         newline_invsync <= '0';
         
         videodma_start  <= '0';
         videodma_stop   <= '0';
         
         vram_blocked <= '0';
         if (gpustate = visible and vram_block_mode = '1' and cycles < 980) then
            vram_blocked <= '1';
         end if;
         
         if (reset = '1') then
         
            gpustate    <= tGPUState'VAL(to_integer(unsigned(SAVESTATE_GPU(21 downto 20))));
            cycles      <= unsigned(SAVESTATE_GPU(11 downto 0));
            linecounter <= unsigned(SAVESTATE_GPU(19 downto 12));
            
            REG_DISPSTAT_V_Counter_flag <= SAVESTATE_GPU(22 downto 22);
            REG_DISPSTAT_H_Blank_flag   <= SAVESTATE_GPU(23 downto 23);
            REG_DISPSTAT_V_Blank_flag   <= SAVESTATE_GPU(24 downto 24);
            
         elsif (gb_on = '1') then
         
            -- really required?
            -- if (forcedblank && !new_forcedblank) then
            --    gpustate = GPUState.VISIBLE
            --    cycles = 0
            --    GBRegs.Sect_display.DISPSTAT_V_Blank_flag.write(0);
            --    GBRegs.Sect_display.DISPSTAT_H_Blank_flag.write(0);
            -- end if;
         
            if (new_cycles_valid = '1') then
               cycles <= cycles + new_cycles;
            else
               case (gpustate) is
                  when VISIBLE =>
                     if ((lockspeed = '0' or cycles >= 160)) then
                        if (lockspeed = '1') then
                           pixelpos  <= (to_integer(cycles) / 2) - 80;
                        end if;
                        if (drawsoon = '1') then
                           drawline  <= '1';
                           drawsoon  <= '0';
                        end if;
                     end if;
                     if (cycles >= 1008) then -- 960 is drawing time
                        pixelpos                  <= 240;
                        cycles <= cycles - 1008;
                        gpustate                  <= HBLANK;
                        REG_DISPSTAT_H_Blank_flag <= "1";
                        hblank_trigger            <= '1';
                        if (linecounter >= 2) then
                           videodma_start  <= '1';
                        end if;
                        if (REG_DISPSTAT_H_Blank_IRQ_Enable = "1") then
                           IRP_HBlank <= '1';
                        end if;
                     end if;
                  
                  when HBLANK =>
                     if (cycles >= 224) then -- 272
                        cycles <= cycles - 224;
                        linecounter <= linecounter + 1;
                        if ((linecounter + 1) = unsigned(REG_DISPSTAT_V_Count_Setting)) then
                           if (REG_DISPSTAT_V_Counter_IRQ_Enable = "1") then
                              IRP_LCDStat <= '1';
                           end if;
                           REG_DISPSTAT_V_Counter_flag <= "1";
                        else
                           REG_DISPSTAT_V_Counter_flag <= "0";
                        end if;
   
                        REG_DISPSTAT_H_Blank_flag <= "0";
                        if ((linecounter + 1) < 160) then
                           gpustate     <= VISIBLE;
                           drawsoon     <= '1';
                           pixelpos     <= 0;
                           line_trigger <= '1';
                        else
                           gpustate                  <= VBLANK;
                           refpoint_update           <= '1';
                           REG_DISPSTAT_V_Blank_flag <= "1";
                           vblank_trigger            <= '1';
                           if (REG_DISPSTAT_V_Blank_IRQ_Enable = "1") then
                              IRP_VBlank <= '1';
                           end if;
                        end if;
                     end if;
                  
                  when VBLANK =>
                     if (cycles >= 1008) then
                        cycles <= cycles - 1008;
                        gpustate                   <= VBLANKHBLANK;
                        REG_DISPSTAT_H_Blank_flag  <= "1";
                        newline_invsync            <= '1';
                        -- don't do hblank for dma here!
                        if (REG_DISPSTAT_H_Blank_IRQ_Enable = "1") then
                           IRP_HBlank <= '1'; -- Note that no H-Blank interrupts are generated within V-Blank period. Really? Seems to work this way...
                        end if;
                        if (linecounter < 162) then
                           videodma_start <= '1';
                        end if;
                        if (linecounter = 162) then
                           videodma_stop  <= '1';
                        end if;
                     end if;
                  
                  when VBLANKHBLANK =>
                     if (cycles >= 224) then -- 272
                        cycles <= cycles - 224;
                        linecounter <= linecounter + 1;
                        if ((linecounter + 1) = unsigned(REG_DISPSTAT_V_Count_Setting) or ((linecounter + 1) = 228 and REG_DISPSTAT_V_Count_Setting = x"00")) then
                           if (REG_DISPSTAT_V_Counter_IRQ_Enable = "1") then
                              IRP_LCDStat <= '1';
                           end if;
                           REG_DISPSTAT_V_Counter_flag <= "1";
                        else
                           REG_DISPSTAT_V_Counter_flag <= "0";
                        end if;
                        
                        REG_DISPSTAT_H_Blank_flag <= "0";
                        line_trigger <= '1';
                        if ((linecounter + 1) = 228) then
                           linecounter <= (others => '0');
                           gpustate    <= VISIBLE;
                           drawsoon    <= '1';
                           pixelpos    <= 0;
                        else
                           gpustate <= VBLANK;
                           if ((linecounter + 1) = 227) then
                              REG_DISPSTAT_V_Blank_flag <= "0";  -- (set in line 160..226; not 227)
                           end if;
                        end if;
                     end if;
               
               end case;
            end if;
         
         end if;
      
      end if;
   end process;

end architecture;





