// Testbench for CORE/sv/gus.sv (the Gravis Ultrasound around LPC-GUS's gf1.v) behind z486's
// iobus_adapter.sv with its io_hold (the patched copy in CORE/gen): the GUS SDK's steps by
// I/O ports at base 240 (Gravis' CARDCHK search through 388h, reset, active voices, the DRAM
// size test, DRAM poke/peek, a DMA upload through system.sv's dma.v with the 8237 programmed
// as the GUS SDK does, a looping voice heard at the DAC, a voice register read back, the
// wave-end IRQ, an AdLib-style timer), then the menu's "off". Prints "ok ..." per check,
// "FAIL ..." and at the end PASS or FAILED. Run by run_gus.sh.
`timescale 1ns/1ps
`default_nettype none

module tb_gus;
    localparam int CLK_HZ = 66_000_000;
    reg clk = 0;
    always #7.576 clk = ~clk;              // 66 MHz

    integer fails = 0;
    task automatic check(input bit cond, input string what);
        if (cond) $display("ok   %s", what);
        else begin $display("FAIL %s", what); fails++; end
    endtask

    // ------------------------------------------------------------------------------------------
    // The adapter, the GUS, channel 3
    // ------------------------------------------------------------------------------------------
    reg reset_n = 0;
    reg enable = 1;
    reg [31:2] cpu_addr = 0;
    reg [3:0] cpu_be = 0;
    reg [31:0] cpu_din = 0;
    wire [31:0] cpu_dout;
    reg cpu_io_rd = 0, cpu_io_wr = 0;
    wire cpu_io_ready;
    wire [15:0] io_address, io_address_next;
    wire io_address_load, io_read, io_write;
    wire [7:0] io_writedata, gus_readdata;
    wire gus_hold;
    wire gus_cs = enable && (io_address[15:4] == 12'h024 || io_address[15:3] == 13'h068);
    wire adl_cs = enable && io_address[15:1] == 15'h01C4;     // 388/389: the GF1 sees writes
    wire opl_cs = io_address[15:2] == 14'h00E2;               // 388-38B: the OPL3 answers reads
    wire dma_s_cs = io_address[15:4] == 12'h000;              // the 8237s (dma.v below)
    wire dma_p_cs = io_address[15:4] == 12'h008;
    wire dma_m_cs = io_address[15:5] == 11'h006;
    wire [7:0] dma_io_rd;

    iobus_adapter adapter (
        .clk(clk), .reset_n(reset_n),
        .cpu_addr(cpu_addr), .cpu_be(cpu_be), .cpu_din(cpu_din),
        .cpu_dout(cpu_dout), .cpu_io_rd(cpu_io_rd), .cpu_io_wr(cpu_io_wr),
        .cpu_io_ready(cpu_io_ready), .io_address(io_address),
        .io_address_next(io_address_next), .io_address_load(io_address_load),
        .io_read(io_read), .io_write(io_write), .io_writedata(io_writedata),
        .io_readdata(gus_cs ? gus_readdata : opl_cs ? 8'h06 :            // 06h: an OPL3's status
                     (dma_s_cs || dma_p_cs || dma_m_cs) ? dma_io_rd : 8'hff),
        .ide_address(), .ide_read(), .ide_write(), .ide_writedata(), .ide_readdata(32'd0),
        .ide_32(), .ide_hold(1'b0), .direct_readdata(8'hff), .direct_handled(1'b0),
        .io_hold(gus_hold)
    );

    wire        dma_req, dma_ack, dma_tc;
    wire  [7:0] dma_rd, dma_wd;
    wire [15:0] irq, sample_l, sample_r;

`ifdef GUS512
    localparam int GUS_KB = 512;           // run_gus.sh 512
`else
    localparam int GUS_KB = 256;
`endif
    gus #(.CLK_HZ(CLK_HZ), .RAM_KB(GUS_KB)) gus (
        .clk(clk), .reset(!reset_n), .enable(enable),
        .io_cs(gus_cs), .adl_cs(adl_cs), .io_address(io_address), .io_read(io_read), .io_write(io_write),
        .io_writedata(io_writedata), .io_readdata(gus_readdata), .io_hold(gus_hold),
        .dma_req(dma_req), .dma_ack(dma_ack), .dma_readdata(dma_rd), .dma_tc(dma_tc),
        .dma_writedata(dma_wd),
        .irq(irq), .sample_l(sample_l), .sample_r(sample_r)
    );

    // DMA channel 3: system.sv's dma.v (the two 8237s, z486_MiSTer/src/soc/dma.v) at its ports
    // 00-0F, 80-8F, C0-DF, and a memory that answers a read a few clocks later. The bytes the
    // upload takes are at 12340h-1243Fh (page 1); others read EEh. dma.v acknowledges a byte for
    // a clock and gives its TC the clock after: the stand-in this bench had before sent both
    // together and hid that the wrapper missed TC (the board's players waited forever)
    wire [23:0] mem_address;
    wire        mem_16bit, mem_read, mem_write;
    wire [15:0] mem_writedata;
    reg         mem_rdv = 0;
    reg  [15:0] mem_rdata = 0;
    reg   [2:0] mem_wait = 0;
    reg  [23:0] mem_a = 0;
    reg   [7:0] dma_buf [0:255];
    reg   [7:0] wbuf [0:511];          // what the DMA writes to 12500h-126FFh
    integer     dma_reads = 0, dma_tcs = 0, dma_writes = 0, dma_wout = 0;

    dma dma (
        .clk(clk), .rst_n(reset_n),
        .io_address(io_address[4:0]), .io_read(io_read), .io_readdata(dma_io_rd),
        .io_write(io_write), .io_writedata(io_writedata),
        .io_master_cs(dma_m_cs), .io_slave_cs(dma_s_cs), .io_page_cs(dma_p_cs),
        .mem_address(mem_address), .mem_16bit(mem_16bit), .mem_waitrequest(1'b0),
        .mem_read(mem_read), .mem_readdatavalid(mem_rdv), .mem_readdata(mem_rdata),
        .mem_write(mem_write), .mem_writedata(mem_writedata),
        .dma_0_req(1'b0), .dma_0_ack(), .dma_0_tc(), .dma_0_readdata(), .dma_0_writedata(8'h00),
        .dma_1_req(1'b0), .dma_1_ack(), .dma_1_tc(), .dma_1_readdata(), .dma_1_writedata(8'h00),
        .dma_2_req(1'b0), .dma_2_ack(), .dma_2_tc(), .dma_2_readdata(), .dma_2_writedata(8'h00),
        .dma_3_req(dma_req), .dma_3_ack(dma_ack), .dma_3_tc(dma_tc), .dma_3_readdata(dma_rd),
        .dma_3_writedata(dma_wd),
        .dma_5_req(1'b0), .dma_5_ack(), .dma_5_tc(), .dma_5_readdata(), .dma_5_writedata(16'h0000),
        .dma_6_req(1'b0), .dma_6_ack(), .dma_6_tc(), .dma_6_readdata(), .dma_6_writedata(16'h0000),
        .dma_7_req(1'b0), .dma_7_ack(), .dma_7_tc(), .dma_7_readdata(), .dma_7_writedata(16'h0000)
    );

    always @(posedge clk) begin
        mem_rdv <= 0;
        if (mem_read && mem_wait == 0) begin
            mem_wait  <= 3'd3;
            mem_a     <= mem_address;
            dma_reads <= dma_reads + 1;
        end else if (mem_wait > 1)
            mem_wait <= mem_wait - 3'd1;
        else if (mem_wait == 1) begin
            mem_wait  <= 0;
            mem_rdv   <= 1;
            mem_rdata <= {8'h00, (mem_a >= 24'h012340 && mem_a < 24'h012440) ?
                                 dma_buf[8'(mem_a - 24'h012340)] : 8'hEE};
        end
        if (dma_tc) dma_tcs <= dma_tcs + 1;
        if (mem_write) begin
            dma_writes <= dma_writes + 1;
            if (mem_address >= 24'h012500 && mem_address < 24'h012700)
                wbuf[9'(mem_address - 24'h012500)] <= mem_writedata[7:0];
            else
                dma_wout <= dma_wout + 1;
        end
    end

    // ------------------------------------------------------------------------------------------
    // The CPU's I/O (as tb_ide.sv)
    // ------------------------------------------------------------------------------------------
    task automatic io_wr(input [15:0] port, input [31:0] value, input [3:0] be);
        @(negedge clk);
        cpu_addr = port[15:2]; cpu_be = be; cpu_din = value; cpu_io_wr = 1;
        do @(posedge clk); while (!cpu_io_ready);
        @(negedge clk); cpu_io_wr = 0;
        repeat (2) @(posedge clk);
    endtask
    task automatic io_rd(input [15:0] port, input [3:0] be, output [31:0] value);
        @(negedge clk);
        cpu_addr = port[15:2]; cpu_be = be; cpu_io_rd = 1;
        do @(posedge clk); while (!cpu_io_ready);
        value = cpu_dout;
        @(negedge clk); cpu_io_rd = 0;
        repeat (2) @(posedge clk);
    endtask
    task automatic outb(input [15:0] port, input [7:0] v);
        io_wr(port, {4{v}}, 4'b0001 << port[1:0]);
    endtask
    task automatic inb(input [15:0] port, output [7:0] v);
        reg [31:0] x;
        io_rd(port, 4'b0001 << port[1:0], x);
        v = 8'(x >> (port[1:0] * 8));
    endtask
    // 3x4 as a word: the adapter makes it 3x4 (low byte), then 3x5 (high byte)
    task automatic outw344(input [15:0] v);
        io_wr(16'h344, {16'd0, v}, 4'b0011);
    endtask
    task automatic inw344(output [15:0] v);
        reg [31:0] x;
        io_rd(16'h344, 4'b0011, x);
        v = x[15:0];
    endtask

    // the GF1's registers (3x3 the number, 3x4/3x5 the data; 3x2 the voice)
    task automatic wr16(input [7:0] r, input [15:0] v); outb(16'h343, r); outw344(v); endtask
    task automatic wr8(input [7:0] r, input [7:0] v);   outb(16'h343, r); outb(16'h345, v); endtask
    task automatic rd16(input [7:0] r, output [15:0] v); outb(16'h343, r); inw344(v); endtask
    task automatic rd8(input [7:0] r, output [7:0] v);  outb(16'h343, r); inb(16'h345, v); endtask
    task automatic voice(input [4:0] n); outb(16'h342, {3'd0, n}); endtask
    task automatic poke(input [19:0] a, input [7:0] v);
        wr16(8'h43, a[15:0]); wr8(8'h44, {4'd0, a[19:16]}); outb(16'h347, v);
    endtask
    task automatic peek(input [19:0] a, output [7:0] v);
        wr16(8'h43, a[15:0]); wr8(8'h44, {4'd0, a[19:16]}); inb(16'h347, v);
    endtask
    task automatic us(input integer n); repeat (n * 66) @(posedge clk); endtask

    // a voice's address registers: high = bits 19..7 in 12..0, low = bits 6..0 in 15..9
    task automatic vaddr(input [7:0] r_hi, input [19:0] a);
        wr16(r_hi, {3'd0, a[19:7]}); wr16(r_hi + 8'd1, {a[6:0], 9'd0});
    endtask

    // ------------------------------------------------------------------------------------------
    // The DAC: each frame's left and right words as the wrapper decodes them
    // ------------------------------------------------------------------------------------------
    integer frames = 0;
    reg signed [15:0] fl [0:4095];
    reg signed [15:0] fr [0:4095];
    reg rec = 0;
    always @(posedge clk)
        if (gus.dac_clk && !gus.o_dac_clk && !gus.o_dac_lr && gus.dac_lr) begin
            if (rec && frames < 4096) begin
                fl[frames] <= gus.dac_l;
                fr[frames] <= gus.dsh;     // the right word, complete at this edge
                frames <= frames + 1;
            end
        end

    // ------------------------------------------------------------------------------------------
    // The test
    // ------------------------------------------------------------------------------------------
    localparam int PER = 32;               // the sample's period in bytes
    integer i, k, t0, t1, n_up, first_up, last_up, ups, maxl, maxr, ok_dma, q;
    reg [7:0] b, mid;
    reg [15:0] w;
    reg [31:0] x;
    real per;

    initial begin
        repeat (20) @(posedge clk);
        reset_n = 1;
        repeat (20) @(posedge clk);

        // unclaimed ports in the range, and the menu's card being there
        inb(16'h241, b);
        check(b == 8'hFF, "241h (no register) reads FFh");

        // Gravis' CARDCHK.EXE (INSTALL 4.11), as a card fresh from power-up meets it: 55h to
        // 388, read back at base+0Ah for bases 220-260; AAh to 388 by a word OUT (389 gets
        // 00h); A5h to base+8, read back at base+0Ah. Then base+106h: FFh is a classic card
        // before rev 3.7 (its table: type 2)
        k = 0;
        outb(16'h388, 8'h55);
        for (i = 16'h220; i <= 16'h260 && k == 0; i += 16'h10) begin
            inb(16'(i + 16'hA), b);
            if (b == 8'h55) begin
                io_wr(16'h388, 32'h0000_00AA, 4'b0011);
                inb(16'(i + 16'hA), b);
                if (b == 8'hAA) begin
                    outb(16'(i + 16'h8), 8'hA5);
                    inb(16'(i + 16'hA), b);
                    if (b == 8'hA5) k = i;
                end
            end
        end
        check(k == 16'h240, $sformatf("CARDCHK's search finds the card at %03Xh", k));
        inb(16'h346, b);
        check(b == 8'hFF, $sformatf("base+106h reads FFh: a classic card, before rev 3.7 (%02Xh)", b));
        inb(16'h388, b);
        check(b == 8'h06, $sformatf("388h reads stay the OPL3's (%02Xh)", b));

        // reset (4Ch: 0 = master reset, then run), as UltraReset
        wr8(8'h4C, 8'h00); us(20);
        wr8(8'h4C, 8'h01); us(20);
        wr8(8'h0E, 8'hC0 | 8'd13);         // 14 active voices: 44.1 kHz
        us(10);
        rd8(8'h8E, b);
        check(b[4:0] == 5'd13, $sformatf("active voices read back: %02Xh", b));

        // the DRAM size test: bank 0 is there (and bank 1 with 512 KB), the next isn't,
        // nothing aliases
        poke(20'h00000, 8'hAA);
        poke(20'h00001, 8'h55);
        poke(20'h40000, 8'h5A);
        poke(20'h80000, 8'hA5);
        peek(20'h00000, b); check(b == 8'hAA, $sformatf("DRAM 00000h holds AAh (%02Xh)", b));
        peek(20'h00001, b); check(b == 8'h55, $sformatf("DRAM 00001h holds 55h (%02Xh)", b));
        peek(20'h40000, b);
        if (GUS_KB == 512) check(b == 8'h5A, $sformatf("DRAM 40000h (bank 1) holds 5Ah (%02Xh)", b));
        else               check(b == 8'hFF, $sformatf("DRAM 40000h (bank 1) reads FFh (%02Xh)", b));
        peek(20'h80000, b); check(b == 8'hFF, $sformatf("DRAM 80000h (bank 2) reads FFh (%02Xh)", b));
        if (GUS_KB == 512) begin
            poke(20'h7FFFF, 8'h3C);
            peek(20'h7FFFF, b); check(b == 8'h3C, $sformatf("DRAM 7FFFFh (bank 1's last byte) holds 3Ch (%02Xh)", b));
            peek(20'h3FFFF, b);
            poke(20'h3FFFF, 8'hC3);
            peek(20'h7FFFF, b); check(b == 8'h3C, $sformatf("bank 0's last byte doesn't alias bank 1's (%02Xh)", b));
        end
        peek(20'h3FFFF, b);
        poke(20'h3FFFF, 8'hC3);
        peek(20'h3FFFF, b); check(b == 8'hC3, $sformatf("DRAM 3FFFFh (the last byte) holds C3h (%02Xh)", b));
        peek(20'h00000, b); check(b == 8'hAA, "bank 1's write didn't reach bank 0");

        // a voice register read back (the hold: the GF1 reads it from its voice RAM)
        voice(5'd3);
        wr16(8'h01, 16'h1234);
        rd16(8'h81, w);
        check(w[15:1] == 15'h091A, $sformatf("voice 3's frequency reads back 1234h, bit 0 unused (%04Xh)", w));
        voice(5'd7);
        wr16(8'h01, 16'hBEEE);
        voice(5'd3);
        rd16(8'h81, w);
        check(w[15:1] == 15'h091A, $sformatf("voice 3's stays when voice 7's is written (%04Xh)", w));

        // a DMA upload of a square-ish wave (period PER, signed bytes) to 01000h
        for (i = 0; i < 256; i++)
            dma_buf[i] = (i % PER) < PER / 2 ? 8'd100 : 8'd156;     // +100, -100
        // the 8237s as the BIOS leaves them (channel 4, the cascade, unmasked), then channel 3
        // as the GUS SDK sets it up: single mode, memory to I/O, 12340h, 256 bytes
        outb(16'h0D4, 8'h00);              // master: channel 4 unmasked
        outb(16'h00A, 8'h07);              // mask channel 3
        outb(16'h00C, 8'h00);              // clear the flip-flop
        outb(16'h00B, 8'h4B);              // single, read (memory to I/O), increment, ch 3
        outb(16'h006, 8'h40); outb(16'h006, 8'h23);    // address 2340h
        outb(16'h082, 8'h01);              // page 1
        outb(16'h007, 8'hFF); outb(16'h007, 8'h00);    // count 256 - 1
        outb(16'h00A, 8'h03);              // unmask channel 3
        wr16(8'h42, 16'h0100);             // the GF1's DMA address >> 4: 01000h
        wr8(8'h41, 8'h21);                 // enable, to DRAM, 8 bits, IRQ on TC
        t0 = $time;
        while (!irq[11] && $time - t0 < 2_000_000) us(10);
        check(dma_reads == 256, $sformatf("the DMA moved %0d bytes", dma_reads));
        check(dma_tcs == 1, $sformatf("dma.v gave one TC (%0d)", dma_tcs));
        check(irq[11], $sformatf("the DMA's TC raised IRQ 11 after %0d us (the latch's power-up choice)",
                                 ($time - t0) / 1000));
        inb(16'h008, b);
        check(b[3], $sformatf("the 8237's status shows channel 3's TC (%02Xh)", b));
        inb(16'h246, b);
        check(b[7], $sformatf("2x6 shows the DMA TC IRQ (%02Xh)", b));
        rd8(8'h41, b);
        check(b[6], $sformatf("41h reads the TC pending (%02Xh)", b));
        us(5);
        check(!irq[11], "reading 41h cleared the IRQ");
        us(50);
        check(dma_reads == 256 && !dma_req, $sformatf("no request after the last byte (%0d reads)", dma_reads));
        ok_dma = 1;
        for (i = 0; i < 256; i += 37) begin
            peek(20'h01000 + i, b);
            if (b != dma_buf[i]) ok_dma = 0;
        end
        peek(20'h010FF, b);
        if (b != dma_buf[255]) ok_dma = 0;
        check(ok_dma, "the DRAM holds the DMA's bytes");

        // the DRAM DMA the other way (Gravis Setup's playback DMA test reads back): 01000h's
        // 256 bytes to 12500h, channel 3 in write (I/O to memory) mode
        dma_tcs = 0;
        for (i = 0; i < 512; i++) wbuf[i] = 8'h11;
        outb(16'h00A, 8'h07);              // mask channel 3
        outb(16'h00C, 8'h00);
        outb(16'h00B, 8'h47);              // single, write (I/O to memory), increment, ch 3
        outb(16'h006, 8'h00); outb(16'h006, 8'h25);    // address 2500h
        outb(16'h082, 8'h01);              // page 1
        outb(16'h007, 8'hFF); outb(16'h007, 8'h00);    // count 256 - 1
        outb(16'h00A, 8'h03);              // unmask channel 3
        wr16(8'h42, 16'h0100);             // from 01000h
        wr8(8'h41, 8'h23);                 // enable, from DRAM, 8 bits, IRQ on TC
        t0 = $time;
        while (!irq[11] && $time - t0 < 2_000_000) us(10);
        check(irq[11], $sformatf("the read DMA's TC raised IRQ 11 after %0d us", ($time - t0) / 1000));
        check(dma_writes == 256 && dma_wout == 0, $sformatf("the DMA wrote %0d bytes (%0d outside)", dma_writes, dma_wout));
        check(dma_tcs == 1, $sformatf("dma.v gave one TC (%0d)", dma_tcs));
        inb(16'h246, b);
        check(b[7], $sformatf("2x6 shows the DMA TC IRQ (%02Xh)", b));
        rd8(8'h41, b);
        check(b[6] && !b[0], $sformatf("41h: TC pending, the DMA off (%02Xh)", b));
        us(5);
        check(!irq[11], "reading 41h cleared the IRQ");
        us(50);
        check(dma_writes == 256 && !dma_req, $sformatf("no request after the last byte (%0d writes)", dma_writes));
        k = 0;
        for (i = 0; i < 256; i++)
            if (wbuf[i] != dma_buf[i]) k++;
        check(k == 0 && wbuf[256] == 8'h11, $sformatf("memory holds the DRAM's bytes (%0d wrong; %02Xh %02Xh .. %02Xh, then %02Xh)",
                                                      k, wbuf[0], wbuf[1], wbuf[255], wbuf[256]));

        // sampling (the record DMA, combined on 3 at power-up): 64 bytes of silence at
        // 9.8784 MHz / (16 x (0 + 2)) = 308.7 kHz, mono, IRQ on TC
        dma_writes = 0; dma_tcs = 0;
        for (i = 0; i < 512; i++) wbuf[i] = 8'h11;
        outb(16'h00A, 8'h07);
        outb(16'h00C, 8'h00);
        outb(16'h00B, 8'h47);
        outb(16'h006, 8'h00); outb(16'h006, 8'h25);
        outb(16'h082, 8'h01);
        outb(16'h007, 8'h3F); outb(16'h007, 8'h00);    // count 64 - 1
        outb(16'h00A, 8'h03);
        wr8(8'h48, 8'd0);
        wr8(8'h49, 8'h21);                 // start, mono, 8 bits, IRQ on TC
        t0 = $time;
        while (!irq[11] && $time - t0 < 2_000_000) @(posedge clk);
        t1 = $time;
        check(irq[11], $sformatf("sampling's TC raised IRQ 11 after %0d us (64 x 3.24 us: 207)", (t1 - t0) / 1000));
        check((t1 - t0) > 195_000 && (t1 - t0) < 220_000, "at 308.7 kHz");
        check(dma_writes == 64 && dma_wout == 0 && dma_tcs == 1, $sformatf("64 bytes written, one TC (%0d, %0d outside, %0d TCs)",
                                                                         dma_writes, dma_wout, dma_tcs));
        k = 0;
        for (i = 0; i < 64; i++)
            if (wbuf[i] != 8'h80) k++;
        check(k == 0 && wbuf[64] == 8'h11, $sformatf("silence: 80h (%0d not; %02Xh, then %02Xh)", k, wbuf[0], wbuf[64]));
        inb(16'h246, b);
        check(b[7], $sformatf("2x6 shows the DMA TC IRQ (%02Xh)", b));
        rd8(8'h41, b);
        check(!b[6], $sformatf("41h's pending stays clear: it is sampling's (%02Xh)", b));
        rd8(8'h49, b);
        check(b == 8'h61, $sformatf("49h reads start, IRQ on, its TC pending (%02Xh)", b));
        us(5);
        check(!irq[11], "reading 49h cleared the IRQ");
        rd8(8'h49, b);
        check(b == 8'h21, $sformatf("49h's pending clears on read (%02Xh)", b));
        inb(16'h246, b);
        check(!b[7], $sformatf("2x6's DMA TC IRQ gone (%02Xh)", b));
        us(50);
        check(dma_writes == 64 && !dma_req, "no request after the TC");

        // stereo, MSB inverted (signed silence): two bytes a sample at 48h = 1 (205.8 kHz)
        dma_writes = 0; dma_tcs = 0;
        outb(16'h00A, 8'h07);
        outb(16'h00C, 8'h00);
        outb(16'h00B, 8'h47);
        outb(16'h006, 8'h00); outb(16'h006, 8'h25);
        outb(16'h082, 8'h01);
        outb(16'h007, 8'h3F); outb(16'h007, 8'h00);
        outb(16'h00A, 8'h03);
        wr8(8'h48, 8'd1);
        wr8(8'h49, 8'hA3);                 // start, stereo, IRQ, invert
        t0 = $time;
        while (!irq[11] && $time - t0 < 2_000_000) @(posedge clk);
        t1 = $time;
        check(irq[11] && (t1 - t0) > 145_000 && (t1 - t0) < 165_000,
              $sformatf("stereo: 32 samples at 205.8 kHz, %0d us (155)", (t1 - t0) / 1000));
        k = 0;
        for (i = 0; i < 64; i++)
            if (wbuf[i] != 8'h00) k++;
        check(dma_writes == 64 && k == 0, $sformatf("64 bytes of 00h (%0d, %0d not)", dma_writes, k));
        rd8(8'h49, b);
        wr8(8'h49, 8'h00);
        us(5);
        check(!irq[11], "sampling off");

        // Quake on a classic GUS (WinQuake snd_gus.c, GUS_Init and GUS_GetDMAPos): its 16-bit
        // stereo mix goes to the DRAM by the 8237 in auto-init mode and 41h = 41h (on, 16-bit
        // data, no IRQ); once a frame it reads 41h and, with bit 6 set, starts both again
        for (q = 0; q < 2; q++) begin
            for (i = 0; i < 256; i++) dma_buf[i] = 8'(i * 7 + q * 101);
            dma_reads = 0; dma_tcs = 0;
            outb(16'h00A, 8'h07);              // disable channel 3
            outb(16'h00B, 8'h5B);              // single, auto-init, read (memory to I/O), ch 3
            outb(16'h082, 8'h01);
            outb(16'h00C, 8'h00);
            outb(16'h006, 8'h40); outb(16'h006, 8'h23);
            outb(16'h00C, 8'h00);
            outb(16'h007, 8'hFF); outb(16'h007, 8'h00);
            outb(16'h00E, 8'h00);              // clear the masks (Quake's ClearReg)
            outb(16'h00A, 8'h03);
            wr16(8'h42, 16'h0200);             // DRAM 02000h (Quake: 0; 01000h is the voice's)
            wr8(8'h41, 8'h41);
            rd8(8'h41, mid);                   // a frame's poll while it runs
            t0 = $time;
            b = 8'h00;
            while (!b[6] && $time - t0 < 2_000_000) begin us(20); rd8(8'h41, b); end
            check(!mid[6] && b[6], $sformatf("Quake %0d: 41h bit 6 clear while it runs (%02Xh), set after %0d us (%02Xh)",
                                             q, mid, ($time - t0) / 1000, b));
            check(!irq[11], "no IRQ (41h bit 5 off)");
            us(50);
            check(dma_reads == 256 && dma_tcs == 1 && !dma_req,
                  $sformatf("256 bytes, one TC, nothing after it with the 8237 auto-init (%0d, %0d)", dma_reads, dma_tcs));
            rd8(8'h41, b);
            check(!b[6], $sformatf("reading 41h cleared bit 6 (%02Xh)", b));
            ok_dma = 1;
            for (i = 0; i < 256; i += 17) begin
                peek(20'h02000 + i, b);
                if (b != dma_buf[i]) ok_dma = 0;
            end
            peek(20'h020FF, b);
            if (b != dma_buf[255]) ok_dma = 0;
            check(ok_dma, $sformatf("Quake %0d: the DRAM holds this frame's mix", q));
        end

        // voice 0 loops the 256 bytes at one sample a frame (fc 1024), left (pan 0)
        wr8(8'h4C, 8'h03);                 // run, DAC on
        voice(5'd0);
        wr8(8'h00, 8'h03);                 // stopped
        wr16(8'h01, 16'd1024);
        vaddr(8'h02, 20'h01000);           // loop start
        vaddr(8'h04, 20'h01100);           // end: the loop jumps there, 256 bytes
        vaddr(8'h0A, 20'h01000);           // current
        wr8(8'h0C, 8'd0);                  // pan full left
        wr8(8'h0D, 8'h03);                 // no ramp
        wr16(8'h09, 16'hF800);             // volume
        wr8(8'h00, 8'h08);                 // run, 8 bits, loop
        us(200);
        rec = 1;
        while (frames < 600) @(posedge clk);
        rec = 0;
        // its period: rising edges through zero
        ups = 0; first_up = -1; last_up = -1; maxl = 0; maxr = 0;
        for (i = 1; i < 600; i++) begin
            if ($signed(fl[i - 1]) < 0 && $signed(fl[i]) >= 0) begin
                if (first_up < 0) first_up = i;
                last_up = i;
                ups++;
            end
            if ($signed(fl[i]) > maxl) maxl = $signed(fl[i]);
            if ($signed(fr[i]) > maxr) maxr = $signed(fr[i]);
        end
        per = ups > 1 ? real'(last_up - first_up) / real'(ups - 1) : 0.0;
        $display("     DAC: %0d frames, %0d rising zero crossings, period %.2f frames, peak L %0d R %0d",
                 frames, ups, per, maxl, maxr);
        for (i = 0; i < 16; i += 8)
            $display("     DAC frames %0d-%0d: L %0d %0d %0d %0d %0d %0d %0d %0d", i, i + 7,
                     fl[i], fl[i+1], fl[i+2], fl[i+3], fl[i+4], fl[i+5], fl[i+6], fl[i+7]);
        check(per > PER - 0.5 && per < PER + 0.5, $sformatf("the voice repeats every %0d frames", PER));
        check(maxl > 1000, "the left channel carries it");
        check(maxr < maxl / 4, "pan 0 keeps the right channel quiet");
        check(sample_l == gus.dac_l, "sample_l follows the DAC");
        t0 = $time; frames = 0; rec = 1;
        while (frames < 100) @(posedge clk);
        rec = 0; t1 = $time;
        per = 100.0e9 / real'(t1 - t0) / 1000.0;
        $display("     frame rate %.3f kHz", per / 1000.0 * 1000.0);
        check(per > 43.9 && per < 44.3, "14 voices: 44.1 kHz frames");

        // Quake's two voices (GUS_StartGf1): 32 voices (19.3 kHz frames), 16 bits, looping over
        // its interleaved stereo ring at fc 0800h (two 16-bit samples a frame): voice 0 the left
        // samples (pan 0), voice 1 the right ones (pan 15). Here the ring is 64 frames at DRAM
        // 03000h (16-bit address 1800h): left a square of 16 frames (+/-8000), right -3000
        for (i = 0; i < 64; i++) begin
            w = (i % 16) < 8 ? 16'd8000 : -16'sd8000;
            dma_buf[4 * i] = w[7:0]; dma_buf[4 * i + 1] = w[15:8];
            w = -16'sd3000;
            dma_buf[4 * i + 2] = w[7:0]; dma_buf[4 * i + 3] = w[15:8];
        end
        dma_reads = 0;
        outb(16'h00A, 8'h07);
        outb(16'h00B, 8'h5B);
        outb(16'h082, 8'h01);
        outb(16'h00C, 8'h00);
        outb(16'h006, 8'h40); outb(16'h006, 8'h23);
        outb(16'h00C, 8'h00);
        outb(16'h007, 8'hFF); outb(16'h007, 8'h00);
        outb(16'h00A, 8'h03);
        wr16(8'h42, 16'h0300);
        wr8(8'h41, 8'h41);
        t0 = $time; b = 8'h00;
        while (!b[6] && $time - t0 < 2_000_000) begin us(20); rd8(8'h41, b); end
        check(b[6] && dma_reads == 256, $sformatf("Quake's ring in the DRAM (%0d bytes)", dma_reads));
        voice(5'd0); wr8(8'h00, 8'h03);
        wr8(8'h0E, 8'hDF);                 // 32 voices (Quake: C0h | 31)
        for (k = 0; k < 2; k++) begin
            voice(5'(k));
            wr8(8'h00, 8'h03);
            wr8(8'h0D, 8'h03);             // no volume ramp (Quake's init sets it on all 32)
            vaddr(8'h02, 20'h01800 + k);   // start (ConvertTo16 of 0 and 2)
            vaddr(8'h0A, 20'h01800 + k);   // position
            vaddr(8'h04, 20'h0187E + k);   // end (ConvertTo16 of 252 and 254)
            wr8(8'h0C, k ? 8'd15 : 8'd0);  // pan
            wr16(8'h09, 16'hFFF0);         // volume
            wr16(8'h01, 16'h0800);         // fc: two samples a frame
        end
        voice(5'd0); wr8(8'h00, 8'h0C);    // run, 16 bits, loop
        voice(5'd1); wr8(8'h00, 8'h0C);
        us(300);
        frames = 0; rec = 1;
        while (frames < 400) @(posedge clk);
        rec = 0;
        ups = 0; first_up = -1; last_up = -1; maxl = 0; maxr = -100000; k = 100000;
        for (i = 1; i < 400; i++) begin
            if ($signed(fl[i - 1]) < 0 && $signed(fl[i]) >= 0) begin
                if (first_up < 0) first_up = i;
                last_up = i;
                ups++;
            end
            if ($signed(fl[i]) > maxl) maxl = $signed(fl[i]);
            if ($signed(fr[i]) > maxr) maxr = $signed(fr[i]);
            if ($signed(fr[i]) < k) k = $signed(fr[i]);
        end
        per = ups > 1 ? real'(last_up - first_up) / real'(ups - 1) : 0.0;
        $display("     Quake: period %.2f frames, peak L %0d, R from %0d to %0d", per, maxl, k, maxr);
        for (i = 0; i < 24; i += 8)
            $display("     frames %0d-%0d: L %0d %0d %0d %0d %0d %0d %0d %0d  R %0d %0d", i, i + 7,
                     fl[i], fl[i+1], fl[i+2], fl[i+3], fl[i+4], fl[i+5], fl[i+6], fl[i+7], fr[i], fr[i+1]);
        check(per > 15.5 && per < 16.5, "Quake: the left voice plays the left samples (16-frame square)");
        check(maxl > 7800 && maxl < 8200, "Quake: the left samples as they are (+8000; bytes swapped: 16415)");
        check(maxr < -2900 && k > -3100,
              "Quake: the right voice plays the right samples (-3000; bytes swapped: +18676)");
        t0 = $time; frames = 0; rec = 1;
        while (frames < 100) @(posedge clk);
        rec = 0; t1 = $time;
        per = 100.0e9 / real'(t1 - t0) / 1000.0;
        check(per > 19.1 && per < 19.5, $sformatf("32 voices: %.3f kHz frames (19.293)", per / 1000.0 * 1000.0));
        voice(5'd0); wr8(8'h00, 8'h03);
        voice(5'd1); wr8(8'h00, 8'h03);
        wr8(8'h0E, 8'hCD);                 // back to 14 voices

        // line out off (2x0 bit 1): silence
        outb(16'h240, 8'h0B);
        us(50);
        check(sample_l == 0 && sample_r == 0, "2x0 line out off: silence");
        outb(16'h240, 8'h09);

        // the wave end: voice 1 once through 32 bytes with its IRQ on
        voice(5'd1);
        wr8(8'h00, 8'h03);
        wr16(8'h01, 16'd1024);
        vaddr(8'h02, 20'h01000);
        vaddr(8'h04, 20'h0101F);
        vaddr(8'h0A, 20'h01000);
        wr8(8'h0D, 8'h03);
        wr8(8'h4C, 8'h07);                 // run, DAC on, IRQs on
        wr8(8'h00, 8'h20);                 // run, IRQ at the end, no loop
        t0 = $time;
        while (!irq[11] && $time - t0 < 3_000_000) us(5);
        check(irq[11], $sformatf("voice 1's end raised IRQ 11 after %0d us", ($time - t0) / 1000));
        inb(16'h246, b);
        check(b[5], $sformatf("2x6 shows a wave IRQ (%02Xh)", b));
        rd8(8'h8F, b);
        check(b[4:0] == 5'd1 && !b[7], $sformatf("8Fh: voice 1, wave (%02Xh)", b));
        us(10);
        rd8(8'h80, b);
        check(b[0], $sformatf("voice 1 stopped (%02Xh)", b));

        // voice 1's IRQ off (its control's IRQ bit), then the IRQ latch moves the line: 7
        voice(5'd1);
        wr8(8'h00, 8'h03);
        us(10);
        inb(16'h246, b);
        check(!b[5] && !irq[11], $sformatf("voice 1's wave IRQ cleared (%02Xh)", b));

        // GK: the wave IRQ's voice number in 8Fh with more voices (Gabriel Knight's speech
        // driver runs 25 and plays voice 22, a 16-bit voice); stopping it must end the IRQ
        begin : gk_voices
            int nv [6] = '{25, 25, 25, 32, 32, 14};
            int vv [6] = '{22, 21, 24, 22, 31, 13};
            for (int k = 0; k < 6; k++) begin
                wr8(8'h0E, 8'hC0 | 8'(nv[k] - 1));
                voice(5'(vv[k]));
                wr8(8'h00, 8'h03);
                wr16(8'h01, 16'd1024);
                vaddr(8'h02, 20'h02000);
                vaddr(8'h04, 20'h0201F);
                vaddr(8'h0A, 20'h02000);
                wr8(8'h0D, 8'h03);
                wr8(8'h00, 8'h24);         // run, 16-bit, IRQ at the end, no loop
                wr8(8'h00, 8'h24);
                t0 = $time;
                while (!irq[11] && $time - t0 < 3_000_000) us(5);
                inb(16'h246, b);
                rd8(8'h8F, b);
                check(irq[11] || b[7] == 1'b0, $sformatf("%0d voices, voice %0d: IRQ", nv[k], vv[k]));
                check(b[4:0] == 5'(vv[k]) && !b[7],
                      $sformatf("%0d voices, voice %0d: 8Fh says voice %0d, wave %0d (%02Xh)",
                                nv[k], vv[k], b[4:0], !b[7], b));
                voice(5'(vv[k]));
                wr8(8'h00, 8'h03);
                wr8(8'h00, 8'h03);
                us(30);
                inb(16'h246, b);
                check(!b[5] && !irq[11], $sformatf("%0d voices, voice %0d stopped: IRQ gone (2x6 %02Xh)",
                                                   nv[k], vv[k], b));
                if (b[5] || irq[11]) begin
                    for (int r = 0; r < 4; r++) begin
                        rd8(8'h8F, b);
                        $display("     8Fh again: %02Xh", b);
                        us(20);
                    end
                end
            end
            // GK's speech voice: 16-bit, LOOPING, wave IRQ on (2Ch); the handler only reads
            // 8Fh: one IRQ per pass expected (a pass of 32 samples at 1.0: ~1.3 ms at 25 voices).
            // gf1.v's own delayed clear hit the voice two slots behind: 109 IRQs in 10 ms
            // (Gabriel Knight's speech restarted without end); cleared by voice number since
            begin : loop_irq
                int n_irq; time tl;
                wr8(8'h0E, 8'hC0 | 8'd24);
                voice(5'd21);
                wr8(8'h00, 8'h03); wr8(8'h00, 8'h03);
                wr16(8'h01, 16'd1024);
                vaddr(8'h02, 20'h02000);
                vaddr(8'h04, 20'h0201F);
                vaddr(8'h0A, 20'h02000);
                wr8(8'h0D, 8'h03);
                wr8(8'h00, 8'h2C);
                wr8(8'h00, 8'h2C);
                n_irq = 0; tl = $time;
                while ($time - tl < 10_000_000) begin
                    if (irq[11]) begin
                        n_irq++;
                        rd8(8'h8F, b);
                        if (n_irq <= 4 || n_irq % 50 == 0)
                            $display("     loop IRQ %0d at %0d us: 8Fh %02Xh", n_irq, ($time - tl) / 1000, b);
                    end
                    us(5);
                end
                $display("     looping voice 21: %0d IRQs in 10 ms", n_irq);
                check(n_irq >= 5 && n_irq <= 12, $sformatf("looping voice: one IRQ per pass (%0d in 10 ms)", n_irq));
                voice(5'd21); wr8(8'h00, 8'h03); wr8(8'h00, 8'h03);
                us(30);
            end
            wr8(8'h0E, 8'hCD);             // back to 14 voices
        end
        outb(16'h240, 8'h49);              // 2xB is the IRQ latch
        outb(16'h24B, 8'h04);              // IRQ 7
        outb(16'h240, 8'h09);
        wr8(8'h46, 8'hF0);                 // timer 1: 16 x 80 us
        wr8(8'h45, 8'h04);                 // timer 1's IRQ on
        outb(16'h248, 8'h04);              // AdLib register 4
        outb(16'h249, 8'h01);              // start timer 1
        t0 = $time;
        while (!irq[7] && $time - t0 < 3_000_000) us(5);
        check(irq[7] && !irq[11], $sformatf("timer 1 raised IRQ 7 after %0d us", ($time - t0) / 1000));
        inb(16'h246, b);
        check(b[2], $sformatf("2x6 shows timer 1 (%02Xh)", b));

        // 2xF (rev 3.4 on) turns 2xB away from the latches: ULTRINIT's jumper write (2xF = 6,
        // 06h) and the Gravis Windows driver's 2xF = 5 write of 00h leave them as they were
        outb(16'h24F, 8'h06); outb(16'h240, 8'h0B); outb(16'h24B, 8'h06); outb(16'h24F, 8'h00);
        outb(16'h24F, 8'h05); outb(16'h240, 8'h4B); outb(16'h24B, 8'h00); outb(16'h24F, 8'h00);
        outb(16'h240, 8'h09);
        us(5);
        check(gus.dma_l == 7'h42 && gus.irq_l == 7'h04 && irq[7],
              $sformatf("2xF = 6 and 5: 2xB misses the latches (DMA %02Xh, IRQ %02Xh)", gus.dma_l, gus.irq_l));
        // the Windows driver's latches: DMA 42h, IRQ 68h (channel 2 = IRQ 11, channel 1 none,
        // combined): the GF1's interrupt on IRQ 11
        outb(16'h240, 8'h1B); outb(16'h24B, 8'h42);
        outb(16'h240, 8'h5B); outb(16'h24B, 8'h68);
        outb(16'h240, 8'h09);
        us(5);
        check(irq[11] && !irq[7], "IRQ latch 68h (channel 2 IRQ 11, combined): timer 1's IRQ on IRQ 11");
        // channel 1 alone, not combined, channel 2 elsewhere: the GF1's on channel 1's line only
        outb(16'h240, 8'h49); outb(16'h24B, 8'h25); outb(16'h240, 8'h09);    // ch 1 IRQ 11, ch 2 IRQ 7
        us(5);
        check(irq[11] && !irq[7], "IRQ latch 25h (not combined): the GF1's on channel 1 (IRQ 11) only");
        // Linux / the GUS SDK: 45h (channel 1 IRQ 11, combined)
        outb(16'h240, 8'h49); outb(16'h24B, 8'h45); outb(16'h240, 8'h09);
        us(5);
        check(irq[11] && !irq[7], "IRQ latch 45h (channel 1 IRQ 11, combined): IRQ 11");

        // the menu's "off": no ports, no IRQ, no sound
        enable = 0;
        us(5);
        inb(16'h246, b);
        check(b == 8'hFF && irq == 0 && sample_l == 0 && !dma_req, "off: 246h reads FFh, no IRQ, silent");

        if (fails == 0) $display("PASS");
        else $display("FAILED (%0d)", fails);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL timeout");
        $display("FAILED");
        $finish;
    end
endmodule

`default_nettype wire
