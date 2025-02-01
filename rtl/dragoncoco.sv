
// todo: find a better name
module dragoncoco(
	input clk, // 57.272 mhz
	input por, // power-on-reset
	input reset_n,
	input hard_reset,
	input cart_remove,
	input dragon,
	input kblayout,
	input mem64kb,

	// video signals
	output [7:0] red,
	output [7:0] green,
	output [7:0] blue,

	output hblank,
	output vblank,
	output hsync,
	output vsync,
  
	// clocks output
	output vclk,
	output clk_Q_out,

	// video options
	input artifact_phase,
	input artifact_enable,
	input overscan,

	input uart_rx,
	output uart_tx,

	// keyboard
	input        key_strobe,
	input  [7:0] key_code, // PS2 keycode
	input        key_pressed,
	input        key_extended,

	// joystick input
	// digital for buttons
	input [15:0] joy1,
	input [15:0] joy2,
	// analog for position
	input [15:0] joya1,
	input [15:0] joya2,
	input joy_use_dpad,


	// roms, cartridges, etc
	input [7:0] ioctl_data,
	input [16:0] ioctl_addr,
	input ioctl_download,
	input ioctl_wr,
	input ioctl_cart,
	input ioctl_rom,

	// cassette signals
	input casdout,
	output cas_relay,
  
	// sound
	input [11:0] cass_snd,
	output [11:0] sound,
	output sndout,

	output ledb,
	// DISK
	//
	input disk_cart_enabled,

	// SD block level interface
	input      [3:0] img_mounted, // signaling that new image has been mounted
	input      [3:0] img_wp,      // write protect
	input     [31:0] img_size,    // size of image in bytes
	output    [31:0] sd_lba,
	output     [3:0] sd_rd,
	output     [3:0] sd_wr,
	input            sd_ack,
	input      [8:0] sd_buff_addr,
	input      [7:0] sd_buff_dout,
	output     [7:0] sd_buff_din,
	input            sd_buff_wr
);

wire dragon64 = dragon & mem64kb;

assign clk_Q_out = clk_Q;

wire nmi; 
wire halt; 

wire clk_E, clk_Q;
wire clk_E_en, clk_Q_en;
wire vclk_en_p, vclk_en_n;
reg clk_14M318_ena ;
reg [1:0] count;

always @(posedge clk)
begin
	clk_14M318_ena <= count == 0;
	count <= count + 1'd1;
end

wire clk_enable = clk_14M318_ena;

wire [7:0] cpu_dout;
wire [15:0] cpu_addr;
wire cpu_rw;
wire irq;
wire firq;
wire cart_firq;

wire ram_cs,rom8_cs,romA_cs,romC_cs,io_cs,pia1_cs,pia_cs,pia_orig_cs;

reg [7:0]vdg_data;
reg [7:0] ram_dout;
reg [7:0] ram_dout_b;
wire [7:0] rom8_dout;
wire [7:0] romA_dout;
wire [7:0] romC_dout;
wire [7:0] romC_cart_dout;
wire [7:0] romC_disk_dout;
wire [7:0] romC_dragondisk_dout;
wire [7:0] pia_dout;
wire [7:0] pia1_dout;
wire [7:0] io_out;

wire we = ~cpu_rw & clk_E;

wire [7:0] keyboard_data;
wire [7:0] kb_cols, kb_rows;

wire [7:0] pia1_portb_out;

// data mux
reg [7:0] cpu_din;

