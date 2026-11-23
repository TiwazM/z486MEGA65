// Testbench for the NE2000 (CORE/sv/ne2000_z486.sv, ne2k_host.sv) with the real MAC
// (CORE/vhdl/eth_mac.vhd: Megamiga's RMII MAC, 50 MHz + 200 MHz phase aligned) and the RMII
// pins looped back (TXD -> RXD, TX_EN -> CRS_DV), behind z486's iobus_adapter.sv (the patched
// copy in CORE/gen). A frame the PC sends leaves through the MAC (preamble, padding, FCS),
// comes back in, passes the MAC's FCS check and the host's filter and lands in the card's
// ring: broadcast, the card's own address, a short frame (padded to 60), a full-size one;
// a frame to another address doesn't come back. Prints "ok ..." per check, "FAIL ..." and
// at the end PASS or FAILED. Run by run_ne2000_eth.sh (xsim: VHDL and SystemVerilog).
`timescale 1ns/1ps
`default_nettype none

module tb_ne2000_eth;
    localparam int CLK_HZ = 64_000_000;
    reg clk = 0;
    always #7.8125 clk = ~clk;             // 64 MHz
    reg clk200 = 0;
    always #2.5 clk200 = ~clk200;          // 200 MHz
    reg clk50 = 0;
    always #10 clk50 = ~clk50;             // 50 MHz, its edges on clk200's (as the MMCM's)

    integer fails = 0;
    task automatic check(input bit cond, input string what);
        if (cond) $display("ok   %s", what);
        else begin $display("FAIL %s", what); fails++; end
    endtask

    localparam [47:0] MAC   = 48'h02_12_34_56_78_9A;
    localparam [47:0] BCAST = 48'hFF_FF_FF_FF_FF_FF;
    localparam [47:0] OTHER = 48'h02_AA_BB_CC_DD_EE;
    localparam [47:0] SRC   = 48'h02_11_22_33_44_55;

    reg reset_n = 0;
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
    wire ne_cs = io_address[15:5] == 11'h018;                 // 300-31F

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
    wire        rx_start, rx_valid, rx_end, rx_ok, tx_start, tx_busy;
    wire  [7:0] rx_byte, tx_data;
    wire [10:0] tx_len, tx_addr;
    wire  [1:0] txd;
    wire        txen;

    ne2000_z486 #(.CLK_HZ(CLK_HZ)) dut (
        .clk(clk), .reset(!reset_n), .enable(1'b1),
        .io_cs(ne_cs), .io_address(io_address), .io_read(io_read), .io_write(io_write),
        .io_writedata(io_writedata), .io_cpu_be(io_cpu_be), .io_readdata(ne_readdata),
        .io_hold(ne_hold), .irq(irq), .mac(MAC),
        .clk50(clk50), .rst50(rst50),
        .rx_start(rx_start), .rx_valid(rx_valid), .rx_byte(rx_byte), .rx_end(rx_end),
        .rx_ok(rx_ok),
        .tx_start(tx_start), .tx_len(tx_len), .tx_addr(tx_addr), .tx_data(tx_data),
        .tx_busy(tx_busy)
    );

    // the MAC, its RMII pins looped back
    eth_mac mac (
        .clk50_i(clk50), .clk200_i(clk200), .rst_i(rst50),
        .phy_rxd_i(txd), .phy_crsdv_i(txen), .phy_txd_o(txd), .phy_txen_o(txen),
        .rx_phase_i(2'b01), .tx_phase_i(2'b01),
        .rx_start_o(rx_start), .rx_valid_o(rx_valid), .rx_byte_o(rx_byte), .rx_end_o(rx_end),
        .rx_ok_o(rx_ok),
        .tx_start_i(tx_start), .tx_len_i(tx_len), .tx_addr_o(tx_addr), .tx_data_i(tx_data),
        .tx_busy_o(tx_busy)
    );

    integer rx_frames = 0, rx_good = 0;
    always @(posedge clk50) if (rx_end) begin rx_frames++; if (rx_ok) rx_good++; end

    function automatic [7:0] fbyte(input [47:0] dst, input integer i, input [7:0] seed);
        if (i < 6)       fbyte = dst[47 - 8 * i -: 8];
        else if (i < 12) fbyte = SRC[47 - 8 * (i - 6) -: 8];
        else if (i == 12) fbyte = 8'h08;
        else if (i == 13) fbyte = 8'h00;
        else             fbyte = 8'(seed + i * 7);
    endfunction

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

    reg [7:0] next_pkt = 8'h47;

    task automatic send_frame(input [47:0] dst, input integer len, input [7:0] seed, output bit got);
        integer i;
        remote(16'h4000, 16'(len + (len & 1)), 8'h12);
        for (i = 0; i < len; i += 2) outw({fbyte(dst, i + 1, seed), fbyte(dst, i, seed)});
        wait_isr(8'h40, 50, got);
        outb(ISR, 8'h40);
        outb(TPSR, 8'h40);
        outb(TBCR0, len[7:0]); outb(TBCR1, len[15:8]);
        outb(CR, 8'h26);
        wait_isr(8'h02, 5000, got);
        outb(ISR, 8'h02);
    endtask

    // The next frame from the ring: count (want: the bytes on the wire, at least 60) and the
    // bytes that were sent (the padding after them isn't compared)
    task automatic recv_frame(input [47:0] dst, input integer len, input [7:0] seed,
                              output bit good);
        reg [15:0] w;
        reg [7:0] nxt;
        integer cnt, i, bad, wire_len;
        wire_len = (len < 60) ? 60 : len;
        remote({next_pkt, 8'h00}, 16'd4, 8'h0A);
        inw(w); nxt = w[15:8];
        inw(w); cnt = w;
        bad = (cnt != wire_len + 4);
        remote({next_pkt, 8'h04}, 16'(len + (len & 1)), 8'h0A);
        for (i = 0; i < len; i += 2) begin
            inw(w);
            if (w[7:0] != fbyte(dst, i, seed)) bad++;
            if (i + 1 < len && w[15:8] != fbyte(dst, i + 1, seed)) bad++;
        end
        good = (bad == 0);
        if (!good) $display("     frame at %02h: count %0d (want %0d), %0d wrong", next_pkt, cnt, wire_len + 4, bad);
        next_pkt = nxt;
        outb(BNRY, (nxt == 8'h46) ? 8'h7F : nxt - 8'h01);
    endtask

    task automatic loop(input [47:0] dst, input integer len, input [7:0] seed, input string what);
        bit got, good;
        send_frame(dst, len, seed, got);
        wait_isr(8'h01, 400, got);
        if (got) recv_frame(dst, len, seed, good);
        outb(ISR, 8'h01);
        check(got && good, what);
    endtask

    initial begin
        reg [7:0] v;
        bit got;
        integer f0;

        repeat (20) @(posedge clk50); rst50 = 0;
        repeat (10) @(posedge clk); reset_n = 1;
        repeat (400) @(posedge clk);

        inb(RESET, v); outb(RESET, v);
        wait_isr(8'h80, 50, got);
        outb(CR, 8'h21);
        outb(DCR, 8'h49);
        outb(RBCR0, 0); outb(RBCR1, 0);
        outb(RCR, 8'h20);
        outb(TCR, 8'h02);
        outb(PSTART, 8'h46); outb(PSTOP, 8'h80); outb(BNRY, 8'h46);
        outb(TPSR, 8'h40);
        outb(ISR, 8'hFF);
        outb(IMR, 8'h13);
        outb(CR, 8'h61);
        outb(16'h301, MAC[47:40]); outb(16'h302, MAC[39:32]); outb(16'h303, MAC[31:24]);
        outb(16'h304, MAC[23:16]); outb(16'h305, MAC[15:8]);  outb(16'h306, MAC[7:0]);
        outb(CURR, 8'h47);
        outb(CR, 8'h22);
        outb(TCR, 8'h00);
        outb(RCR, 8'h04);
        repeat (300) @(posedge clk);

        loop(BCAST, 100, 8'h11, "loopback: a broadcast frame out and back in, byte for byte");
        check(rx_good == 1 && rx_frames == 1, "loopback: the MAC's FCS right");
        loop(MAC, 1514, 8'h22, "loopback: a 1514-byte frame to the card's own address");
        loop(MAC, 42, 8'h33, "loopback: a 42-byte frame (an ARP's size), padded to 60");
        f0 = rx_frames;
        send_frame(OTHER, 64, 8'h44, got);
        repeat (3000) @(posedge clk);
        inb(ISR, v);
        check(rx_frames == f0 + 1 && !v[0], "loopback: a frame to another address not taken");
        loop(BCAST, 333, 8'h55, "loopback: the next broadcast still comes");

        if (fails == 0) $display("PASS"); else $display("FAILED (%0d)", fails);
        $finish;
    end

    initial begin
        #20ms;
        $display("FAIL timeout"); $display("FAILED"); $finish;
    end
endmodule

`default_nettype wire
