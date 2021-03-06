----------------------------------------------------------------------------------
--
-- SPI slave device
--
-- Parameters:
--   ADDR_WIDTH  -- Wishbone address width in bits (8, 16, 24, 32...64)
--   DATA_WIDTH  -- Wishbone data width in bits (8, 16, 24, 32...64)
--
-- Signals: Clock, Reset, standard wishbone, SPI: CLK, CE, MOSI, MISO
--
-- SPI Protocol:  (For data bytes sent over SPI)
--
-- This device works with clock polarity and phase = 0, so data is stable
-- on rising edge of clock.
--
-- Writes: First (ADDR_WIDTH/8) bytes must be WB address.  The top bit
--         of the address must be set to '1' to indicate a write cycle.
--         After sending the WB address, send (DATA_WIDTH/8) bytes of WB data.
--         Sending partial WB data results in the write being cancelled.
--
-- Reads: First perform a write of (ADDR_WIDTH/8) bytes to set the WB address.
--        The top bit of the addressw must be set to '0' to indicate a read
--        cycle.  Send (DATA_WIDTH/8) more bytes of any value while reading
--        from the MISO pin.  Performing a partial read will read the first N
--        bits of the WB data.
--
-- WB addresses and data are in big endian order, MSB first.
--
-- Because the SPI protocol has no way to tell the master device to wait for
-- data to become available, WB reads must be complete within one SPI clock
-- cycle.  With a Raspberry PI running SPI at 32MHz and sys_clk at 100MHz, that
-- is less than 3 sys_clk cycles.
--
----------------------------------------------------------------------------------
--
-- Copyright (C) 2017  Nathan Friess
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity spislave is
	 Generic (
				  ADDR_WIDTH : Positive range 8 to 64 := 8;
				  DATA_WIDTH : Positive range 8 to 64 := 8;
				  AUTO_INC_ADDRESS : STD_LOGIC := '1'
				  );
    Port ( sys_clk : in  STD_LOGIC;
			  
			  spi_clk : in STD_LOGIC;
			  spi_ce : in STD_LOGIC;
			  spi_mosi : in STD_LOGIC;
			  spi_miso : out STD_LOGIC;
			  
			  wb_cycle : out STD_LOGIC;
			  wb_strobe : out STD_LOGIC;
			  wb_write : out STD_LOGIC;
			  wb_address : out STD_LOGIC_VECTOR(ADDR_WIDTH-1 downto 0);
			  wb_data_i : in STD_LOGIC_VECTOR(DATA_WIDTH-1 downto 0);
			  wb_data_o : out STD_LOGIC_VECTOR(DATA_WIDTH-1 downto 0);
			  wb_ack : in STD_LOGIC
			  );
end spislave;

architecture Behavioral of spislave is

	signal spi_addr_shift_reg : std_logic_vector(ADDR_WIDTH-1 downto 0);
	signal spi_shift_in_reg : std_logic_vector(DATA_WIDTH-1 downto 0);
	signal spi_shift_out_reg : std_logic_vector(DATA_WIDTH-1 downto 0);
	
	signal spi_shift_count : integer range 0 to (ADDR_WIDTH + DATA_WIDTH);
	
	signal last_spi_ce : std_logic := '1';
	
	signal wb_cycle_reg : std_logic := '0';
	signal wb_strobe_reg : std_logic := '0';
	signal wb_write_reg : std_logic := '0';
	signal wb_data_o_reg : std_logic_vector(DATA_WIDTH-1 downto 0);
	
	signal spi_clk_delayed : std_logic;

begin
	
	wb_cycle <= wb_cycle_reg;
	wb_strobe <= wb_strobe_reg;
	wb_write <= wb_write_reg;
	wb_data_o <= wb_data_o_reg;
	wb_address <= "0" & spi_addr_shift_reg(ADDR_WIDTH-2 downto 0);
	
	
	-- Delay spi_clk by one sys_clk cycle.  This seems to be necessary to transfer
	-- 1K blocks at 32MHz without any bit errors.
	process(sys_clk)
	begin
	
		if rising_edge(sys_clk) then
			spi_clk_delayed <= spi_clk;
		end if;
	
	end process;
	
	
	-- Clocking in address and data
	process(spi_clk_delayed, spi_ce)
	begin
	
		if spi_ce = '1' then
			
			spi_shift_count <= 0;
			wb_cycle_reg <= '0';
			wb_strobe_reg <= '0';
			
		elsif rising_edge(spi_clk_delayed ) then
			
			-- Counting the number of bits shifted in so far
			if spi_shift_count < ADDR_WIDTH + DATA_WIDTH then
				spi_shift_count <= spi_shift_count + 1;
			end if;
			
			-- Shifting address and data input
			-- The last shift here is not really needed since we save to wb_address
			-- below during the last shift in.
			if spi_shift_count > (ADDR_WIDTH-1) then
				
				spi_shift_in_reg <= spi_shift_in_reg(DATA_WIDTH-2 downto 0) & spi_mosi;
				
			else
				
				spi_addr_shift_reg <= spi_addr_shift_reg(ADDR_WIDTH-2 downto 0) & spi_mosi;
				
			end if;
			
			-- Read cycle is done as soon as address is complete
			if spi_shift_count = (ADDR_WIDTH-1) and spi_addr_shift_reg(ADDR_WIDTH-2) = '0' then
				
				wb_cycle_reg <= '1';
				wb_strobe_reg <= '1';
				wb_write_reg <= '0';
				wb_data_o_reg <= (others => '0');
				
			-- Write cycle is done after data has arrived
			elsif spi_shift_count = (ADDR_WIDTH+DATA_WIDTH-1) and spi_addr_shift_reg(ADDR_WIDTH-1) = '1' then
				
				wb_cycle_reg <= '1';
				wb_strobe_reg <= '1';
				wb_write_reg <= '1';
				wb_data_o_reg <= spi_shift_in_reg(DATA_WIDTH-2 downto 0) & spi_mosi;
				
			end if;

			-- End of read or write cycle
			if wb_strobe_reg = '1' and wb_ack = '1' then
				
				wb_cycle_reg <= '0';
				wb_strobe_reg <= '0';
				
				-- If we allow multiple writes without de-asserting CE, then
				-- increment address and go back to data phase
				if AUTO_INC_ADDRESS = '1' and wb_write_reg = '1' then
					
					spi_addr_shift_reg <= spi_addr_shift_reg + 1;
					
					spi_shift_count <= ADDR_WIDTH+1;
					
				end if;
				
			end if;
			
		end if;
		
	end process;
	
	-- Make first bit available from wb_data immediately, and otherwise use shift register
	spi_miso <= wb_data_i(DATA_WIDTH-1) when spi_shift_count = ADDR_WIDTH else spi_shift_out_reg(DATA_WIDTH-1);
	
	
	-- Clocking out data
	process(spi_clk_delayed)
	begin
	
		-- In theory, data should change on the falling edge of spi_clk, but to achieve 
		-- higher speeds we give extra time by transitioning on the delayed rising edge
		if rising_edge(spi_clk_delayed) then
			
			-- Shifting data output
			if spi_shift_count > ADDR_WIDTH then
				
				spi_shift_out_reg <= spi_shift_out_reg(DATA_WIDTH-2 downto 0) & '0';
				
			-- Capture data from wishbone device and start output
			elsif spi_shift_count = ADDR_WIDTH and wb_ack = '1' then
				
				spi_shift_out_reg <= wb_data_i(DATA_WIDTH-2 downto 0) & '0';
				
			end if;
			
		end if;
		
	end process;
	
	
end Behavioral;

