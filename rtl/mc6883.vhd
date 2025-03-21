library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity mc6883 is
	port
	(
		clk         : in std_logic;
		clk_ena     : in std_logic;
		por         : in std_logic;
		reset       : in std_logic;

		-- input
		addr        : in std_logic_vector(15 downto 0);
		rw_n        : in std_logic;

		-- vdg signals
		da0         : in std_logic;  -- display address 0 - 
		hs_n        : in std_logic;
		vclk        : out std_logic;
		vclk_en_p   : out std_logic;
		vclk_en_n   : out std_logic;

		-- peripheral address selects		
		s_device_select				: out std_logic_vector(2 downto 0);

		-- clock generation
		clk_e			: out std_logic;
		clk_q			: out std_logic;
		clk_e_en		: out std_logic;
		clk_q_en		: out std_logic;

		-- dynamic addresses
		z_ram_addr	: out std_logic_vector(7 downto 0);

		-- ram
		ras0_n 		: out std_logic;
		cas_n			: out std_logic;
		we_n			: out std_logic;
		-- debug
		dbg     		: out std_logic_vector(15 downto 0)
	);
end mc6883;

architecture SYN of mc6883 is

	subtype DivisorType is integer range 0 to 11;
	type DivisorArrayType is array (natural range <>) of DivisorType;
	-- Division variables for V0=0, V2..V1=sel
	--constant y_divisor		: DivisorArrayType(0 to 3) := (12, 3, 2, 1);
	-- Division variable for V0=1, v2..V1=sel
	--constant x_divisor		: DivisorArrayType(0 to 3) := (3, 2, 1, 1);
	constant mode_rows    : DivisorArrayType(0 to 7) := (12-1, 3-1, 3-1, 2-1, 2-1, 1-1, 1-1, 1-1);
	
	-- clocks
	signal count          : std_logic_vector(3 downto 0);

	-- some rising_edge pulses
	signal rising_edge_hs : std_logic;

	-- video counter
	signal b_int          : std_logic_vector(15 downto 0);

	-- control register (CR)
	signal cr				: std_logic_vector(15 downto 0);
	signal sel_cr		: std_logic;
	
	alias ty_memory_map_type: std_logic 							is cr(15);
	alias m_memory_size		: std_logic_vector(1 downto 0) 	is cr(14 downto 13);
	alias r_mpu_rate			: std_logic_vector(1 downto 0) 	is cr(12 downto 11);
	alias p_32k_page_switch : std_logic 							is cr(10);
	alias f_vdg_addr_offset : std_logic_vector(6 downto 0) 	is cr(9 downto 3);
	alias v_vdg_addr_modes 	: std_logic_vector(2 downto 0) 	is cr(2 downto 0);
	
	alias flag			: std_logic 										is addr(0);

	-- flag if VDG need to be synchronized
	signal count_offset : std_logic_vector(1 downto 0);
	signal count_eff : std_logic_vector(1 downto 0);
	signal vclk_s : std_logic;
	signal vclk_en_p_s : std_logic;
	signal vclk_en_n_s : std_logic;

	-- internal chipselect vectors
	signal sel_ram    : std_logic;
	signal s_ty0		: std_logic_vector(2 downto 0);
	signal s_ty1		: std_logic_vector(2 downto 0);

	signal video_ras_addr : std_logic_vector(7 downto 0);
	signal video_cas_addr : std_logic_vector(7 downto 0);
	signal mpu_ras_addr : std_logic_vector(7 downto 0);
	signal mpu_cas_addr : std_logic_vector(7 downto 0);

	signal clk_e_en_n : std_logic;
	signal clk_e_en_p : std_logic;
	signal clk_q_en_n : std_logic;
	signal clk_q_en_p : std_logic;

	-- internal versions of pin signals
	signal we_n_next       : std_logic;
	signal we_n_s          : std_logic;
	signal ras0_n_next     : std_logic;
	signal ras0_n_s        : std_logic;
	signal cas_n_next      : std_logic;
	signal cas_n_s         : std_logic;
	signal z_ram_addr_next : std_logic_vector(7 downto 0);
	signal z_ram_addr_s    : std_logic_vector(7 downto 0);

	signal turbo           : std_logic;

	signal debug    : std_logic_vector(1 downto 0);