always_comb begin
	unique case (1'b1)
		ram_cs:  cpu_din =  ram_dout;
		rom8_cs: cpu_din =  rom8_dout;
		romA_cs: cpu_din =  romA_dout;
		romC_cs: cpu_din =  romC_dout;
		pia_cs:  cpu_din =  pia_dout;
		pia1_cs: cpu_din =  pia1_dout;
		io_cs:   cpu_din =  io_out;
		default: cpu_din =  8'hff;
	endcase
end

/*
Dragon 64 has two hardware changes to access more I/O

cpu_addr[2] is used as a select between the pia and the ACIA serial

pia_portb_out[2] switches between the rom and alternative rom chip
*/

assign pia_cs = dragon64 ? pia_64_cs : pia_orig_cs ;             

wire pia_64_cs= ~cpu_addr[2] & pia_orig_cs;
wire acia_cs = cpu_addr[2] &  pia_orig_cs ;

/* because of the tristate nature of the real hardware, and one pin having a resistor
   pulling it high, we wired the output of DDRB2 to this logic, and it seems to swap 
	ROM banks correctly now. A bit of a hack, but it seems to work.
*/
wire rom8_1_cs = rom8_cs & (~DDRB[2] | pia1_portb_out[2]);
wire romA_1_cs = romA_cs & (~DDRB[2] | pia1_portb_out[2]);
wire rom8_2_cs = rom8_cs & DDRB[2] & ~pia1_portb_out[2];
wire romA_2_cs = romA_cs & DDRB[2] & ~pia1_portb_out[2];
reg [7:0] cpu_din64;

always_comb begin
	unique case (1'b1)
		ram_cs:     cpu_din64 =  ram_dout;
		rom8_1_cs:  cpu_din64 =  rom8_64_1;
		rom8_2_cs:  cpu_din64 =  rom8_64_2;
		romA_1_cs:  cpu_din64 =  romA_64_1;
		romA_2_cs:  cpu_din64 =  romA_64_2;
		romC_cs:    cpu_din64 =  romC_dout;
		acia_cs:    cpu_din64 =  acia_dout;
		pia_cs:     cpu_din64 =  pia_dout;
		pia1_cs:    cpu_din64 =  pia1_dout;
		io_cs:      cpu_din64 =  io_out;
		default:    cpu_din64 =  8'hff;
	endcase
end

mc6809is cpu(
	.CLK(clk),
	.D(dragon64?cpu_din64:cpu_din),
	.DOut(cpu_dout),
	.ADDR(cpu_addr),
	.RnW(cpu_rw),
	.fallE_en(clk_E_en),
	.fallQ_en(clk_Q_en),
	.BS(),
	.BA(),
	.nIRQ(~irq),
	.nFIRQ(~firq),
	.nNMI(~nmi),
	.AVMA(),
	.BUSY(),
	.LIC(),
	.nHALT(dragon ? 1'b1 : ~halt),
	.nRESET(reset_n),
	.nDMABREQ(1)
);

dpram #(.addr_width_g(16), .data_width_g(8)) ram1(
	.clock_a(clk),
	.address_a(sam_a),
	.data_a(cpu_dout),
	.q_a(ram_dout),
	.wren_a(~sam_we_n),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(16'h71),
	.data_b( 8'h00),
	.wren_b(hard_reset),
	.q_b()
);

// 8k extended basic rom
// Do we need an option to enable/disable extended basic rom?
assign rom8_dout = dragon ? rom8_dout_dragon : rom8_dout_tandy;
wire [7:0] rom8_dout_dragon;
wire [7:0] rom8_dout_tandy;

dpram #(.addr_width_g(13), .data_width_g(8)) rom8_tandy(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(rom8_dout_tandy),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 1),
	.q_b()
);

dpram #(.addr_width_g(13), .data_width_g(8)) rom8_dragon(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(rom8_dout_dragon),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 3),
	.q_b()
);

assign romA_dout = dragon ? romA_dout_dragon : romA_dout_tandy;
wire [7:0] romA_dout_dragon;
wire [7:0] romA_dout_tandy;

// 8k color basic rom
dpram #(.addr_width_g(13), .data_width_g(8)) romA_tandy(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(romA_dout_tandy),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 0),
	.q_b()
);

dpram #(.addr_width_g(13), .data_width_g(8)) romA_dragon(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(romA_dout_dragon),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 4),
	.q_b()
);

//
// Dragon 64 has two banks of 16k roms. We split them into 
// 4 banks of 8. Not sure this is the best idea..
// 
wire [7:0] rom8_64_1;
wire [7:0] rom8_64_2;
wire [7:0] romA_64_1;
wire [7:0] romA_64_2;

dpram #(.addr_width_g(13), .data_width_g(8)) romA_d64_1(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(romA_64_1),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 6),
	.q_b()
);

dpram #(.addr_width_g(13), .data_width_g(8)) rom8_d64_1(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(rom8_64_1),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 5),
	.q_b()
);

dpram #(.addr_width_g(13), .data_width_g(8)) romA_d64_2(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(romA_64_2),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 8),
	.q_b()
);

dpram #(.addr_width_g(13), .data_width_g(8)) rom8_d64_2(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(rom8_64_2),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 7),
	.q_b()
);

reg cart_loaded = 0;
always @(posedge clk)
	if (ioctl_cart & ioctl_download & ~ioctl_wr)
		cart_loaded <= ioctl_addr > 15'h100;
	else if (cart_remove)
		cart_loaded <= 0;

