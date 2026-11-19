//
// z486 for MEGA65: a Gravis Ultrasound (classic, 256 KB; 512 KB as a build option) on system.sv's I/O byte bus, DMA
// channel 3 and the PICs. The GF1 is LPC-GUS's die-shot model (gus/gf1.v, nukeykt,
// GPL-2.0-or-later, github.com/nukeykt/LPC-GUS d0f072f); this is the card around it, as
// LPC-GUS's gf1_lpc.v is for a PC's LPC bus: the 2x0 mix control and the 2xB IRQ/DMA latches,
// 256 KB of sample DRAM (block RAM), and the DAC's serial stream as 16-bit samples.
//
// Ports at base 240: the GF1 at 246, 248, 249, 24A, 24C, 24E and 342-345, 347 (its 4-bit
// address is the port's low nibble: the two sets don't overlap); 240 the mix control, 24B the
// latch 240 bit 6 picks (1 IRQ, 0 DMA). MIDI (340/341) isn't there; the rest read FFh.
// A classic card also decodes the AdLib ports 388/389 as the GF1's 2x8/2x9 (86Box's GUS
// too): Gravis' CARDCHK.EXE (run by INSTALL 4.11) finds the card by writing 55h/AAh to 388
// and reading them back at 2xA. Here the GF1 gets the writes there (adl_cs); reads stay the
// OPL3's (system.sv's fm_cs), so FM detection and music work beside it.
//
// Power-up state: a card after ULTRINIT with ULTRASND=240,3,3,11,11 (latches on, DMA 3,
// IRQ 11, line out on). A real card is silent until ULTRINIT; a game that skips it would be.
// The IRQ goes where the latch says (2 as 9, 3, 5, 7, 11, 12, 15), as from a card on the ISA
// bus (the same line as the Sound Blaster's is the user's clash, as on a real PC). Only DMA 3
// is wired: another DMA latch setting asks on a channel that isn't there.
//
// A GF1 access, the CPU's or the DMA's, is an ISA-like cycle: IOR/IOW (DACK1 with it for the
// DMA) for at least C_ACT clocks, while the GF1 holds WAIT (IOCHRDY: voice registers,
// DRAM peek/poke) and C_DAT clocks more (a read's byte is taken then), then C_REC clocks
// without strobes. The CPU waits in iobus_adapter.sv
// (io_hold) until its byte is in or out. dma.v acknowledges a byte for one clock, its
// terminal count (a register) comes the clock after: the byte (still on dma_readdata) and
// TC are taken then (dma_ack_d) and wait in d_pend if the bus is busy. Taking TC with the
// acknowledge missed it: the GF1 never ended the transfer, never raised its TC IRQ, and a
// player waited forever for its first upload.
//
// The DRAM DMA the other way (41h bit 1: the DRAM to the PC, Gravis Setup's playback DMA test
// reads back what it wrote): dma.v takes a device's byte (dma_writedata) as it starts the
// transfer, so the wrapper fetches the GF1's byte first (DACK1 + IOR when the GF1 asks) and
// asks the 8237 with it in hand. TC is known only after: when it comes with a byte, one more
// DACK1 + IOR carries it to the GF1 (that byte is dropped), which ends the DMA and raises the
// IRQ. Which way it goes the wrapper sees from the CPU's 41h writes (3x3 = 41h, then 3x5).
//
// Sampling (48h the rate, 49h the control) isn't in the GF1 model (its DRQ2 is 0): the wrapper
// does it, with silence (no ADC here: 80h, 00h with 49h's MSB inverted), one byte a sample
// (two in stereo) every 16 x (48h + 2) GF1 clocks, on the record DMA (the latch's second
// channel, or the first combined: DMA 3 only). The 8237's TC ends it and sets 49h bit 6 (read
// clears it), with 49h bit 5 the GF1's IRQ and 2x6 bit 7 (DMA TC). Gravis Setup's record DMA
// test samples a block this way.
//
`default_nettype none

module gus #(
    parameter int CLK_HZ = 66_000_000,
    parameter int RAM_KB = 512             // the sample DRAM: 256 (bank 0) or 512 (banks 0, 1);
                                           // 512 is 128 block RAMs: only with the L2 cut
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,             // the menu's "Gravis Ultrasound"; off: no card

    // system.sv's I/O byte bus (iobus_adapter.sv: one-clock strobes, data the clock after)
    input  wire        io_cs,              // 240-24F or 340-347 (registered with the address)
    input  wire        adl_cs,             // 388-389 (the same): the GF1 takes the writes
    input  wire [15:0] io_address,
    input  wire        io_read,
    input  wire        io_write,
    input  wire  [7:0] io_writedata,
    output reg   [7:0] io_readdata,
    output wire        io_hold,            // the adapter waits (S_WAITn) while it is high

    // DMA channel 3 (dma.v: dma_ack a clock, the byte from memory with it, TC a clock later;
    // to memory, the byte here from the request on)
    output wire        dma_req,
    input  wire        dma_ack,
    input  wire  [7:0] dma_readdata,
    input  wire        dma_tc,
    output wire  [7:0] dma_writedata,

    output reg  [15:0] irq,                // one line per PC IRQ (the latch's IRQ 2 as 9)
    output reg  [15:0] sample_l,           // the DAC's samples (two's complement)
    output reg  [15:0] sample_r,
    output wire [15:0] dbg                 // the card's IRQ and DMA state (the end of this file)
);

localparam int C_ACT = 10;                 // IOR/IOW at least (~150 ns, gf1_lpc.v's 5 LPC clocks)
localparam int C_DAT = 3;                  // after WAIT, before the data is taken (it reaches
                                           // DATA_o a clock or two after WAIT drops)
localparam int C_REC = 6;                  // then without strobes

// ---------------------------------------------------------------------------------------------
// The GF1's clock: 9.8784 MHz (its 19.7568 MHz crystal halved) as bit 16 of a phase
// accumulator on clk; gf1.v steps its phases on CLK's levels (gf1_lpc.v does it from 33 MHz)
// ---------------------------------------------------------------------------------------------
localparam longint C_INC = (64'd9_878_400 * 64'd131072 + CLK_HZ / 2) / CLK_HZ;

reg [16:0] ph = 17'd0;
always @(posedge clk)
    ph <= ph + C_INC[16:0];

// ---------------------------------------------------------------------------------------------
// The GF1
// ---------------------------------------------------------------------------------------------
reg         g_ior = 1'b0, g_iow = 1'b0, g_cs1 = 1'b0, g_dack = 1'b0, g_tc = 1'b0;
reg   [3:0] g_a = 4'd0;
reg  [15:0] g_din = 16'd0;
wire [15:0] g_dout;
wire        g_wait, g_drq, g_irq1, g_irq2;
wire  [7:0] dram_i, dram_o;
wire  [8:0] daddr;
wire        dram_we, ras;
wire  [3:0] cas;
wire        dac_data, dac_clk, dac_lr;

gf1 gf1 (
    .MCLK       (clk),
    .CLK        (ph[16]),
    .IOW        (g_iow),
    .IOR        (g_ior),
    .CS1        (g_cs1),
    .CS2        (1'b0),
    .DACK1      (g_dack),
    .DACK2      (1'b0),
    .RESET      (reset || !enable),
    .WAIT       (g_wait),
    .DRQ1       (g_drq),
    .DRQ2       (),
    .IRQ1       (g_irq1),
    .IRQ2       (g_irq2),
    .IRQ3       (),
    .DMA_TC     (g_tc),
    .DATA_i     (g_din),
    .DATA_o     (g_dout),
    .IO16       (1'b0),                    // byte accesses: 3x4 the low byte, 3x5 the high
    .ADDRESS    (g_a),
    .BUSA_LOW   (),
    .BUSA_HIGH  (),
    .DRAM_DATA_i(dram_i),
    .DRAM_DATA_o(dram_o),
    .DRAM_WE    (dram_we),
    .DRAM_RAS   (ras),
    .DRAM_ADDR  (daddr),
    .DRAM_CAS0  (cas[0]),
    .DRAM_CAS1  (cas[1]),
    .DRAM_CAS2  (cas[2]),
    .DRAM_CAS3  (cas[3]),
    .DAC_DATA   (dac_data),
    .DAC_CLK    (dac_clk),
    .DAC_LR     (dac_lr),
    .DAC_LR2    ()
);

// ---------------------------------------------------------------------------------------------
// The I/O ports and the board's registers
// ---------------------------------------------------------------------------------------------
wire       a_hi = io_address[8];           // 34x (else 24x)
wire [3:0] a_lo = io_address[3:0];
wire       a_gf1 = a_hi ? (a_lo == 4'h2 || a_lo == 4'h3 || a_lo == 4'h4 || a_lo == 4'h5 ||
                           a_lo == 4'h7)
                        : (a_lo == 4'h6 || a_lo == 4'h8 || a_lo == 4'h9 || a_lo == 4'hA ||
                           a_lo == 4'hC || a_lo == 4'hE);
wire       acc = enable && io_cs && (io_read || io_write);
wire       acc_adl = enable && adl_cs && io_write;     // 388/389: the GF1's 8/9 (a_lo)

// 2x0: 0 line in off, 1 line out off, 2 mic on, 3 latches (IRQ, DMA) on, 4 IRQs combined,
// 5 MIDI loopback, 6 2xB is the IRQ latch (else DMA). 2xB bits 2..0: IRQ 0 none, 1 IRQ 2,
// 2 5, 3 3, 4 7, 5 11, 6 12, 7 15; DMA 0 none, 1 DMA 1, 2 3, 3 5, 4 6, 5 7: bits 2..0 the
// DRAM DMA's channel, 5..3 the record DMA's, 6 both on the first. The IRQ latch the same way:
// bits 2..0 channel 1 (the GF1's interrupts), 5..3 channel 2 (MIDI's: none here), 6 both
// together on either channel's line (Linux and the GUS SDK set channel 1 and bit 6, 45h for
// IRQ 11; Gravis' Windows driver channel 2 and bit 6, 68h). 2xF (register controls, rev 3.4
// on): 2xB reaches the latches only while its bits 2..0 are 0; else it is another register
// (ULTRINIT: 6, the jumpers, 06h; the Windows driver: 5, 00h), not here.
localparam [6:0] C_MIX0 = 7'b000_1001;     // line in off, line out on, latches on
reg  [6:0] mix   = C_MIX0;
reg  [6:0] irq_l = 7'h05;                  // IRQ 11 on channel 1
reg  [6:0] dma_l = 7'h42;                  // DMA 3, recording on it too
reg  [2:0] reg_ctl = 3'd0;                 // 2xF bits 2..0
wire       dram_ch3 = dma_l[2:0] == 3'd2;
wire       rec_ch3  = dma_l[6] ? dma_l[2:0] == 3'd2 : dma_l[5:3] == 3'd2;

// What the CPU wrote to the GF1 (its register number at 3x3, then 3x5): the DRAM DMA's way
// and sampling
reg  [6:0] g_sel  = 7'd0;
reg        rd_dir = 1'b0;                  // 41h bit 1: the DRAM DMA reads the DRAM (to the PC)
reg        rd_en  = 1'b0;                  // 41h bit 0
reg  [7:0] s_rate = 8'd0;                  // 48h
reg  [7:0] s_ctl  = 8'd0;                  // 49h: 0 start, 1 stereo, 2 16 bits, 5 IRQ, 7 invert
reg        s_pend = 1'b0;                  // 49h bit 6: its TC came (reading 49h clears it)
wire       s_irq  = s_pend && s_ctl[5];

// ---------------------------------------------------------------------------------------------
// The GF1's bus: the CPU's access and the DMA's byte, one cycle at a time
// ---------------------------------------------------------------------------------------------
localparam [1:0] B_IDLE = 2'd0, B_ACT = 2'd1, B_DAT = 2'd2, B_REC = 2'd3;
reg  [1:0] bs = B_IDLE;
reg  [4:0] bcnt = 5'd0;
reg        b_dma = 1'b0;                   // this cycle is the DMA's

reg        c_pend = 1'b0;                  // the CPU's access waits for the bus
reg        c_wait = 1'b0;                  // the CPU waits: its access until its byte is in/out
reg        c_rd = 1'b0;
reg  [3:0] c_a = 4'd0;
reg  [7:0] c_d = 8'd0;
reg        d_pend = 1'b0;                  // the DMA's byte waits for the bus
reg  [7:0] d_d = 8'd0;
reg        d_tc = 1'b0;
reg        dma_ack_d = 1'b0;               // the clock after dma.v's acknowledge: TC valid
localparam [1:0] A_W = 2'd0, A_R = 2'd1, A_S = 2'd2;
reg  [1:0] ack_src = A_W;                  // whose byte it was: the DRAM's write, its read, a sample

// The DRAM DMA to the PC: the GF1's byte fetched before the 8237 is asked
reg        r_full = 1'b0;                  // it waits in r_byte for the 8237
reg  [7:0] r_byte = 8'd0;
reg        r_tc   = 1'b0;                  // the 8237's TC came: one more DACK1 + IOR carries it
reg        r_stop = 1'b0;                  // the GF1 has it: nothing more until 41h is written

// Sampling: silence every 16 x (48h + 2) GF1 clocks (ph[16]'s rising edges)
reg        o_ph    = 1'b0;
reg [12:0] s_cnt   = 13'd0;
reg  [1:0] s_avail = 2'd0;                 // bytes ready (two a stereo sample)
reg        s_done  = 1'b0;                 // the 8237's TC ended it: nothing until 49h is written
wire       s_run   = s_ctl[0] && !s_done;
wire       s_tick  = s_run && ph[16] && !o_ph && s_cnt == 13'd0;
wire [2:0] s_add   = s_tick ? (s_ctl[1] ? 3'd2 : 3'd1) : 3'd0;
wire       s_take  = dma_ack && !r_full && s_run && s_avail != 2'd0;
wire [2:0] s_sum   = {1'b0, s_avail} + s_add - {2'd0, s_take};

assign io_hold = (acc && a_gf1) || acc_adl || c_wait;

// One request per byte: none from the acknowledge until its TC is in (dma.v samples the
// request a clock late, after its own cycle); a DRAM write's also none until its byte's cycle
// is over (the GF1 drops DRQ1 at DACK1)
wire w_rdy = dram_ch3 && !rd_dir && g_drq && !d_pend && !(b_dma && bs != B_IDLE);
wire r_rdy = dram_ch3 && r_full;
wire s_rdy = rec_ch3 && s_run && s_avail != 2'd0;
assign dma_req = enable && mix[3] && (w_rdy || r_rdy || s_rdy) && !dma_ack && !dma_ack_d;
assign dma_writedata = r_full ? r_byte : (s_ctl[7] ? 8'h00 : 8'h80);

always @(posedge clk) begin
    if (reset || !enable) begin
        bs     <= B_IDLE;
        b_dma  <= 1'b0;
        c_pend <= 1'b0;
        c_wait <= 1'b0;
        d_pend <= 1'b0;
        dma_ack_d <= 1'b0;
        ack_src <= A_W;
        g_ior  <= 1'b0;
        g_iow  <= 1'b0;
        g_cs1  <= 1'b0;
        g_dack <= 1'b0;
        g_tc   <= 1'b0;
        mix    <= C_MIX0;
        irq_l  <= 7'h05;
        dma_l  <= 7'h42;
        reg_ctl <= 3'd0;
        io_readdata <= 8'hFF;
        g_sel  <= 7'd0;
        rd_dir <= 1'b0;
        rd_en  <= 1'b0;
        r_full <= 1'b0;
        r_tc   <= 1'b0;
        r_stop <= 1'b0;
        s_rate <= 8'd0;
        s_ctl  <= 8'd0;
        s_pend <= 1'b0;
        s_done <= 1'b0;
        s_avail <= 2'd0;
        s_cnt  <= 13'd0;
    end else begin
        // sampling's clock
        o_ph <= ph[16];
        if (s_run && ph[16] && !o_ph)
            s_cnt <= s_tick ? {9'(s_rate) + 9'd1, 4'hF} : s_cnt - 13'd1;    // 16 x (48h + 2) - 1
        s_avail <= s_sum > 3'd2 ? 2'd2 : s_sum[1:0];

        case (bs)
            B_IDLE:
                if (d_pend) begin
                    d_pend <= 1'b0;
                    b_dma  <= 1'b1;
                    g_dack <= 1'b1;
                    g_iow  <= 1'b1;
                    g_din  <= {8'h00, d_d};
                    g_tc   <= d_tc;
                    bcnt   <= 5'd0;
                    bs     <= B_ACT;
                end else if (c_pend) begin
                    c_pend <= 1'b0;
                    b_dma  <= 1'b0;
                    g_cs1  <= 1'b1;
                    g_a    <= c_a;
                    g_din  <= {8'h00, c_d};
                    g_ior  <= c_rd;
                    g_iow  <= !c_rd;
                    bcnt   <= 5'd0;
                    bs     <= B_ACT;
                    // what it writes (3x3: the register; 3x5: an 8-bit register's value)
                    if (!c_rd && c_a == 4'h3)
                        g_sel <= c_d[6:0];
                    if (!c_rd && c_a == 4'h5)
                        case (g_sel)
                            7'h41: begin
                                rd_dir <= c_d[1];
                                rd_en  <= c_d[0];
                                r_full <= 1'b0;
                                r_tc   <= 1'b0;
                                r_stop <= 1'b0;
                            end
                            7'h48: s_rate <= c_d;
                            7'h49: begin
                                s_ctl   <= c_d & 8'hA7;
                                s_done  <= 1'b0;
                                s_avail <= 2'd0;
                                s_cnt   <= {9'(s_rate) + 9'd1, 4'hF};
                            end
                            7'h4C: if (!c_d[0]) begin                  // the GF1's reset
                                rd_dir <= 1'b0;
                                rd_en  <= 1'b0;
                                r_full <= 1'b0;
                                r_tc   <= 1'b0;
                                r_stop <= 1'b0;
                                s_ctl  <= 8'd0;
                                s_pend <= 1'b0;
                                s_done <= 1'b0;
                                s_avail <= 2'd0;
                            end
                            default: ;
                        endcase
                end else if (dram_ch3 && mix[3] && rd_dir && rd_en && !r_stop && !r_full &&
                             g_drq && !dma_ack && !dma_ack_d) begin
                    // the GF1's next byte for the 8237 (with the 8237's TC: the last DACK)
                    b_dma  <= 1'b1;
                    g_dack <= 1'b1;
                    g_ior  <= 1'b1;
                    g_tc   <= r_tc;
                    bcnt   <= 5'd0;
                    bs     <= B_ACT;
                end
            B_ACT:
                if (bcnt != 5'(C_ACT))
                    bcnt <= bcnt + 5'd1;
                else if (!g_wait) begin
                    bcnt <= 5'd0;
                    bs   <= B_DAT;
                end
            B_DAT:
                if (bcnt != 5'(C_DAT))
                    bcnt <= bcnt + 5'd1;
                else begin
                    if (!b_dma) begin
                        if (g_ior) begin
                            if (c_a == 4'h5 && g_sel == 7'h49) begin    // sampling's control
                                io_readdata <= {s_ctl[7], s_pend, s_ctl[5:0]};
                                s_pend <= 1'b0;
                            end else if (c_a == 4'h6)                    // 2x6: DMA TC, sampling's too
                                io_readdata <= g_dout[7:0] | {s_irq, 7'd0};
                            else
                                io_readdata <= g_dout[7:0];
                        end
                        c_wait <= 1'b0;
                    end else if (g_ior) begin                            // the DRAM's byte
                        if (g_tc) begin
                            r_tc   <= 1'b0;
                            r_stop <= 1'b1;
                        end else begin
                            r_byte <= g_dout[7:0];
                            r_full <= 1'b1;
                        end
                    end
                    g_ior  <= 1'b0;
                    g_iow  <= 1'b0;
                    g_dack <= 1'b0;
                    g_tc   <= 1'b0;
                    bcnt   <= 5'd0;
                    bs     <= B_REC;
                end
            default:                       // B_REC
                if (bcnt != 5'(C_REC))
                    bcnt <= bcnt + 5'd1;
                else begin
                    g_cs1 <= 1'b0;
                    bs    <= B_IDLE;
                end
        endcase

        // the CPU's access (the adapter holds while it is the GF1's)
        if (acc_adl) begin
            c_pend <= 1'b1;
            c_wait <= 1'b1;
            c_rd   <= 1'b0;
            c_a    <= a_lo;
            c_d    <= io_writedata;
        end
        if (acc) begin
            if (a_gf1) begin
                c_pend <= 1'b1;
                c_wait <= 1'b1;
                c_rd   <= io_read;
                c_a    <= a_lo;
                c_d    <= io_writedata;
            end else begin
                io_readdata <= 8'hFF;
                if (io_write && !a_hi && a_lo == 4'h0)
                    mix <= io_writedata[6:0];
                if (io_write && !a_hi && a_lo == 4'hF)
                    reg_ctl <= io_writedata[2:0];
                if (io_write && !a_hi && a_lo == 4'hB && reg_ctl == 3'd0) begin
                    if (mix[6])
                        irq_l <= io_writedata[6:0];
                    else
                        dma_l <= io_writedata[6:0];
                end
            end
        end

        // the DMA's byte, with its TC: whose it was is settled at the acknowledge (one source
        // has a request out at a time: the DRAM DMA goes one way, sampling is the record DMA)
        dma_ack_d <= dma_ack;
        if (dma_ack) begin
            if (r_full) begin
                r_full  <= 1'b0;
                ack_src <= A_R;
            end else if (s_take)
                ack_src <= A_S;
            else
                ack_src <= A_W;
        end
        if (dma_ack_d)
            case (ack_src)
                A_R: if (dma_tc) r_tc <= 1'b1;
                A_S: if (dma_tc) begin
                    s_done <= 1'b1;
                    s_pend <= 1'b1;
                end
                default: begin
                    d_pend <= 1'b1;
                    d_d    <= dma_readdata;
                    d_tc   <= dma_tc;
                end
            endcase
    end
end

// The IRQ lines the latch picks: channel 1 the GF1's interrupts, channel 2 MIDI's (none here);
// combined (bit 6), either channel's line carries both
function automatic [15:0] irq_line(input [2:0] sel);
    case (sel)
        3'd1:    irq_line = 16'h0200;          // IRQ 2: the slave PIC's 9 on an AT
        3'd2:    irq_line = 16'h0020;
        3'd3:    irq_line = 16'h0008;
        3'd4:    irq_line = 16'h0080;
        3'd5:    irq_line = 16'h0800;
        3'd6:    irq_line = 16'h1000;
        3'd7:    irq_line = 16'h8000;
        default: irq_line = 16'h0000;
    endcase
endfunction
wire irq_ch1 = g_irq1 || g_irq2 || s_irq;
wire irq_ch2 = 1'b0;
wire irq_on1 = irq_l[6] ? (irq_ch1 || irq_ch2) : irq_ch1;
wire irq_on2 = irq_l[6] ? (irq_ch1 || irq_ch2) : irq_ch2;
reg  [15:0] irq_n;
always @(*) begin                          // ifs, not ?: (an X from gf1.v's timers right after
    irq_n = 16'd0;                         // their start stays out of the simulation's lines)
    if (irq_on1)
        irq_n = irq_n | irq_line(irq_l[2:0]);
    if (irq_on2)
        irq_n = irq_n | irq_line(irq_l[5:3]);
end
always @(posedge clk) begin
    irq <= 16'd0;
    if (enable && mix[3])
        irq <= irq_n;
end

// ---------------------------------------------------------------------------------------------
// The sample DRAM: RAM_KB of block RAM, bank 0 (CAS0: 00000h-3FFFFh) and with 512 KB bank 1
// (CAS1: 40000h-7FFFFh); the row on RAS, the column on CAS (each CAS with RAS: CAS before RAS
// is a refresh), as gf1_lpc.v. The other banks aren't there: writes go nowhere, reads give
// FFh, so the size test finds RAM_KB. The GF1 latches DRAM data over some 250 ns after CAS;
// the byte is here 4 clocks after it (the CAS edge, the address, the RAM, its output
// register; 5 with 512 KB, whose 128 block RAMs spread wider), and stays until the next CAS:
// the DMA's read latch is open up to the end of its slot, after the refresh's RAS (row 0) that
// follows it (with the RAM read at the current row, the DMA read DRAM 0's bytes).
// The RAM holds 16-bit words: a 16-bit voice reads its sample's two bytes by two CASes in one
// RAS (2n, then 2n+1), and the second byte's latch closes some 6-7 clocks after its CAS, too
// soon for 512 KB's 5. Both bytes are in the word the first CAS read, so the second comes from
// it a clock after its CAS.
// ---------------------------------------------------------------------------------------------
wire [3:0] casa = cas & {4{ras}};
reg        o_ras = 1'b0;
reg  [3:0] o_cas = 4'd0;
localparam int RAM_AB = RAM_KB == 512 ? 19 : 18;
reg  [8:0] row = 9'd0;
reg [RAM_AB-1:0] acc_a = '0;              // the CAS's address: {bank 1, row, column}
reg        here = 1'b0;                    // the CAS's bank is there
reg        dwe = 1'b0;
wire       c_here = casa[0] || (RAM_KB == 512 && casa[1]);
wire [18:0] c_addr = {casa[1], row, daddr};

always @(posedge clk) begin
    o_ras <= ras;
    o_cas <= casa;
    if (ras && !o_ras)
        row <= daddr;
    if (|(casa & ~o_cas) && o_ras) begin
        acc_a <= c_addr[RAM_AB-1:0];
        here  <= c_here;
        dwe   <= dram_we && c_here;
    end
    if (|(~casa & o_cas))
        dwe <= 1'b0;
end

(* ram_style = "block" *) reg [15:0] ram [0:RAM_KB*512-1];
reg [15:0] rq1 = 16'd0, rq2 = 16'd0, rq3 = 16'd0;
wire [RAM_AB-2:0] w_a = acc_a[RAM_AB-1:1];             // the word

// block RAM starts at 0; so does the simulation's (the GF1 reads past a loop's end too: the
// next sample to interpolate toward, which GUS software copies there)
// synthesis translate_off
initial for (int i = 0; i < RAM_KB * 512; i++) ram[i] = 16'd0;
// synthesis translate_on

always @(posedge clk) begin
    if (dwe && !acc_a[0])
        ram[w_a][7:0] <= dram_o;
    if (dwe && acc_a[0])
        ram[w_a][15:8] <= dram_o;
    rq1 <= ram[w_a];
    rq2 <= rq1;
    rq3 <= rq2;
end

wire [15:0] rqw = RAM_KB == 512 ? rq3 : rq2;
assign dram_i = !here ? 8'hFF : acc_a[0] ? rqw[15:8] : rqw[7:0];

// ---------------------------------------------------------------------------------------------
// The DAC: 16 bits a channel, MSB first on DAC_CLK; LR's falling edge ends the left word, its
// rising edge the right one (gf1_lpc.v). Line out off (2x0 bit 1) or no card: silence.
// ---------------------------------------------------------------------------------------------
reg        o_dac_clk = 1'b0, o_dac_lr = 1'b0;
reg [15:0] dsh = 16'd0, dac_l = 16'd0, dac_r = 16'd0;

always @(posedge clk) begin
    o_dac_clk <= dac_clk;
    if (dac_clk && !o_dac_clk) begin
        dsh <= {dsh[14:0], dac_data};
        if (o_dac_lr && !dac_lr)
            dac_l <= dsh;
        else if (!o_dac_lr && dac_lr)
            dac_r <= dsh;
        o_dac_lr <= dac_lr;
    end
    sample_l <= (enable && !mix[1]) ? dac_l : 16'd0;
    sample_r <= (enable && !mix[1]) ? dac_r : 16'd0;
end

// ---------------------------------------------------------------------------------------------
// For the MEGA65's debug readout (mega65.vhd's C_DEV_PC_CTL 0x000F, qmon.py status): 15 the
// card is there, 14 2x0's latches on, 13..11 the GF1's IRQ (the latch's choice for its
// interrupts: channel 1, or with bit 6 channel 2), 10 the GF1's IRQ1, 9 its IRQ2,
// 8 sampling's IRQ, 7 the GF1's DRAM DMA request, 6 ours to dma.v, 5..4 41h's direction and
// enable as written, 3 49h's start, 2..0 the DMA latch
// ---------------------------------------------------------------------------------------------
wire [2:0] irq_gf1 = irq_l[2:0] != 3'd0 ? irq_l[2:0] : irq_l[6] ? irq_l[5:3] : 3'd0;   // its line
assign dbg = {enable, mix[3], irq_gf1, g_irq1, g_irq2, s_irq, g_drq, dma_req, rd_dir, rd_en,
              s_ctl[0], dma_l[2:0]};

endmodule

`default_nettype wire
