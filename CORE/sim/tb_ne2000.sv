// Testbench for CORE/sv/ne2000_z486.sv (the NE2000: georgemog's ao486 port of apolkosnik's
// Minimig model, ne2k_host.sv as its network side) behind z486's iobus_adapter.sv with its
// io_hold and io_cpu_be (the patched copy in CORE/gen), with a model of eth_mac.vhd's streams
// on a 50 MHz clock. The steps a DOS packet driver takes (Crynwr NE2000.COM's order): reset,
// the PROM, the ring, the station address, start; then frames out and in, by words (OUTSW /
// INSW), doublewords and bytes. Checks the bytes on the wire and in the ring, the filter (the
// card's address and broadcast; others and bad FCS dropped), IRQ 10, a full ring (OVW), at
// most 4 frames waiting while the card is stopped, no old frames after a reset, the TX slots
// reused while the MAC is slow, and the menu's off. Prints "ok ..." per check, "FAIL ..."
// and at the end PASS or FAILED. Run by run_ne2000.sh.
`timescale 1ns/1ps
`default_nettype none

module tb_ne2000;
    localparam int CLK_HZ = 64_000_000;
    reg clk = 0;
    always #7.8125 clk = ~clk;             // 64 MHz
    reg clk50 = 0;
    always #10 clk50 = ~clk50;             // 50 MHz (RMII)

    integer fails = 0;
    task automatic check(input bit cond, input string what);
        if (cond) $display("ok   %s", what);
        else begin $display("FAIL %s", what); fails++; end
    endtask

    localparam [47:0] MAC   = 48'h02_12_34_56_78_9A;
    localparam [47:0] BCAST = 48'hFF_FF_FF_FF_FF_FF;
    localparam [47:0] OTHER = 48'h02_AA_BB_CC_DD_EE;
    localparam [47:0] SRC   = 48'h02_11_22_33_44_55;

    // ------------------------------------------------------------------------------------------
    // The adapter and the card
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
    wire [7:0] io_writedata, ne_readdata;
    wire [3:0] io_cpu_be;
    wire ne_hold, irq;
    wire ne_cs = enable && io_address[15:5] == 11'h018;       // 300-31F

    iobus_adapter adapter (
        .clk(clk), .reset_n(reset_n),
        .cpu_addr(cpu_addr), .cpu_be(cpu_be), .cpu_din(cpu_din),
        .cpu_dout(cpu_dout), .cpu_io_rd(cpu_io_rd), .cpu_io_wr(cpu_io_wr),
        .cpu_io_ready(cpu_io_ready), .io_address(io_address),
        .io_address_next(io_address_next), .io_address_load(io_address_load),
        .io_read(io_read), .io_write(io_write), .io_writedata(io_writedata),
        .io_readdata(ne_cs ? ne_readdata : 8'hff),
        .ide_address(), .ide_read(), .ide_write(), .ide_writedata(), .ide_readdata(32'd0),
        .ide_32(), .ide_hold(1'b0), .direct_readdata(8'hff), .direct_handled(1'b0),
        .io_hold(ne_hold), .io_cpu_be(io_cpu_be)
    );

    reg         rst50 = 1;
    reg         m_rx_start = 0, m_rx_valid = 0, m_rx_end = 0, m_rx_ok = 0;
    reg   [7:0] m_rx_byte = 0;
    wire        tx_start;
    wire [10:0] tx_len;
    reg  [10:0] m_tx_addr = 0;
    wire  [7:0] tx_data;
    wire        m_tx_busy;

    ne2000_z486 #(.CLK_HZ(CLK_HZ)) dut (
        .clk(clk), .reset(!reset_n), .enable(enable),
        .io_cs(ne_cs), .io_address(io_address), .io_read(io_read), .io_write(io_write),
        .io_writedata(io_writedata), .io_cpu_be(io_cpu_be), .io_readdata(ne_readdata),
        .io_hold(ne_hold), .irq(irq), .mac(MAC),
        .clk50(clk50), .rst50(rst50),
        .rx_start(m_rx_start), .rx_valid(m_rx_valid), .rx_byte(m_rx_byte), .rx_end(m_rx_end),
        .rx_ok(m_rx_ok),
        .tx_start(tx_start), .tx_len(tx_len), .tx_addr(m_tx_addr), .tx_data(tx_data),
        .tx_busy(m_tx_busy)
    );

    // ------------------------------------------------------------------------------------------
    // eth_mac's transmit side: takes tx_start when idle, reads the frame by address (the data a
    // clock after the address), then stays busy for the gap (tx_gap clocks: long = a slow MAC)
    // ------------------------------------------------------------------------------------------
    reg   [7:0] cap_mem [0:32767];          // 16 frames x 2 KB
    integer     cap_len [0:15];
    integer     cap_n = 0;
    integer     tx_gap = 12;
    reg   [1:0] mt_st = 0;
    integer     mt_n = 0, mt_g = 0;
    assign m_tx_busy = (mt_st != 0);

    always @(posedge clk50) begin
        case (mt_st)
            0: if (tx_start) begin mt_st <= 1; mt_n <= tx_len; m_tx_addr <= 0; end
            1: begin m_tx_addr <= m_tx_addr + 1; mt_st <= 2; end
            2: begin
                cap_mem[(cap_n % 16) * 2048 + m_tx_addr - 1] <= tx_data;
                if (m_tx_addr == mt_n) begin
                    cap_len[cap_n % 16] <= mt_n;
                    cap_n <= cap_n + 1;
                    mt_g  <= tx_gap;
                    mt_st <= 3;
                end else
                    m_tx_addr <= m_tx_addr + 1;
            end
            3: if (mt_g == 0) mt_st <= 0; else mt_g <= mt_g - 1;
        endcase
    end

    // ------------------------------------------------------------------------------------------
    // eth_mac's receive side: a frame as bytes (dst, src, 0800h, a pattern), then 4 FCS bytes
    // (the model's: rx_ok says whether they were right), a byte every 2 clocks
    // ------------------------------------------------------------------------------------------
    function automatic [7:0] fbyte(input [47:0] dst, input integer i, input [7:0] seed);
        if (i < 6)       fbyte = dst[47 - 8 * i -: 8];
        else if (i < 12) fbyte = SRC[47 - 8 * (i - 6) -: 8];
        else if (i == 12) fbyte = 8'h08;
        else if (i == 13) fbyte = 8'h00;
        else             fbyte = 8'(seed + i * 7);
    endfunction

    task automatic rx_frame(input [47:0] dst, input integer len, input [7:0] seed, input bit ok);
        integer i;
        @(posedge clk50); m_rx_start <= 1;
        @(posedge clk50); m_rx_start <= 0;
        for (i = 0; i < len + 4; i++) begin
            @(posedge clk50); m_rx_valid <= 1; m_rx_byte <= (i < len) ? fbyte(dst, i, seed) : 8'hA5;
            @(posedge clk50); m_rx_valid <= 0;
        end
        @(posedge clk50); m_rx_end <= 1; m_rx_ok <= ok;
        @(posedge clk50); m_rx_end <= 0;
        repeat (30) @(posedge clk50);       // the inter-frame gap
    endtask

    // ------------------------------------------------------------------------------------------
    // The CPU's I/O (as tb_gus.sv)
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
    task automatic outw(input [15:0] v);   io_wr(16'h310, {16'd0, v}, 4'b0011); endtask
    task automatic inw(output [15:0] v);
        reg [31:0] x;
        io_rd(16'h310, 4'b0011, x);
        v = x[15:0];
    endtask

    // The DP8390's registers (page 0 unless said)
    localparam [15:0] CR = 16'h300, PSTART = 16'h301, PSTOP = 16'h302, BNRY = 16'h303,
                      TPSR = 16'h304, TBCR0 = 16'h305, TBCR1 = 16'h306, ISR = 16'h307,
                      RSAR0 = 16'h308, RSAR1 = 16'h309, RBCR0 = 16'h30A, RBCR1 = 16'h30B,
                      RCR = 16'h30C, TCR = 16'h30D, DCR = 16'h30E, IMR = 16'h30F,
                      CURR = 16'h307, RESET = 16'h31F;

    task automatic wait_isr(input [7:0] mask, input integer limit, output bit got);
        reg [7:0] v;
        integer n;
        got = 0;
        for (n = 0; n < limit && !got; n++) begin
            inb(ISR, v);
            if (v & mask) got = 1;
            else repeat (40) @(posedge clk);
        end
    endtask

    task automatic remote(input [15:0] addr, input [15:0] count, input [7:0] cmd);
        outb(RBCR0, count[7:0]); outb(RBCR1, count[15:8]);
        outb(RSAR0, addr[7:0]);  outb(RSAR1, addr[15:8]);
        outb(CR, cmd);
    endtask

    reg [7:0] next_pkt = 8'h47;            // where the next received frame starts

    task automatic init_card(input [7:0] rcr);
        reg [7:0] v;
        bit got;
        inb(RESET, v); outb(RESET, v);
        wait_isr(8'h80, 50, got);
        check(got, "reset port: ISR.RST");
        outb(CR, 8'h21);                   // page 0, stop, no DMA
        outb(DCR, 8'h49);                  // word transfers, normal, FIFO 8
        outb(RBCR0, 0); outb(RBCR1, 0);
        outb(RCR, 8'h20);                  // monitor
        outb(TCR, 8'h02);                  // internal loopback
        outb(PSTART, 8'h46); outb(PSTOP, 8'h80); outb(BNRY, 8'h46);
        outb(TPSR, 8'h40);
        outb(ISR, 8'hFF);
        outb(IMR, 8'h13);                  // PRX, PTX, OVW
        outb(CR, 8'h61);                   // page 1, stop
        outb(16'h301, MAC[47:40]); outb(16'h302, MAC[39:32]); outb(16'h303, MAC[31:24]);
        outb(16'h304, MAC[23:16]); outb(16'h305, MAC[15:8]);  outb(16'h306, MAC[7:0]);
        outb(CURR, 8'h47);
        outb(CR, 8'h22);                   // page 0, start
        outb(TCR, 8'h00);
        outb(RCR, rcr);
        next_pkt = 8'h47;
    endtask

    // A frame out: by words (OUTSW) or doublewords (OUTSD), through page 40h
    task automatic send_frame(input [47:0] dst, input integer len, input [7:0] seed, input bit dw,
                              output bit got);
        integer i;
        reg [7:0] b0, b1, b2, b3;
        remote(16'h4000, len[15:0], 8'h12);
        if (dw)
            for (i = 0; i < len; i += 4) begin
                b0 = fbyte(dst, i, seed); b1 = fbyte(dst, i + 1, seed);
                b2 = fbyte(dst, i + 2, seed); b3 = fbyte(dst, i + 3, seed);
                io_wr(16'h310, {b3, b2, b1, b0}, 4'b1111);
            end
        else
            for (i = 0; i < len; i += 2) outw({fbyte(dst, i + 1, seed), fbyte(dst, i, seed)});
        wait_isr(8'h40, 50, got);          // RDC
        outb(ISR, 8'h40);
        outb(TPSR, 8'h40);
        outb(TBCR0, len[7:0]); outb(TBCR1, len[15:8]);
        outb(CR, 8'h26);                   // transmit
        wait_isr(8'h02, 5000, got);        // PTX (a slot waiting for a slow MAC holds it)
        outb(ISR, 8'h02);
    endtask

    // The next frame from the ring: its header, then its bytes compared with what was sent
    task automatic recv_frame(input [47:0] dst, input integer len, input [7:0] seed,
                              output bit good, output [7:0] status);
        reg [15:0] w;
        reg [7:0] nxt;
        integer cnt, i, bad;
        remote({next_pkt, 8'h00}, 16'd4, 8'h0A);
        inw(w); status = w[7:0]; nxt = w[15:8];
        inw(w); cnt = w;
        bad = 0;
        if (cnt != len + 4) bad++;
        remote({next_pkt, 8'h04}, 16'(len + (len & 1)), 8'h0A);
        for (i = 0; i < len; i += 2) begin
            inw(w);
            if (w[7:0] != fbyte(dst, i, seed)) bad++;
            if (i + 1 < len && w[15:8] != fbyte(dst, i + 1, seed)) bad++;
        end
        good = (bad == 0);
        if (!good) $display("     frame at %02h: count %0d (want %0d), %0d bytes wrong", next_pkt, cnt, len + 4, bad);
        next_pkt = nxt;
        outb(BNRY, (nxt == 8'h46) ? 8'h7F : nxt - 8'h01);
    endtask

    // The stand-in holding a write into a TX slot that still waits for the MAC
    integer tx_holds = 0;
    always @(posedge clk) if (dut.host.tx_hold) tx_holds <= tx_holds + 1;

    function automatic bit cap_is(input integer k, input [47:0] dst, input integer len, input [7:0] seed);
        integer i;
        cap_is = (cap_len[k % 16] == len);
        for (i = 0; i < len; i++)
            if (cap_mem[(k % 16) * 2048 + i] != fbyte(dst, i, seed)) cap_is = 0;
    endfunction

    // ------------------------------------------------------------------------------------------
    // The test
    // ------------------------------------------------------------------------------------------
    initial begin
        reg [7:0] v, st;
        reg [15:0] w;
        bit got, good, allgood;
        integer i, k, n0;

        repeat (10) @(posedge clk50); rst50 = 0;
        repeat (10) @(posedge clk); reset_n = 1;
        repeat (400) @(posedge clk);       // the card's start-up (it reads the address then)

        init_card(8'h04);                  // accept broadcast

        // The PROM: the station address, each byte twice (read by words)
        remote(16'h0000, 16'd12, 8'h0A);
        allgood = 1;
        for (i = 0; i < 6; i++) begin
            inw(w);
            if (w[7:0] != MAC[47 - 8 * i -: 8] || w[15:8] != MAC[47 - 8 * i -: 8]) allgood = 0;
        end
        check(allgood, "PROM: the station address from the host (DNA-style 02:..)");
        outb(ISR, 8'h40);

        // A frame out by words, one by doublewords
        repeat (300) @(posedge clk);       // the card's first heartbeat poll (a host is there)
        send_frame(BCAST, 100, 8'h11, 0, got);
        check(got, "TX: PTX after a 100-byte frame (words)");
        wait (cap_n == 1); repeat (5) @(posedge clk50);
        check(cap_is(0, BCAST, 100, 8'h11), "TX: the frame on the wire, byte for byte");
        send_frame(OTHER, 64, 8'h22, 1, got);
        wait (cap_n == 2); repeat (5) @(posedge clk50);
        check(got && cap_is(1, OTHER, 64, 8'h22), "TX: a 64-byte frame by doublewords");
        send_frame(OTHER, 1514, 8'h33, 0, got);
        wait (cap_n == 3); repeat (5) @(posedge clk50);
        check(got && cap_is(2, OTHER, 1514, 8'h33), "TX: a 1514-byte frame");

        // Frames in: to the card, broadcast; another address and a bad FCS dropped
        rx_frame(MAC, 98, 8'h40, 1);
        wait_isr(8'h01, 100, got);
        check(got, "RX: PRX for a frame to the card");
        check(irq, "RX: IRQ with PRX in IMR");
        recv_frame(MAC, 98, 8'h40, good, st);
        check(good && st == 8'h21, "RX: header and bytes in the ring");
        outb(ISR, 8'h01);
        repeat (5) @(posedge clk);
        check(!irq, "RX: IRQ gone with ISR cleared");

        rx_frame(OTHER, 98, 8'h41, 1);
        rx_frame(MAC, 120, 8'h42, 0);
        rx_frame(BCAST, 333, 8'h43, 1);
        wait_isr(8'h01, 100, got);
        recv_frame(BCAST, 333, 8'h43, good, st);
        check(got && good, "RX: another address and a bad FCS dropped, broadcast taken");
        outb(ISR, 8'h01);
        outb(CR, 8'h62); inb(CURR, v); outb(CR, 8'h22);
        check(v == next_pkt, "RX: CURR where the next frame goes");

        // Odd lengths and the ring wrapping round (46h-7Fh: 58 pages)
        allgood = 1;
        for (k = 0; k < 24; k++) begin
            rx_frame(MAC, 601 + k * 3, 8'(8'h50 + k), 1);
            wait_isr(8'h01, 100, got);
            recv_frame(MAC, 601 + k * 3, 8'(8'h50 + k), good, st);
            outb(ISR, 8'h01);
            if (!got || !good) allgood = 0;
        end
        check(allgood, "RX: 24 frames of odd lengths, the ring wrapped twice");

        // Byte transfers (DCR byte mode): a remote write and read by single bytes
        outb(DCR, 8'h48);
        remote(16'h4000, 16'd6, 8'h12);
        for (i = 0; i < 6; i++) outb(16'h310, 8'(8'hC0 + i));
        outb(ISR, 8'h40);
        remote(16'h4000, 16'd6, 8'h0A);
        allgood = 1;
        for (i = 0; i < 6; i++) begin inb(16'h310, v); if (v != 8'(8'hC0 + i)) allgood = 0; end
        check(allgood, "byte mode: remote DMA by single bytes");
        outb(ISR, 8'h40);
        outb(DCR, 8'h49);

        // A full ring: frames until no page is free, nothing read meanwhile -> OVW
        for (k = 0; k < 18; k++) rx_frame(MAC, 1000, 8'(8'h70 + k), 1);
        repeat (2000) @(posedge clk);
        inb(ISR, v);
        check(v[4], "RX: a full ring sets OVW");
        // the driver's overflow recovery: stop, empty the ring, start
        outb(CR, 8'h21);
        outb(ISR, 8'hFF);
        outb(CR, 8'h61); outb(CURR, 8'h47); outb(CR, 8'h21);
        outb(BNRY, 8'h46);
        outb(CR, 8'h22);
        next_pkt = 8'h47;

        // Stopped: at most 4 frames wait in the host, then they come in order
        outb(CR, 8'h21);
        repeat (200) @(posedge clk);
        outb(ISR, 8'hFF);
        for (k = 0; k < 7; k++) rx_frame(MAC, 80, 8'(8'h90 + k), 1);
        repeat (500) @(posedge clk);
        inb(ISR, v);
        check(!v[0], "stopped: no frame delivered");
        outb(CR, 8'h22);
        wait_isr(8'h01, 100, got);         // one PRX: all 4 are in the ring at once
        repeat (2000) @(posedge clk);
        outb(ISR, 8'h01);
        allgood = got;
        for (k = 0; k < 4; k++) begin      // read until BNRY + 1 = CURR, as a driver does
            recv_frame(MAC, 80, 8'(8'h90 + k), good, st);
            if (!good) begin allgood = 0; $display("     waiting frame %0d not intact", k); end
        end
        inb(ISR, v);
        outb(CR, 8'h62); inb(CURR, st); outb(CR, 8'h22);
        if (v[0] || st != next_pkt) $display("     after them: ISR %02h, CURR %02h, next %02h", v, st, next_pkt);
        check(allgood && !v[0] && st == next_pkt, "started: the 4 waiting frames, the rest dropped");

        // A reset while frames wait: none of them is delivered after it
        outb(CR, 8'h21);
        repeat (200) @(posedge clk);
        for (k = 0; k < 3; k++) rx_frame(MAC, 70, 8'(8'hA0 + k), 1);
        init_card(8'h04);
        repeat (2000) @(posedge clk);
        inb(ISR, v);
        check(!v[0], "reset: the frames waiting before it are gone");
        rx_frame(MAC, 77, 8'hB0, 1);
        wait_isr(8'h01, 100, got);
        recv_frame(MAC, 77, 8'hB0, good, st);
        outb(ISR, 8'h01);
        check(got && good, "reset: the next frame comes");

        // A slow MAC: 10 frames, the 9th and 10th reuse slots that wait to be sent
        tx_gap = 30000;                    // 600 us a frame
        n0 = cap_n;
        for (k = 0; k < 10; k++) send_frame(OTHER, 200 + k * 2, 8'(8'hC0 + k), 0, got);
        wait (cap_n == n0 + 10);
        repeat (5) @(posedge clk50);
        allgood = 1;
        for (k = 0; k < 10; k++)
            if (!cap_is(n0 + k, OTHER, 200 + k * 2, 8'(8'hC0 + k))) allgood = 0;
        check(allgood && tx_holds > 0, "TX: 10 frames through 8 slots behind a slow MAC (slot reuse held), in order and intact");
        tx_gap = 12;

        // The menu's off: nothing at 300h, no IRQ, no frames
        rx_frame(MAC, 90, 8'hD0, 1);
        wait_isr(8'h01, 100, got);
        enable = 0;
        repeat (20) @(posedge clk);
        inb(16'h300, v);
        check(v == 8'hFF && !irq, "off: 300h reads FFh, no IRQ");

        if (fails == 0) $display("PASS"); else $display("FAILED (%0d)", fails);
        $finish;
    end

    initial begin
        #100ms;
        $display("FAIL timeout"); $display("FAILED"); $finish;
    end
endmodule

`default_nettype wire