dpram #(.addr_width_g(14), .data_width_g(8)) romC(
	.clock_a(clk),
	.address_a(cpu_addr[13:0]),
	.q_a(romC_cart_dout),
	.enable_a(romC_cs),

	.clock_b(clk),
	.address_b(ioctl_addr[13:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_cart)
);

/*dragon_dsk*/
dpram #(.addr_width_g(13), .data_width_g(8)) rom_disk_dragon(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(romC_dragondisk_dout),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 9),
	.q_b()
);

dpram #(.addr_width_g(13), .data_width_g(8)) rom_disk_tandy(
	.clock_a(clk),
	.address_a(cpu_addr[12:0]),
	.data_a(),
	.q_a(romC_disk_dout),
	.wren_a(1'b0),
	.enable_a(1'b1),
	.enable_b(1'b1),

	.clock_b(clk),
	.address_b(ioctl_addr[12:0]),
	.data_b(ioctl_data),
	.wren_b(ioctl_wr & ioctl_rom & ioctl_addr[16:13] == 2),
	.q_b()
);

assign romC_dout = cart_loaded ? romC_cart_dout : disk_cart_enabled ? (dragon ? romC_dragondisk_dout : romC_disk_dout) : 8'hFF;

wire [2:0] s_device_select;

wire da0;
wire [7:0] ma_ram_addr;
wire ras_n, cas_n,sam_we_n;
reg [15:0] sam_a;
reg ras_n_r;
reg cas_n_r;

always @(posedge clk)
begin
	if (clk_enable)
	begin
		if (ras_n & ~ras_n_r) vdg_data <= ram_dout;

		if (~ras_n & ras_n_r)
			sam_a[7:0]<= ma_ram_addr;
		if (~cas_n & cas_n_r)
			sam_a[15:8] <= ma_ram_addr;

		ras_n_r <= ras_n;
		cas_n_r <= cas_n;
	end
end

mc6883 sam(
	.clk(clk),
	.clk_ena(clk_enable),
	.reset(~reset_n),
	.por(por),

	//-- input
	.addr(cpu_addr),
	.rw_n(cpu_rw),

	//-- vdg signals
	.da0(da0),
	.hs_n(hs_n),
	.vclk(),
	.vclk_en_p(vclk_en_p),
	.vclk_en_n(vclk_en_n),

	//-- peripheral address selects
	.s_device_select(s_device_select),

	//-- clock generation
	.clk_e(clk_E),
	.clk_q(clk_Q),
	.clk_e_en(clk_E_en),
	.clk_q_en(clk_Q_en),

	//-- dynamic addresses
	.z_ram_addr(ma_ram_addr),

	//-- ram
	.ras0_n(ras_n),
	.cas_n(cas_n),
	.we_n(sam_we_n),

	.dbg()//sam_dbg
);

always @(*) begin
	io_cs = 0;
	pia1_cs = 0;
	pia_orig_cs = 0;
	romC_cs = 0;
	romA_cs = 0;
	rom8_cs = 0;
	ram_cs = 0;
	case(s_device_select)
		0: ram_cs = 1;
		1: rom8_cs = 1;
		2: romA_cs = 1;
		3: romC_cs = 1;
		4: pia_orig_cs = 1;
		5: pia1_cs = 1;
		6: io_cs = 1;
	default: ;
	endcase
end

wire fs_n;
wire hs_n;
wire pia_irq;

pia6520 pia(
	.data_out(pia_dout),
	.data_in(cpu_dout),
	.addr(cpu_addr[1:0]),
	.strobe(pia_cs),
	.we(we),
	.irq(pia_irq),
	.porta_in(kb_rows),
	.porta_out(),
	.portb_in(),
	.portb_out(kb_cols),
	.ca1_in(hs_n),
	.ca2_in(),
	.cb1_in(fs_n),  
	.cb2_in(),
	.ca2_out(sela), // used for joy & snd
	.cb2_out(selb), // used for joy & snd
	.clk(clk),
	.clk_ena(clk_enable),
	.reset(~reset_n)
);

assign irq = pia_irq | (dragon64 & ~acia_irq_n);

wire casdin0;
wire rsout1;
wire [5:0] dac_data;
wire sela,selb;
wire snden;
// 1 bit sound
assign sndout = pia1_portb_out[1];
wire [7:0] DDRB;
wire cart_n = (disk_cart_enabled & dragon) ? fdc_drq : (clk_Q | ~cart_loaded);

pia6520 pia1(
	.data_out(pia1_dout),
	.data_in(cpu_dout),
	.addr(cpu_addr[1:0]),
	.strobe(pia1_cs),
	.we(we),
	.irq(firq),
	.porta_in({7'd0,casdout}),
	.porta_out({dac_data,casdin0,rsout1}),
	.portb_in(dragon?8'b00000001:{5'd0, mem64kb ? kb_cols[5] : 1'b1, 1'b0, uart_rx}),
	.portb_out(pia1_portb_out),
	.DDRB(DDRB),
	.ca1_in(1'b1), // from dragon64 schematic - this should be held high
	.ca2_in(),
	.cb1_in(cart_n), // cartridge inserted
	.cb2_in(),
	.ca2_out(cas_relay),
	.cb2_out(snden),
	.clk(clk),
	.clk_ena(clk_enable),
	.reset(~reset_n)
);

mc6847 vdg(
	.clk(clk),
	.clk_ena(vclk_en_p | vclk_en_n),
	.reset(~reset_n),
	.da0(da0),
	.dd(vdg_data),
	.hs_n(hs_n),
	.fs_n(fs_n),
	.an_g(pia1_portb_out[7]), // PIA1 port B
	.an_s(vdg_data[7]),
	.intn_ext(pia1_portb_out[4]),
	.gm(pia1_portb_out[6:4]), // [2:0] pin 6 (gm2),5 (gm1) & 4 (gm0) PIA1 port B
	.css(pia1_portb_out[3]),
	.inv(vdg_data[6]),
	.red(red),
	.green(green),
	.blue(blue),
	.hsync(hsync),
	.vsync(vsync),
	.hblank(hblank),
	.vblank(vblank),
	.artifact_enable(artifact_enable),
	.artifact_set(1'b0),
	.artifact_phase(artifact_phase),
	.overscan(overscan),

	.pixel_clock(vclk)

);

// hilo comes from the dac as the comparator 
// of whether the joystick value is higher or lower than the amount being probed
// we need to pass it through the keyboard matrix so it flows into here
wire hilo;
keyboard kb(
	.clk_sys(clk),
	.reset(~reset_n),
	.dragon(dragon),
	.key_strobe(key_strobe),
	.key_pressed(key_pressed),
	.key_extended(key_extended),
	.key_code(key_code),
	.addr(kb_cols),
	.kb_rows(kb_rows),
	.kblayout(kblayout),
	.Fn(),
	.modif(),
	.joystick_1_button(joy1[4]),
	.joystick_2_button(joy2[4]),
	.joystick_hilo(hilo)
);

// the DAC isn't really a DAC but represents the DAC chip on the schematic. 
// All the signals have been digitized before it gets here.

reg [15:0] dac_joya1;
reg [15:0] dac_joya2;

//	Limits for joysticks - set to total limits 0,255 SRH 6/5/24
always @(posedge clk) begin

	if (joy_use_dpad)
	begin
		dac_joya1[15:8] <= 8'd128;
		dac_joya1[7:0]  <= 8'd128;

		dac_joya2[15:8] <= 8'd128;
		dac_joya2[7:0]  <= 8'd128;

		if (joy1[0])	// right
			dac_joya1[15:8] <= 8'd255;

		if (joy1[1])	// left
			dac_joya1[15:8] <= 8'd0;

		if (joy1[2])	// down
			dac_joya1[7:0] <= 8'd255;

		if (joy1[3])	// up
			dac_joya1[7:0] <= 8'd0;

		if (joy2[0])	// right
			dac_joya2[15:8] <= 8'd255;

		if (joy2[1])	// left
			dac_joya2[15:8] <= 8'd0;

		if (joy2[2])	// down
			dac_joya2[7:0] <= 8'd255;

		if (joy2[3])	// upimg_mounted
			dac_joya2[7:0] <= 8'd0;
	end
	else
	begin
		dac_joya1 <= joya1;
		dac_joya2 <= joya2;
	end
end

trs80_dac dac(
	.clk(clk),
	.joya1(dac_joya1),
	.joya2(dac_joya2),
	.dac(dac_data),
	.cass_snd(cass_snd),
	.snden(snden),
	.snd(),
	.hilo(hilo),
	.selb(selb),
	.sela(sela),
	.sound(sound)
);

//dragon 64 has a serial module wired in based on addr[2]
wire [7:0] acia_dout;
wire       acia_tx;
wire       acia_irq_n;
wire       clk_en_18432;

CEGen #(.SYSTEM_CLOCK(32'd57_272_272), .OUT_CLOCK(32'd1_843_200)) CEGen_acia(~reset_n, clk, clk_en_18432);

gen_uart_mos_6551 mos_6551 (
	.reset(~reset_n),
	.clk(clk),
	.clk_en(clk_en_18432),
	.din(cpu_dout),
	.dout(acia_dout),
	.rnw(cpu_rw),
	.cs(acia_cs & clk_E),
	.rs(cpu_addr[1:0]),
	.irq_n(acia_irq_n),
	.cts_n(1'b0),
	.dcd_n(1'b0),
	.dsr_n(1'b0),
	.dtr_n(),
	.rts_n(),
	.rx(uart_rx),
	.tx(acia_tx)
);

assign uart_tx = dragon64 ? acia_tx : !dragon ? rsout1 : 1'b1;
//
//  Floppy Controller Support
//
wire clk_en_8M;
CEGen #(.SYSTEM_CLOCK(32'd57_272_272), .OUT_CLOCK(32'd8_000_000)) CEGen_fdc(~reset_n, clk, clk_en_8M);

wire [7:0] fdc_dout;
reg  [3:0] fdc_drive_sel;
reg        fdc_motor;
reg        fdc_precomp;
reg        fdc_dden;
reg        fdc_nmi_en;
reg        fdc_halt_en;

wire       fdc_ctrl_write = disk_cart_enabled & clk_E & io_cs & !cpu_rw & (~cpu_addr[3] ^ dragon);
wire       fdc_sel = disk_cart_enabled & clk_E & io_cs & (cpu_addr[3] ^ dragon) & (!dragon | ~cpu_addr[2]);
wire       fdc_irq, fdc_drq;

assign io_out = fdc_dout;

always @(posedge clk) begin
	if (~reset_n) 
		{fdc_drive_sel, fdc_motor, fdc_precomp, fdc_dden, fdc_halt_en, fdc_nmi_en} <= 0;
	else begin
		if (fdc_ctrl_write) begin
			if (dragon) begin
				case (cpu_dout[1:0])
					0: fdc_drive_sel <= 4'b0001;
					1: fdc_drive_sel <= 4'b0010;
					2: fdc_drive_sel <= 4'b0100;
					3: fdc_drive_sel <= 4'b1000;
				endcase
				fdc_motor <= cpu_dout[2];
				fdc_dden <= cpu_dout[3];
				fdc_precomp <= cpu_dout[4];
				fdc_nmi_en <= cpu_dout[5];
			end else begin
				fdc_drive_sel <= {cpu_dout[6], cpu_dout[2:0]};
				fdc_motor <= cpu_dout[3];
				fdc_precomp <= cpu_dout[4];
				fdc_dden <= cpu_dout[5];
				fdc_halt_en <= cpu_dout[7];
			end
		end

		if (fdc_irq) fdc_halt_en <= 0; // only CoCo has halt ctrl
	end
end

assign nmi = (fdc_dden & fdc_irq & !dragon) | (fdc_nmi_en & fdc_irq & dragon);
assign halt = !dragon & fdc_halt_en & !fdc_drq;

fdc1772 #(.FD_NUM(4), .MODEL(3), .EXT_MOTOR(1'b1)) wd1793 (

	.clkcpu         ( clk             ),
	.clk8m_en       ( clk_en_8M       ),

	.cpu_sel        ( fdc_sel         ),
	.cpu_rw         ( cpu_rw          ),
	.cpu_addr       ( cpu_addr[1:0]   ),
	.cpu_dout       ( fdc_dout        ),
	.cpu_din        ( cpu_dout        ),

	.irq            ( fdc_irq         ),
	.drq            ( fdc_drq         ),

	.img_type       ( 3'd6            ), // CoCo single side, 18 sectors/track
	.img_mounted    ( img_mounted     ),
	.img_size       ( img_size        ),
	.img_wp         ( img_wp          ),
	.sd_lba         ( sd_lba          ),
	.sd_rd          ( sd_rd           ),
	.sd_wr          ( sd_wr           ),
	.sd_ack         ( sd_ack          ),
	.sd_buff_addr   ( sd_buff_addr    ),
	.sd_dout        ( sd_buff_dout    ),
	.sd_din         ( sd_buff_din     ),
	.sd_dout_strobe ( sd_buff_wr      ),

	.floppy_drive	( ~fdc_drive_sel   ),
	.floppy_motor	( fdc_motor        ),
//	.floppy_inuse	( floppy_inuse     ),
	.floppy_side	( 1'b1             ),
//	.floppy_density ( floppy_density   ),
	.floppy_reset	( reset_n          )
);

assign ledb = ~(ioctl_download | fdc_motor);

endmodule
