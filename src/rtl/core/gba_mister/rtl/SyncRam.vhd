--------------------------------------------------------------------------------
-- @file SyncRam.vhd
-- @module-contract
-- 职责: 单口 RAM；单口同步 RAM 基础模块，封装可综合块 RAM 推断。
-- 上游: core 内部同步读写请求。
-- 下游: Vivado 存储资源推断。
-- 时钟域: clk100/clk 等，具体以 entity 端口命名为准。
-- 复位: 低有效复位 rst_n 或 core 内部复位信号，按模块端口定义生效。
-- 关键协议: 模块内部 valid/ready、写使能、读有效或单拍脉冲按端口命名和相邻状态机消费关系传递。
-- 设计注意点: 提供简单同步 RAM 基础块；本注释只解释设计意图，不改变 RTL/XDC 功能。
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity SyncRam is
   generic 
   (
      DATA_WIDTH : natural := 8;
      ADDR_WIDTH : natural := 6
   );
   port 
   (
      clk        : in std_logic;
      
      addr     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain   : in std_logic_vector((DATA_WIDTH-1) downto 0);
      dataout  : out std_logic_vector((DATA_WIDTH -1) downto 0);
      we       : in std_logic := '1'
   );
end;

architecture rtl of SyncRam is

   -- Build a 2-D array type for the RAM
   subtype word_t is std_logic_vector((DATA_WIDTH-1) downto 0);
   type memory_t is array(2**ADDR_WIDTH-1 downto 0) of word_t;

   -- Declare the RAM 
   shared variable ram : memory_t;

begin

   -- Port A
   -- @process-purpose: 在 clk 时钟域维护单口 RAM的寄存器状态，使总线事件、内部状态机和对外输出在同一拍更新。
   -- @process-mechanism: 写使能有效时先把 Din 写入 ram(addr)，随后每拍把 ram(addr) 读到 dataout；因此读数据是同步 RAM 的一拍时序输出。
   -- @process-result: 结果是下游看到按本模块协议整理过的同步状态、单拍脉冲或组合选择。
   process(clk)
   begin
   if(rising_edge(clk)) then 
      if(we = '1') then
         ram(addr) := datain;
      end if;
      dataout <= ram(addr);
   end if;
   end process;

end rtl;