begin

	--  
	-- CPU Address is valid tAD after falling edge of E
	-- CPU Read Data latched at falling edge of E
	-- CPU Write Data valid tDDW after rising edge of Q, 
	-- - until tDHW (short) after falling edge E
	--

	-- clock generation, ras/cas generation
	clk_e_en <= clk_e_en_n and clk_ena;
	clk_q_en <= clk_q_en_n and clk_ena;
	
	process(m_memory_size, b_int, addr, ty_memory_map_type)
	begin
		case m_memory_size is
			when "00" =>
				video_ras_addr <= '0' & b_int(6 downto 0);
				video_cas_addr <= "00" & b_int(11 downto 6);
				mpu_ras_addr <= '0' & addr(6 downto 0);
				mpu_cas_addr <= "00" & addr(11 downto 6);
			when "01" =>
				video_ras_addr <= '0' & b_int(6 downto 0);
				video_cas_addr <= '0' & b_int(13 downto 7);
				mpu_ras_addr <= '0' & addr(6 downto 0);
				mpu_cas_addr <= '0' & addr(13 downto 7);
			when others =>
				video_ras_addr <= b_int(7 downto 0);
				video_cas_addr <= b_int(15 downto 8);
				mpu_ras_addr <= addr(7 downto 0);
				if ty_memory_map_type = '0' then
					mpu_cas_addr <= p_32k_page_switch & addr(14 downto 8);
				else
					mpu_cas_addr <= addr(15 downto 8);
				end if;
		end case;
	end process;

	-- adjust vclk until VDG and SAM are synced
	count_eff <= count(1 downto 0) - count_offset;
	vclk_en_p_s <= '1' when vclk_s = '0' and clk_ena = '1' and count_eff(1 downto 0) = "01" else '0';
	vclk_en_n_s <= '1' when vclk_s = '1' and clk_ena = '1' and count_eff(1 downto 0) = "11" else '0';
	vclk <= vclk_s;
	vclk_en_p <= vclk_en_p_s;
	vclk_en_n <= vclk_en_n_s;

	turbo <= '1' when r_mpu_rate(1) = '1' or (r_mpu_rate(0) = '1' and sel_ram = '0') else '0';

	process(r_mpu_rate, count, sel_ram, z_ram_addr_s, we_n_s, ras0_n_s, cas_n_s, rw_n,
	        video_ras_addr, video_cas_addr, mpu_ras_addr, mpu_cas_addr, turbo)
	begin
		clk_e_en_p <= '0';
		clk_q_en_p <= '0';
		clk_e_en_n <= '0';
		clk_q_en_n <= '0';
		z_ram_addr_next <= z_ram_addr_s;
		ras0_n_next <= ras0_n_s;
		cas_n_next <= cas_n_s;
		we_n_next <= we_n_s;

		case count is
			when "0000" =>
				if turbo = '1' and sel_ram = '1' then
					z_ram_addr_next <= mpu_ras_addr;
				else
					z_ram_addr_next <= video_ras_addr;
				end if;
				ras0_n_next <= '0';
			when "0001" =>
				if turbo = '1' then clk_q_en_p <= '1'; end if;
			when "0010" =>
				-- valid VDG address (col)
				if turbo = '1' and sel_ram = '1' then
					z_ram_addr_next <= mpu_cas_addr;
				else
					z_ram_addr_next <= video_cas_addr;
				end if;
				cas_n_next <= '0';
			when "0011" =>
				if turbo = '0' then clk_q_en_p <= '1'; end if;
				if turbo = '1' then clk_e_en_p <= '1'; end if;
				we_n_next <= rw_n or not sel_ram or not turbo;
			when "0100" =>
			when "0101" =>
				we_n_next <= '1';
				ras0_n_next <= '1';
				if turbo = '1' then clk_q_en_n <= '1'; end if;
			when "0110" =>
			when "0111" =>
				cas_n_next <= '1';
				if turbo = '0' then clk_e_en_p <= '1'; end if;
				if turbo = '1' then clk_e_en_n <= '1'; end if;
			when "1000" =>
				-- valid MPU address (row)
				z_ram_addr_next <= mpu_ras_addr;
				ras0_n_next <= '0';
			when "1001" =>
				if turbo = '1' then clk_q_en_p <= '1'; end if;
			when "1010" =>
				-- valid MPU address (col)
				z_ram_addr_next <= mpu_cas_addr;
				cas_n_next <= '0';
			when "1011" =>
				if turbo = '0' then clk_q_en_n <= '1'; end if;
				if turbo = '1' then clk_e_en_p <= '1'; end if;
				we_n_next <= rw_n or not sel_ram;
			when "1100" =>
			when "1101" =>
				ras0_n_next <= '1';
				we_n_next <= '1';
				if turbo = '1' then clk_q_en_n <= '1'; end if;
			when "1110" =>
			when "1111" =>
				cas_n_next <= '1';
				clk_e_en_n <= '1';
			when others =>
				null;
		end case;
	end process;

	PROC_MAIN : process (clk, por)
	begin
		if por = '1' then
			z_ram_addr_s <= (others => '0');
			count <= (others => '0');
			clk_q <= '0';
			clk_e <= '0';
			ras0_n_s <= '1';
			cas_n_s <= '1';
			we_n_s <= '1';
		elsif rising_edge (clk) then
			if vclk_en_p_s = '1' then
				vclk_s <= '1';
			end if;
			if vclk_en_n_s = '1' then
				vclk_s <= '0';
			end if;
			if clk_ena = '1' then
				z_ram_addr_s <= z_ram_addr_next;
				we_n_s <= we_n_next;
				ras0_n_s <= ras0_n_next;
				cas_n_s <= cas_n_next;
				if clk_e_en_p = '1' then
					clk_e <= '1';
				end if;
				if clk_e_en_n = '1' then
					clk_e <= '0';
				end if;
				if clk_q_en_p = '1' then
					clk_q <= '1';
				end if;
				if clk_q_en_n = '1' then
					clk_q <= '0';
				end if;

				count <= count + 1;
			end if; -- clk_ena
		end if;
	end process PROC_MAIN;

	-- assign outputs
	z_ram_addr <= z_ram_addr_s;
	ras0_n <= ras0_n_s;
	cas_n <= cas_n_s;
	we_n <= we_n_s;

	-- rising edge pulses
	process (clk, por)
		variable old_hs : std_logic;
	begin
		if por = '1' then
			old_hs := '0';
			rising_edge_hs <= '0';
		elsif rising_edge (clk) then
			if clk_ena = '1' then
				rising_edge_hs <= '0';
				if old_hs = '0' and hs_n = '1' then
					rising_edge_hs <= '1';
				end if;
				old_hs := hs_n;
			end if; -- clk_ena
		end if;
	end process;

	-- video address generation
	-- normally, da0 clocks the internal counter
	-- but we want a synchronous design
	-- so sample da0 each internal clock
	process (clk, por)
		variable old_hs   : std_logic;
		variable old_da0  : std_logic;
		variable yscale   : integer;
		variable saved_b : std_logic_vector(15 downto 0);
	begin
		if por = '1' then
			b_int <= (others => '0');
			old_hs := '1';
			old_da0 := '1';
			yscale := 0;
			saved_b := (others => '0');
			count_offset <= "00";
		elsif rising_edge (clk) then
			if clk_ena = '1' then
				-- vertical blanking - HS rises when DA0 is high
				-- resets bits B9-15, clear B1-B8
				if rising_edge_hs = '1' and da0 = '1' then
					b_int(15 downto 9) <= f_vdg_addr_offset(6 downto 0);
					b_int(8 downto 0) <= (others => '0');
					yscale := mode_rows(conv_integer(v_vdg_addr_modes(2 downto 0)));
					saved_b := f_vdg_addr_offset(6 downto 0) & "000000000";
				-- horizontal blanking - HS low
				-- resets bits B1-B3/4
				elsif hs_n = '0' then
					if v_vdg_addr_modes(0) = '0' then
						b_int(4) <= '0';
					end if;
					b_int(3 downto 1) <= (others => '0');
					-- coming out of HS?
					if old_hs = '1' then
						if yscale = mode_rows(conv_integer(v_vdg_addr_modes(2 downto 0))) then
							yscale := 0;
							saved_b := b_int;
						else
							yscale := yscale + 1;
							b_int <= saved_b;
						end if;
					end if;
					-- transition on da is the video clock
				elsif da0 /= old_da0 then
					b_int <= b_int + 1;
				end if;

				if hs_n = '1' and da0 /= old_da0 and count /= x"E" then
					count_offset <= count_offset + 1;
				end if;

				old_hs := hs_n;
				old_da0 := da0;
				debug <= old_hs & old_da0;
			end if; -- clk_ena
		end if;
	end process;

	-- select control register (CR)
	sel_cr <= '1' when addr(15 downto 5) = "11111111110" else '0';

	--
	--	Memory decode logic
	--	- combinatorial - needs to be gated
	--
	sel_ram <= '1' when m_memory_size = "00" and addr(15 downto 12) = x"0" else -- 4k
	           '1' when m_memory_size = "01" and addr(15 downto 14) = "00" else -- 16k
	           '1' when m_memory_size(1) = '1' and addr(15) = '0' else -- 32/64k
	           '1' when m_memory_size(1) = '1' and ty_memory_map_type = '1' and addr(15 downto 8) /= x"FF" else
	           '0';

	s_ty0 <= 	"010" when 	-- $FFF2-$FFFF (6809 vectors)
	                        -- $FFE0-$FFF1 (reserved)
	                        addr(15 downto 5) = "11111111111"
	                  else
               "111" when  -- $FFC0-$FFDF (SAM control register)
                           -- $FF60-$FFBF (reserved)
                           sel_cr = '1' or 
	                        (addr(15 downto 8) = "11111111" and (addr(7) = '1' or addr(6 downto 5) = "11"))
	                  else
               "110" when	-- $FF40-$FF5F (IO2)
	                        addr(15 downto 5) = "11111111010"
	                  else
               "101" when	-- $FF20-$FF3F (IO1)
	                        addr(15 downto 5) = "11111111001"
	                  else
               "100" when	-- $FF00-$FF1F (IO0)
	                        addr(15 downto 5) = "11111111000"
	                  else
               "011" when	-- $C000-$FEFF (rom2)
	                        addr(15 downto 14) = "11"
	                  else
               "010" when	-- $A000-$BFFF (rom1)
	                        addr(15 downto 13) = "101"
	                  else
               "001" when	-- $8000-$9FFF (rom0)
	                        addr(15 downto 13) = "100"
	                  else
               "000"	when	-- $0000-$7FFF (32K) RW_N=1   -> map to RAM select
	                        addr(15) = '0' and rw_n = '1' and sel_ram = '1'
	                  else
               "111" when	-- $0000-$7FFF (32K) RW_N=0
	                        addr(15) = '0' and rw_n = '0' and sel_ram = '1'
	                  else
	            "111";

	--
	-- alternate control logic,
	-- when mapping in effect
	--
	s_ty1 <=    s_ty0 when	-- $FF00-$FFFF
	                        addr(15 downto 8) = X"FF"
	                  else
	            "000" when  -- $0000-$FEFF (32K) RW_N=1   -> map to RAM select
	                  rw_n = '1'
	                  else
	            "111";      -- $0000-$FEFF (32K) RW_N=0
	
	s_device_select <= 	s_ty0 when ty_memory_map_type = '0' else		-- if himem mapped to ROM, use s_ty0 multiplex output (normal)
				s_ty1;							-- else, also map &H8000 thru &HFEFF as RAM
				
	--
	--	Handle update of the control register (CR)
	--
	WRITE_CR : process (clk, reset, addr, rw_n)
	begin
		if reset = '1' then
			cr <= (others => '0');
		elsif rising_edge (clk) then
			if clk_ena = '1' then
				if sel_cr = '1' and rw_n = '0' then
					case addr(4 downto 1) is
						when "0000" =>
							v_vdg_addr_modes(0) <= flag;
						when "0001" =>
							v_vdg_addr_modes(1) <= flag;
						when "0010" =>
							v_vdg_addr_modes(2) <= flag;
						when "0011" =>
							f_vdg_addr_offset(0) <= flag;
						when "0100" =>
							f_vdg_addr_offset(1) <= flag;
						when "0101" =>
							f_vdg_addr_offset(2) <= flag;
						when "0110" =>
							f_vdg_addr_offset(3) <= flag;
						when "0111" =>
							f_vdg_addr_offset(4) <= flag;
						when "1000" =>
							f_vdg_addr_offset(5) <= flag;
						when "1001" =>
							f_vdg_addr_offset(6) <= flag;
						when "1010" =>
							p_32k_page_switch <= flag;
						when "1011" =>		-- &HFFD6/D7 - the "high speed poke"  (D7 enables "high speed", D6 disables)
							r_mpu_rate(0) <= flag;
						when "1100" =>
							r_mpu_rate(1) <= flag;
						when "1101" =>
							m_memory_size(0) <= flag;
						when "1110" =>
							m_memory_size(1) <= flag;
						when others =>    -- "1111"   &HFFDE/DF
							ty_memory_map_type <= flag;		-- this flag maps ROM or RAM to the top half of memory.  FFDE = ROM, FFDF = RAM
					end case;
				end if;
			end if; -- clk_ena
		end if;
	end process WRITE_CR;

-- for hexy display, for example
	dbg <= cr;
  
end SYN;
