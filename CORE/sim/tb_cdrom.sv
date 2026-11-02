`timescale 1ns/1ps

// z486 for MEGA65
//
// Testbench: the CD-ROM drive. z486_MiSTer's ide.v twice (the first channel with the hard disk,
// the second with the CD-ROM drive, both through the real I/O adapter: 8-bit registers, the
// 16-bit data ports) against pc_mgmt.vhd with pc_cdrom.vhd and disk_sd.vhd, with a model of the
// SD host controller's engine port behind them. The test does what a BIOS's ATAPI probe and a
// DOS CD-ROM driver do: soft reset (the signature; the slave not there), IDENTIFY DEVICE
// (aborted), IDENTIFY PACKET DEVICE, then packets: TEST UNIT READY and REQUEST SENSE without a
// disc and after one came (UNIT ATTENTION once), INQUIRY, READ CAPACITY, READ (10) across the
// image file's two extents with a byte count limit of FFFEh and of 512, READ (12) of 40 sectors
// (one SD transfer), a READ past the end, READ TOC (LBA, MSF, the lead-out alone, sessions),
// MODE SENSE, an odd allocation length, MODE SELECT (data out), an unknown command; a hard disk
// read between two of a READ's DRQ blocks; the disc ejected. Every DRQ block and every end
// must come with an interrupt (IRQ 15). CORE/sim/run_disks.sh runs it with xsim.
//
// Licensed under GPL v3

module tb_cdrom #(
    // the engine model's pace: clocks per read byte, and clocks between a block's last byte
    // and its e_blk (the real engine: 2 and ~34, its CRC; 1 and 0: as fast as it goes)
    parameter int E_PER = 1,
    parameter int E_CRC = 0,
    // disk_sd's G_LUTRAM: 1, the ring and the write buffer in LUT RAM
    parameter int LUTRAM = 0,
    // disk_sd's G_FAULT: every FAULT-th answer's first copy reads its last byte wrong
    // (pc_cdrom must make the block again, fresh from the card; the SD read counts then differ)
    parameter int FAULT = 0
);
    reg clk = 0;
    always #7.8125 clk = ~clk;              // the PC's 64 MHz
    reg qclk = 0;
    always #10 qclk = ~qclk;                // QNICE's 50 MHz
    reg reset_n = 0;
    reg qrst = 1;

    // ------------------------------------------------------------------------------------------
    // The PC: I/O adapter, both IDE channels
    // ------------------------------------------------------------------------------------------
    reg [31:2] cpu_addr = 0;
    reg [3:0] cpu_be = 0;
    reg [31:0] cpu_din = 0;
    wire [31:0] cpu_dout;
    reg cpu_io_rd = 0, cpu_io_wr = 0;
    wire cpu_io_ready;
    wire [15:0] io_address;
    wire io_read, io_write;
    wire [7:0] io_writedata;
    wire [3:0] w_address;
    wire w_read, w_write, w_32;
    wire [31:0] w_writedata, ide0_readdata, ide1_readdata;
    wire sel0 = io_address[15:3] == (16'h1f0 >> 3) || io_address == 16'h3f6;
    wire sel1 = io_address[15:3] == (16'h170 >> 3) || io_address == 16'h376;
    iobus_adapter adapter (
        .clk(clk), .reset_n(reset_n),
        .cpu_addr(cpu_addr), .cpu_be(cpu_be), .cpu_din(cpu_din),
        .cpu_dout(cpu_dout), .cpu_io_rd(cpu_io_rd), .cpu_io_wr(cpu_io_wr),
        .cpu_io_ready(cpu_io_ready), .io_address(io_address),
        .io_read(io_read), .io_write(io_write), .io_writedata(io_writedata),
        .io_readdata(sel0 ? ide0_readdata[7:0] : sel1 ? ide1_readdata[7:0] : 8'hff),
        .ide_address(w_address), .ide_read(w_read), .ide_write(w_write),
        .ide_writedata(w_writedata), .ide_readdata(sel0 ? ide0_readdata : ide1_readdata),
        .ide_32(w_32), .ide_hold(1'b0), .direct_readdata(8'hff), .direct_handled(1'b0)
    );

    wire [15:0] mgmt_address, mgmt_writedata, mgmt_readdata, ide0_mgmt_rd, ide1_mgmt_rd;
    wire mgmt_read, mgmt_write;
    wire [2:0] ide0_request, ide1_request;
    wire irq14, irq15;
    wire wide = w_read | w_write;
    ide ide0 (
        .clk(clk), .rst_n(reset_n), .irq(irq14), .drq(),
        .use_fast(1'b1), .no_data(), .drive_en(),
        .io_address(wide ? w_address : {io_address[9], io_address[2:0]}),
        .io_read((io_read || w_read) && sel0), .io_readdata(ide0_readdata),
        .io_write((io_write || w_write) && sel0),
        .io_writedata(wide ? w_writedata : {24'd0, io_writedata}),
        .io_32(wide ? w_32 : 1'b0), .io_wait(),
        .request(ide0_request),
        .mgmt_address(mgmt_address[3:0]),
        .mgmt_write(mgmt_write && mgmt_address[15:8] == 8'hF0),
        .mgmt_writedata(mgmt_writedata),
        .mgmt_read(mgmt_read && mgmt_address[15:8] == 8'hF0),
        .mgmt_readdata(ide0_mgmt_rd)
    );
    ide ide1 (
        .clk(clk), .rst_n(reset_n), .irq(irq15), .drq(),
        .use_fast(1'b1), .no_data(), .drive_en(),
        .io_address(wide ? w_address : {io_address[9], io_address[2:0]}),
        .io_read((io_read || w_read) && sel1), .io_readdata(ide1_readdata),
        .io_write((io_write || w_write) && sel1),
        .io_writedata(wide ? w_writedata : {24'd0, io_writedata}),
        .io_32(wide ? w_32 : 1'b0), .io_wait(),
        .request(ide1_request),
        .mgmt_address(mgmt_address[3:0]),
        .mgmt_write(mgmt_write && mgmt_address[15:8] == 8'hF1),
        .mgmt_writedata(mgmt_writedata),
        .mgmt_read(mgmt_read && mgmt_address[15:8] == 8'hF1),
        .mgmt_readdata(ide1_mgmt_rd)
    );
    assign mgmt_readdata = mgmt_address[15:8] == 8'hF0 ? ide0_mgmt_rd :
                           mgmt_address[15:8] == 8'hF1 ? ide1_mgmt_rd : 16'h0001;

    // the interrupts IRQ 15 raised
    integer irqs = 0;
    always @(posedge irq15) irqs++;

    // ------------------------------------------------------------------------------------------
    // The bridge
    // ------------------------------------------------------------------------------------------
    wire sd_req, sd_req_wr, sd_done, sd_err;
    wire [1:0] sd_req_unit;
    wire [31:0] sd_req_lba;
    wire [8:0] sd_req_cnt;
    wire [8:0] buf_addr;
    wire buf_we;
    wire [7:0] buf_wd, buf_rd;
    wire buf_bad, sd_req_fresh;
    wire [159:0] mnt;
    wire [64:0] rtc_word = {1'b0, 8'h40, 8'h04, 8'h26, 8'h10, 8'h30, 8'h12, 8'h34, 8'h56};

    // the CD's track table (mega65.vhd's block RAM: the data a clock after its address)
    wire [11:0] tab_addr;
    reg  [15:0] tab_q = 0;
    reg  [15:0] tab [0:4095];
    always @(posedge clk) tab_q <= tab[tab_addr];
    wire [15:0] cd_l, cd_r;
    wire        cd_stb;
    wire [63:0] cd_stat;

    pc_mgmt #(.G_CLK_HZ(6400000)) mgmt (
        .clk_i(clk), .rst_i(!reset_n),
        .mgmt_address_o(mgmt_address), .mgmt_read_o(mgmt_read), .mgmt_write_o(mgmt_write),
        .mgmt_writedata_o(mgmt_writedata), .mgmt_readdata_i(mgmt_readdata),
        .fdd_request_i(2'b00), .ide_request_i(ide0_request), .ide1_request_i(ide1_request),
        .rtc_i(rtc_word), .mnt_i(mnt),
        .sd_req_o(sd_req), .sd_req_wr_o(sd_req_wr), .sd_req_unit_o(sd_req_unit),
        .sd_req_lba_o(sd_req_lba), .sd_req_cnt_o(sd_req_cnt), .sd_req_fresh_o(sd_req_fresh), .sd_done_i(sd_done), .sd_err_i(sd_err),
        .buf_addr_o(buf_addr), .buf_we_o(buf_we), .buf_wd_o(buf_wd), .buf_rd_i(buf_rd), .buf_bad_i(buf_bad),
        .cd_tab_addr_o(tab_addr), .cd_tab_q_i(tab_q), .cd_l_o(cd_l), .cd_r_o(cd_r), .cd_stb_o(cd_stb),
        .cd_stat_o(cd_stat)
    );

    // the CD audio's samples (from the FIFO, not silence for want of them)
    reg [15:0] aud_l [0:65535], aud_r [0:65535];
    integer naud = 0;
    always @(posedge clk) if (cd_stb && naud < 65536) begin
        aud_l[naud] = cd_l; aud_r[naud] = cd_r; naud = naud + 1;
    end

    reg [27:0] q_addr = 0;
    reg [15:0] q_wdata = 0;
    reg q_ce = 0, q_we = 0;
    wire [15:0] q_rdata;
    wire q_wait;
    wire [63:0] q2c;
    wire [75:0] c2q;
    disk_sd #(.G_QNICE_HZ(50000000), .G_LUTRAM(LUTRAM), .G_FAULT(FAULT)) sd (
        .qnice_clk_i(qclk), .qnice_rst_i(qrst),
        .qnice_addr_i(q_addr), .qnice_data_i(q_wdata), .qnice_ce_i(q_ce), .qnice_unit_i(2'b00), .qnice_we_i(q_we),
        .qnice_data_o(q_rdata), .qnice_wait_o(q_wait),
        .sd_q2c_i(q2c), .sd_c2q_o(c2q), .mnt_o(mnt),
        .req_i(sd_req), .req_wr_i(sd_req_wr), .req_unit_i(sd_req_unit), .req_lba_i(sd_req_lba),
        .req_cnt_i(sd_req_cnt), .req_fresh_i(sd_req_fresh), .done_o(sd_done), .done_err_o(sd_err),
        .main_clk_i(clk), .buf_addr_i(buf_addr), .buf_we_i(buf_we), .buf_wd_i(buf_wd),
        .buf_rd_o(buf_rd), .buf_bad_o(buf_bad)
    );

    // ------------------------------------------------------------------------------------------
    // The images, base 9000, 8 sectors per cluster. The hard disk: 200000 sectors, extents (100,
    // 10) and (500, 100000). The CD: 30000 sectors of 2048 bytes (120000 of 512), extents
    // (200000, 50) and (300000, 14950): CD sectors 0..99 in the first, 100.. in the second.
    // ------------------------------------------------------------------------------------------
    localparam integer TOTAL = 200000;
    localparam integer CDCAP = 30000;
    function automatic integer blk(input integer lba);
        integer c;
        c = lba / 8;
        blk = 9000 + ((c < 10) ? 100 + c : 500 + c - 10) * 8 + lba % 8;
    endfunction
    function automatic integer cdblk(input integer l512);
        integer c;
        c = l512 / 8;
        cdblk = 9000 + ((c < 50) ? 200000 + c : 300000 + c - 50) * 8 + l512 % 8;
    endfunction
    function automatic [7:0] sdbyte(input integer b, input integer i);
        sdbyte = 8'(b * 7 ^ i ^ (i >> 8) ^ 8'h5a);
    endfunction
    // byte i of CD sector s
    function automatic [7:0] cdbyte(input integer s, input integer i);
        cdbyte = sdbyte(cdblk(4 * s + i / 512), i % 512);
    endfunction
    // MSF of a frame count
    function automatic [23:0] msf(input integer f);
        msf = {8'(f / 4500), 8'((f / 75) % 60), 8'(f % 75)};
    endfunction
    // byte v of the virtual image (the CD's files back to back: the same extents)
    function automatic [7:0] vbyte(input integer v);
        vbyte = sdbyte(cdblk(v / 512), v % 512);
    endfunction

    // ------------------------------------------------------------------------------------------
    // The track table, as the firmware writes it (cdimage.asm; pc_cdrom.vhd has the layout)
    // ------------------------------------------------------------------------------------------
    function automatic [15:0] sw16(input [15:0] x);
        sw16 = {x[7:0], x[15:8]};
    endfunction
    task automatic tab_desc(input integer k, input integer num, input integer ctl, input integer lba);
        reg [23:0] m;
        tab[16'h100 + 4 * k] = 16'(ctl << 8); tab[16'h101 + 4 * k] = 16'(num);
        tab[16'h102 + 4 * k] = sw16(16'(lba >> 16)); tab[16'h103 + 4 * k] = sw16(16'(lba));
        m = msf(lba + 150);
        tab[16'h300 + 4 * k] = 16'(ctl << 8); tab[16'h301 + 4 * k] = 16'(num);
        tab[16'h302 + 4 * k] = {m[23:16], 8'h00}; tab[16'h303 + 4 * k] = {m[7:0], m[15:8]};
    endtask
    // track k: number, control, sector size, user data offset, flags (1 audio), its LBAs
    // (start, INDEX 01, first in its file, end of those, end) and its file's byte of fb
    task automatic tab_track(input integer k, num, ctl, ssize, off, flags, start, idx1, fb, fe, e,
                             input integer byte_);
        integer b;
        b = 16'h800 + 16 * k;
        tab[b] = 16'(num | ctl << 8); tab[b + 1] = 16'(ssize); tab[b + 2] = 16'(off); tab[b + 3] = 16'(flags);
        tab[b + 4] = 16'(start); tab[b + 5] = 16'(start >> 16);
        tab[b + 6] = 16'(idx1);  tab[b + 7] = 16'(idx1 >> 16);
        tab[b + 8] = 16'(fb);    tab[b + 9] = 16'(fb >> 16);
        tab[b + 10] = 16'(fe);   tab[b + 11] = 16'(fe >> 16);
        tab[b + 12] = 16'(e);    tab[b + 13] = 16'(e >> 16);
        tab[b + 14] = 16'(byte_); tab[b + 15] = 16'(byte_ >> 16);
        tab_desc(k, num, ctl, idx1);
    endtask
    task automatic tab_head(input integer n, first, last, lead, med, lctl);
        reg [23:0] m;
        m = msf(lead + 150);
        tab[0] = 16'(n); tab[1] = 16'(first | last << 8); tab[2] = 16'(lead); tab[3] = 16'(lead >> 16);
        tab[4] = 16'(med); tab[5] = {m[15:8], m[23:16]}; tab[6] = {8'h00, m[7:0]};
        tab_desc(n, 8'hAA, lctl, lead);
    endtask

    // The SD engine port (tb_ide's model, reads only): a START moves COUNT blocks from ADDR on,
    // block k only once k < LIMIT, ABORT ends a read at the next block boundary
    reg e_busy = 0, e_done = 0, e_err = 0, e_blk = 0, e_rdwe = 0;
    reg [8:0] e_rdidx = 0, e_wridx = 0;
    reg [7:0] e_rddata = 0;
    reg [15:0] e_rdblk = 0;
    assign q2c = {e_wridx, 16'd0, e_rddata, e_rdidx, e_rdblk, e_rdwe, e_blk, e_err, e_done,
                  e_busy, 1'b1};
    integer eng_reads = 0, eng_blocks = 0, eng_aborts = 0;
    always begin
        integer b, i, k, n;
        bit stop;
        @(posedge qclk);
        if (c2q[0]) begin
            b = c2q[34:3];
            n = c2q[50:35];
            if (c2q[1]) $fatal(1, "engine: a write");
            e_busy <= 1;
            repeat (40) @(posedge qclk);
            eng_reads++;
            stop = 0;
            for (k = 0; k < n && !stop; k++) begin
                while (!c2q[2] && k >= c2q[66:51]) @(posedge qclk);
                if (c2q[2]) begin
                    stop = 1;
                end else begin
                    e_rdblk <= k;
                    for (i = 0; i < 512; i++) begin
                        e_rdwe <= 1; e_rdidx <= i; e_rddata <= sdbyte(b + k, i);
                        @(posedge qclk);
                        if (E_PER > 1) begin e_rdwe <= 0; repeat (E_PER - 1) @(posedge qclk); end
                    end
                    e_rdwe <= 0;
                    repeat (E_CRC) @(posedge qclk);
                    e_blk <= 1; @(posedge qclk); e_blk <= 0;
                    eng_blocks++;
                    if (c2q[2]) stop = 1;
                end
            end
            if (c2q[2]) eng_aborts++;
            repeat (10) @(posedge qclk);
            e_done <= 1; @(posedge qclk); e_done <= 0; e_err <= 0;
            e_busy <= 0;
        end
    end

    // ------------------------------------------------------------------------------------------
    // QNICE writes, the PC's I/O
    // ------------------------------------------------------------------------------------------
    task automatic qwr(input [27:0] a, input [15:0] d);
        @(posedge qclk);
        q_addr <= a; q_wdata <= d; q_ce <= 1; q_we <= 1;
        @(posedge qclk);
        q_ce <= 0; q_we <= 0;
    endtask
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
    task automatic inw(input [15:0] port, output [15:0] v);
        reg [31:0] x;
        io_rd(port, 4'b0011, x);
        v = x[15:0];
    endtask
    task automatic outw(input [15:0] port, input [15:0] v);
        io_wr(port, {16'd0, v}, 4'b0011);
    endtask

    integer errors = 0;
    task automatic check(input bit ok, input string what);
        if (ok) $display("ok    %s", what);
        else begin $error("FAIL  %s", what); errors++; end
    endtask

    // the status of channel `base` once BSY is clear
    task automatic wait_ready(input [15:0] base, output [7:0] st);
        integer k;
        for (k = 0; k < 40000; k++) begin
            inb(base + 7, st);
            if (!st[7]) return;
            repeat (20) @(posedge clk);
        end
        $fatal(1, "IDE %03x: still busy, status %02x", base, st);
    endtask

    // ------------------------------------------------------------------------------------------
    // ATAPI: a packet, then its data in or out; the result as a DOS driver sees it
    // ------------------------------------------------------------------------------------------
    reg [7:0] cdb [0:11];
    reg [7:0] din [0:131071];               // the data that came in
    reg [7:0] dout [0:255];                 // the data to go out (MODE SELECT)
    integer   nout_pos;
    integer   nin;                          // its bytes
    integer   blocks;                       // DRQ blocks
    reg [7:0] r_st, r_err, r_ir;            // the end: status, error, interrupt reason
    integer   r_irqs;                       // interrupts raised during the command

    task automatic set_cdb(input [7:0] c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11);
        cdb[0] = c0; cdb[1] = c1; cdb[2] = c2; cdb[3] = c3; cdb[4] = c4; cdb[5] = c5;
        cdb[6] = c6; cdb[7] = c7; cdb[8] = c8; cdb[9] = c9; cdb[10] = c10; cdb[11] = c11;
    endtask

    // the packet with byte count limit `lim`; then DRQ blocks in (or, with `nout` > 0, out),
    // until the end; `hdd_after` > 0: a hard disk read after that many blocks
    task automatic packet(input [15:0] lim, input integer nout = 0, input integer hdd_after = 0);
        reg [7:0] st, ir, lo, hi;
        reg [15:0] w;
        integer k, n, i0;
        i0 = irqs;
        nin = 0;
        nout_pos = 0;
        blocks = 0;
        outb(16'h176, 8'ha0);
        outb(16'h171, 8'h00);               // PIO
        outb(16'h174, lim[7:0]); outb(16'h175, lim[15:8]);
        outb(16'h177, 8'ha0);
        wait_ready(16'h170, st);
        inb(16'h172, ir);
        if ((st & 8'h89) != 8'h08 || ir[1:0] != 2'b01) $fatal(1, "packet: status %02x, reason %02x", st, ir);
        for (k = 0; k < 6; k++) outw(16'h170, {cdb[2 * k + 1], cdb[2 * k]});
        forever begin
            wait_ready(16'h170, st);
            if (!st[3]) break;
            inb(16'h172, ir);
            inb(16'h174, lo); inb(16'h175, hi);
            n = {hi, lo};
            if (nout > 0) begin
                if (ir[1:0] != 2'b00) $fatal(1, "data out: reason %02x", ir);
                for (k = 0; k < (n + 1) / 2; k++) outw(16'h170, {dout[nout_pos + 2 * k + 1], dout[nout_pos + 2 * k]});
                nout_pos += n;
            end else begin
                if (ir[1:0] != 2'b10) $fatal(1, "data in: reason %02x", ir);
                for (k = 0; k < (n + 1) / 2; k++) begin
                    inw(16'h170, w);
                    din[nin] = w[7:0];
                    if (nin + 1 < nin + n - 2 * k) din[nin + 1] = w[15:8];
                    nin += (2 * k + 1 < n) ? 2 : 1;
                end
            end
            blocks++;
            if (hdd_after > 0 && blocks == hdd_after) read_hdd(1234, 2);
        end
        inb(16'h172, r_ir);
        inb(16'h171, r_err);
        r_st = st;
        r_irqs = irqs - i0;
    endtask

    // the end: done (status 40h, DRDY) or CHECK CONDITION (ERR, the sense key); interrupt
    // reason IO + CoD; an interrupt per block and one at the end
    task automatic expect_end(input string what, input integer key = 0);
        bit ok;
        if (key == 0) ok = (r_st & 8'hC9) == 8'h40;
        else ok = (r_st & 8'h89) == 8'h01 && r_err[7:4] == key[3:0];
        check(ok && r_ir[1:0] == 2'b11 && r_irqs == blocks + 1,
              $sformatf("%s: status %02x, error %02x, reason %02x, %0d blocks, %0d interrupts",
                        what, r_st, r_err, r_ir, blocks, r_irqs));
    endtask

    // REQUEST SENSE: key, ASC
    task automatic sense(output [3:0] key, output [7:0] asc);
        set_cdb(8'h03, 0, 0, 0, 18, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        key = din[2][3:0];
        asc = din[12];
    endtask

    // a hard disk read on the first channel, checked
    task automatic read_hdd(input integer lba, input integer n);
        reg [15:0] w;
        reg [7:0] st;
        integer s, k, bad;
        bad = 0;
        outb(16'h1f2, n[7:0]);
        outb(16'h1f3, lba[7:0]); outb(16'h1f4, lba[15:8]); outb(16'h1f5, lba[23:16]);
        outb(16'h1f6, 8'he0 | lba[27:24]);
        outb(16'h1f7, 8'h20);
        for (s = 0; s < n; s++) begin
            wait_ready(16'h1f0, st);
            for (k = 0; k < 256; k++) begin
                inw(16'h1f0, w);
                if (w !== {sdbyte(blk(lba + s), 2 * k + 1), sdbyte(blk(lba + s), 2 * k)}) bad++;
            end
        end
        wait_ready(16'h1f0, st);
        check(bad == 0 && (st & 8'hC9) == 8'h40,
              $sformatf("hard disk read LBA %0d-%0d (%0d words wrong, status %02x)", lba, lba + n - 1, bad, st));
    endtask

    // READ (10) / (12) of n sectors from lba, limit lim: the data checked
    task automatic cd_read(input bit r12, input integer lba, input integer n, input [15:0] lim,
                           input integer hdd_after = 0);
        integer i, bad;
        if (r12) set_cdb(8'ha8, 0, lba[31:24], lba[23:16], lba[15:8], lba[7:0], n[31:24], n[23:16], n[15:8], n[7:0], 0, 0);
        else     set_cdb(8'h28, 0, lba[31:24], lba[23:16], lba[15:8], lba[7:0], 0, n[15:8], n[7:0], 0, 0, 0);
        packet(lim, 0, hdd_after);
        bad = 0;
        for (i = 0; i < nin; i++) if (din[i] !== cdbyte(lba + i / 2048, i % 2048)) bad++;
        check(nin == n * 2048 && bad == 0, $sformatf("READ (%0d) %0d-%0d, limit %04x: %0d bytes, %0d wrong",
                                                      r12 ? 12 : 10, lba, lba + n - 1, lim, nin, bad));
        expect_end($sformatf("  its end (%0d blocks)", blocks));
    endtask


    // ------------------------------------------------------------------------------------------
    // The mixed disc: track 1 data (MODE1/2352) at 0..99, track 2 audio with its pregap in the
    // file (INDEX 00 100, INDEX 01 250) to 399, track 3 audio with a 2-sector PREGAP in no file
    // (start 400, INDEX 01 402) to 701; one raw file: LBA x at byte x * 2352 up to 399, track
    // 3's at (x - 2) * 2352
    // ------------------------------------------------------------------------------------------
    localparam integer LEAD = 702;
    function automatic integer vsec(input integer x);
        vsec = (x < 400) ? x * 2352 : (x - 2) * 2352;
    endfunction
    // the samples LBA x has (none: silence), L and R of frame j
    function automatic bit in_file(input integer x);
        in_file = x < 400 || x >= 402;
    endfunction
    function automatic [15:0] smp(input integer x, input integer j, input bit right);
        integer v;
        v = vsec(x) + 4 * j + (right ? 2 : 0);
        smp = in_file(x) ? {vbyte(v + 1), vbyte(v)} : 16'h0000;
    endfunction

    // READ of n sectors of the data track from lba, limit lim: the user data checked
    task automatic raw_read(input integer lba, input integer n, input [15:0] lim, input integer hdd_after = 0);
        integer i, bad;
        set_cdb(8'h28, 0, lba[31:24], lba[23:16], lba[15:8], lba[7:0], 0, n[15:8], n[7:0], 0, 0, 0);
        packet(lim, 0, hdd_after);
        bad = 0;
        for (i = 0; i < nin; i++) if (din[i] !== vbyte(vsec(lba + i / 2048) + 16 + i % 2048)) bad++;
        check(nin == n * 2048 && bad == 0, $sformatf("raw READ %0d-%0d, limit %04x: %0d bytes, %0d wrong, %0d blocks",
                                                      lba, lba + n - 1, lim, nin, bad, blocks));
        expect_end("  its end");
    endtask

    // PLAY AUDIO MSF from a to b (LBAs, b excluded)
    task automatic play(input integer a, input integer b);
        reg [23:0] ma, mb;
        ma = msf(a + 150); mb = msf(b + 150);
        set_cdb(8'h47, 0, 0, ma[23:16], ma[15:8], ma[7:0], mb[23:16], mb[15:8], mb[7:0], 0, 0, 0);
        packet(16'hfffe);
        expect_end($sformatf("PLAY AUDIO MSF %0d-%0d", a, b - 1));
    endtask

    // READ SUB-CHANNEL, format 1, LBA or MSF: status, track, index, absolute, relative
    reg [7:0] q_st, q_ctl, q_trk, q_idx;
    reg [31:0] q_abs, q_rel;
    task automatic subq(input bit m);
        set_cdb(8'h42, m ? 8'h02 : 8'h00, 8'h40, 8'h01, 0, 0, 0, 0, 16, 0, 0, 0);
        packet(16'hfffe);
        q_st = din[1]; q_ctl = din[5]; q_trk = din[6]; q_idx = din[7];
        q_abs = {din[8], din[9], din[10], din[11]}; q_rel = {din[12], din[13], din[14], din[15]};
    endtask

    // until the audio status is s (READ SUB-CHANNEL), at most `tries` times
    task automatic wait_status(input [7:0] s, input integer tries);
        integer k;
        for (k = 0; k < tries; k++) begin
            subq(0);
            if (q_st == s) return;
            repeat (20000) @(posedge clk);
        end
    endtask

    // the samples since index a0 against LBAs a..b-1 (silence in no file)
    task automatic check_audio(input integer a0, input integer a, input integer b, input string what,
                               input integer vol0 = 256, input bit swap = 0);
        integer x, j, k, bad, want;
        reg [15:0] el, er;
        bad = 0; k = a0;
        for (x = a; x < b; x++)
            for (j = 0; j < 588; j++) begin
                el = smp(x, j, 0); er = smp(x, j, 1);
                if (swap) begin el = smp(x, j, 1); end
                if (vol0 != 256) el = 16'(($signed(el) * vol0) >>> 8);
                if (k >= naud || aud_l[k] !== el || aud_r[k] !== er) bad++;
                k++;
            end
        // (FAULT: the streamer takes a copy that did not match as it is, a click, not again)
        check((bad == 0 || FAULT != 0) && naud == k, $sformatf("%s: %0d samples (%0d expected), %0d wrong", what,
                                                               naud - a0, k - a0, bad));
    endtask

    initial begin
        reg [7:0] v, sc, sn, cl, ch, st, er;
        reg [15:0] w, id [0:255];
        reg [3:0] key;
        reg [7:0] asc;
        integer k, n, r0, a0;
        string s;
        repeat (5) @(negedge clk);
        reset_n = 1;
        repeat (5) @(posedge qclk);
        qrst = 0;

        // the firmware's DISK_PREP for the hard disk (unit 2): map in window 2, registers 0x40
        qwr(28'h0002000, 16'd2);
        qwr(28'h0002001, 16'd100); qwr(28'h0002002, 16'd0); qwr(28'h0002003, 16'd10); qwr(28'h0002004, 16'd0);
        qwr(28'h0002005, 16'd500); qwr(28'h0002006, 16'd0); qwr(28'h0002007, 16'(100000)); qwr(28'h0002008, 16'(100000 >> 16));
        qwr(28'h0000041, 16'(TOTAL)); qwr(28'h0000042, 16'(TOTAL >> 16));
        qwr(28'h0000043, 16'd9000); qwr(28'h0000044, 16'd0);
        qwr(28'h0000045, 16'd3);
        qwr(28'h0000040, 16'd1);
        repeat (20000) @(posedge clk);

        // soft reset of the second channel, the master selected: the ATAPI signature
        outb(16'h176, 8'ha0);
        outb(16'h376, 8'h04); repeat (50) @(posedge clk); outb(16'h376, 8'h00);
        repeat (2000) @(posedge clk);
        wait_ready(16'h170, st);
        inb(16'h172, sc); inb(16'h173, sn); inb(16'h174, cl); inb(16'h175, ch);
        check(sc == 1 && sn == 1 && cl == 8'h14 && ch == 8'heb && st == 8'h00,
              $sformatf("reset, master: %02x %02x %02x %02x, status %02x", sc, sn, cl, ch, st));
        // the slave: not there
        outb(16'h176, 8'hb0);
        outb(16'h376, 8'h04); repeat (50) @(posedge clk); outb(16'h376, 8'h00);
        repeat (2000) @(posedge clk);
        wait_ready(16'h170, st);
        inb(16'h174, cl); inb(16'h175, ch);
        check(cl == 8'hff && ch == 8'hff, $sformatf("reset, slave: cylinder %02x%02x", ch, cl));

        // IDENTIFY DEVICE: aborted, the signature
        outb(16'h176, 8'ha0);
        outb(16'h177, 8'hec);
        wait_ready(16'h170, st);
        inb(16'h171, er); inb(16'h174, cl); inb(16'h175, ch);
        check((st & 8'h01) && er == 8'h04 && cl == 8'h14 && ch == 8'heb,
              $sformatf("IDENTIFY DEVICE: status %02x, error %02x, cylinder %02x%02x", st, er, ch, cl));

        // IDENTIFY PACKET DEVICE
        outb(16'h177, 8'ha1);
        wait_ready(16'h170, st);
        if ((st & 8'h89) != 8'h08) $fatal(1, "IDENTIFY PACKET DEVICE: status %02x", st);
        for (k = 0; k < 256; k++) inw(16'h170, id[k]);
        wait_ready(16'h170, st);
        check(id[0] == 16'h85C0 && id[27] == 16'h7A34 && id[49] == 16'h0200 && (st & 8'hC9) == 8'h40,
              $sformatf("IDENTIFY PACKET DEVICE: %04x, model %04x, caps %04x, status %02x", id[0], id[27], id[49], st));

        // no disc: NOT READY, MEDIUM NOT PRESENT
        set_cdb(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        expect_end("TEST UNIT READY, no disc", 2);
        sense(key, asc);
        check(key == 2 && asc == 8'h3a && nin == 18, $sformatf("  REQUEST SENSE: %0d bytes, %0x/%02x", nin, key, asc));
        expect_end("  its end");

        // the disc (DISK_PREP for unit 3: map in window 2 from 2048, registers 0x60, write
        // protected; CD_PREP's track table first: an ISO, one data track)
        tab_track(0, 1, 8'h14, 2048, 0, 0, 0, 0, 0, CDCAP, CDCAP, 0);
        tab_head(1, 1, 1, CDCAP, 1, 8'h14);
        qwr(28'h0002800, 16'd2);
        qwr(28'h0002801, 16'(200000)); qwr(28'h0002802, 16'(200000 >> 16)); qwr(28'h0002803, 16'd50); qwr(28'h0002804, 16'd0);
        qwr(28'h0002805, 16'(300000)); qwr(28'h0002806, 16'(300000 >> 16)); qwr(28'h0002807, 16'(14950)); qwr(28'h0002808, 16'd0);
        qwr(28'h0000061, 16'(CDCAP * 4)); qwr(28'h0000062, 16'((CDCAP * 4) >> 16));
        qwr(28'h0000063, 16'd9000); qwr(28'h0000064, 16'd0);
        qwr(28'h0000065, 16'd3);
        qwr(28'h0000060, 16'd5);
        repeat (2000) @(posedge clk);

        // a new disc: UNIT ATTENTION once, then ready
        set_cdb(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        expect_end("TEST UNIT READY, a new disc", 6);
        sense(key, asc);
        check(key == 6 && asc == 8'h28, $sformatf("  REQUEST SENSE: %0x/%02x", key, asc));
        set_cdb(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        expect_end("TEST UNIT READY again");

        // INQUIRY
        set_cdb(8'h12, 0, 0, 0, 36, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        s = "";
        for (k = 8; k < 36; k++) s = {s, string'(din[k])};
        check(nin == 36 && din[0] == 8'h05 && din[1] == 8'h80 && s == "z486    MEGA65 CD-ROM   1.00",
              $sformatf("INQUIRY: %0d bytes, %02x %02x '%s'", nin, din[0], din[1], s));
        expect_end("  its end");

        // READ CAPACITY
        set_cdb(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 8 && {din[0], din[1], din[2], din[3]} == CDCAP - 1 && {din[4], din[5], din[6], din[7]} == 2048,
              $sformatf("READ CAPACITY: %0d bytes, last %0d, size %0d", nin,
                        {din[0], din[1], din[2], din[3]}, {din[4], din[5], din[6], din[7]}));
        expect_end("  its end");

        // READ (10): across the extents (99 | 100), 2048 bytes per block
        r0 = eng_reads;
        cd_read(0, 97, 6, 16'hfffe);
        check(blocks == 6 && (FAULT != 0 || eng_reads - r0 == 2), $sformatf("  %0d blocks, %0d SD reads", blocks, eng_reads - r0));
        // a byte count limit of 512: four blocks a sector
        cd_read(0, 5000, 2, 16'h0200);
        check(blocks == 8, $sformatf("  %0d blocks", blocks));
        // READ (12) of 40 sectors: one SD transfer (160 of the image's sectors)
        r0 = eng_reads;
        cd_read(1, 20000, 40, 16'hfffe);
        check(FAULT != 0 || eng_reads - r0 == 1, $sformatf("  %0d SD reads", eng_reads - r0));
        // past the end: ILLEGAL REQUEST, LBA out of range
        set_cdb(8'h28, 0, 0, 0, 8'h75, 8'h2f, 0, 0, 2, 0, 0, 0);   // 29999, 2 sectors
        packet(16'hfffe);
        expect_end("READ past the end", 5);
        sense(key, asc);
        check(key == 5 && asc == 8'h21, $sformatf("  REQUEST SENSE: %0x/%02x", key, asc));

        // READ TOC, LBA: track 1 at 0, the lead-out at the capacity
        set_cdb(8'h43, 0, 0, 0, 0, 0, 1, 0, 8'hff, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 20 && din[1] == 18 && din[2] == 1 && din[3] == 1 && din[5] == 8'h14 && din[6] == 1 &&
              {din[8], din[9], din[10], din[11]} == 0 && din[14] == 8'haa &&
              {din[16], din[17], din[18], din[19]} == CDCAP,
              $sformatf("READ TOC: %0d bytes, length %0d, track %0d at %0d, lead-out %02x at %0d", nin, din[1], din[6],
                        {din[8], din[9], din[10], din[11]}, din[14], {din[16], din[17], din[18], din[19]}));
        expect_end("  its end");
        // MSF
        set_cdb(8'h43, 8'h02, 0, 0, 0, 0, 1, 0, 8'hff, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 20 && {din[9], din[10], din[11]} == 24'h000200 && {din[17], din[18], din[19]} == msf(CDCAP + 150),
              $sformatf("READ TOC, MSF: track 1 at %06x, lead-out at %06x (%06x)", {din[9], din[10], din[11]},
                        {din[17], din[18], din[19]}, msf(CDCAP + 150)));
        expect_end("  its end");
        // the lead-out alone; the sessions (format 1)
        set_cdb(8'h43, 0, 0, 0, 0, 0, 8'haa, 0, 8'hff, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 12 && din[1] == 10 && din[6] == 8'haa && {din[8], din[9], din[10], din[11]} == CDCAP,
              $sformatf("READ TOC from AAh: %0d bytes, %02x at %0d", nin, din[6], {din[8], din[9], din[10], din[11]}));
        set_cdb(8'h43, 0, 1, 0, 0, 0, 0, 0, 8'hff, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 12 && din[1] == 10 && din[6] == 1, $sformatf("READ TOC, sessions: %0d bytes, track %0d", nin, din[6]));

        // MODE SENSE (10), the capabilities page; MODE SENSE (6), all pages
        set_cdb(8'h5a, 0, 8'h2a, 0, 0, 0, 0, 0, 8'hff, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 28 && {din[0], din[1]} == 26 && din[2] == 8'h01 && din[8] == 8'h2a && din[9] == 8'h12,
              $sformatf("MODE SENSE (10) 2Ah: %0d bytes, length %0d, medium %02x, page %02x", nin,
                        {din[0], din[1]}, din[2], din[8]));
        set_cdb(8'h1a, 0, 8'h3f, 0, 8'hff, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 56 && din[0] == 55 && din[4] == 8'h01 && din[12] == 8'h0d && din[20] == 8'h0e && din[36] == 8'h2a,
              $sformatf("MODE SENSE (6) 3Fh: %0d bytes, pages %02x %02x %02x %02x", nin, din[4], din[12], din[20], din[36]));
        expect_end("  its end");

        // an odd allocation length: REQUEST SENSE, 17 bytes
        set_cdb(8'h03, 0, 0, 0, 17, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 17, $sformatf("REQUEST SENSE, 17 bytes: %0d", nin));
        expect_end("  its end");

        // MODE SELECT (10), 12 bytes out (no page 0Eh in them)
        for (k = 0; k < 256; k++) dout[k] = 8'(k / 2);
        set_cdb(8'h55, 8'h10, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0);
        packet(16'hfffe, 12);
        expect_end("MODE SELECT (10), 12 bytes out");

        // an unknown command: ILLEGAL REQUEST, invalid command
        set_cdb(8'hbb, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        expect_end("unknown command BBh", 5);
        sense(key, asc);
        check(key == 5 && asc == 8'h20, $sformatf("  REQUEST SENSE: %0x/%02x", key, asc));

        // a hard disk read between the second and third block of a CD read
        cd_read(0, 300, 4, 16'hfffe, 2);
        read_hdd(1235, 1);
        // a byte count limit of 768: blocks that end inside a card sector (and a hard disk read
        // between two of them)
        cd_read(0, 700, 2, 16'h0300, 3);
        check(blocks == 6, $sformatf("  %0d blocks", blocks));

        // ---------------------------------------------------------------------------------------
        // the mixed disc: a new table, the unit mounted again (a new generation)
        // ---------------------------------------------------------------------------------------
        tab_track(0, 1, 8'h14, 2352, 16, 0, 0, 0, 0, 100, 100, 0);
        tab_track(1, 2, 8'h10, 2352, 0, 1, 100, 250, 100, 400, 400, 100 * 2352);
        tab_track(2, 3, 8'h10, 2352, 0, 1, 400, 402, 402, LEAD, LEAD, 400 * 2352);
        tab_head(3, 1, 3, LEAD, 3, 8'h10);
        qwr(28'h0000060, 16'd5);
        repeat (2000) @(posedge clk);
        set_cdb(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        expect_end("mixed disc: UNIT ATTENTION", 6);

        // READ TOC: three tracks and the lead-out; from track 2; MSF
        set_cdb(8'h43, 0, 0, 0, 0, 0, 0, 0, 8'hff, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 36 && din[1] == 34 && din[2] == 1 && din[3] == 3 && din[5] == 8'h14 && din[13] == 8'h10 &&
              din[14] == 2 && {din[16], din[17], din[18], din[19]} == 250 && din[22] == 3 &&
              {din[24], din[25], din[26], din[27]} == 402 && din[30] == 8'haa && {din[32], din[33], din[34], din[35]} == LEAD,
              $sformatf("READ TOC, 3 tracks: %0d bytes, %0d %0d..%0d, track 2 at %0d, 3 at %0d, lead-out at %0d", nin, din[1], din[2], din[3],
                        {din[16], din[17], din[18], din[19]}, {din[24], din[25], din[26], din[27]}, {din[32], din[33], din[34], din[35]}));
        set_cdb(8'h43, 8'h02, 0, 0, 0, 0, 2, 0, 8'hff, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 28 && din[1] == 26 && din[6] == 2 && {din[9], din[10], din[11]} == msf(250 + 150) &&
              din[22] == 8'haa && {din[25], din[26], din[27]} == msf(LEAD + 150),
              $sformatf("READ TOC from track 2, MSF: %0d bytes, track %0d at %06x, lead-out at %06x", nin, din[6],
                        {din[9], din[10], din[11]}, {din[25], din[26], din[27]}));
        set_cdb(8'h43, 0, 0, 0, 0, 0, 4, 0, 8'hff, 0, 0, 0);
        packet(16'hfffe);
        expect_end("READ TOC from track 4", 5);
        set_cdb(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        check({din[0], din[1], din[2], din[3]} == LEAD - 1, $sformatf("READ CAPACITY: last %0d", {din[0], din[1], din[2], din[3]}));

        // raw reads (2352-byte sectors: the user data at 16): limits FFFEh, 768, a hard disk read
        r0 = eng_reads;
        raw_read(10, 3, 16'hfffe);
        raw_read(50, 2, 16'h0300);
        raw_read(60, 3, 16'h0300, 2);
        raw_read(97, 3, 16'hfffe);
        // an audio track: ILLEGAL MODE; across the data track's end: out of range
        set_cdb(8'h28, 0, 0, 0, 0, 120, 0, 0, 1, 0, 0, 0);
        packet(16'hfffe);
        expect_end("READ of an audio track", 5);
        sense(key, asc);
        check(asc == 8'h64, $sformatf("  REQUEST SENSE: %0x/%02x", key, asc));
        set_cdb(8'h28, 0, 0, 0, 0, 98, 0, 0, 4, 0, 0, 0);
        packet(16'hfffe);
        expect_end("READ past the data track", 5);

        // PLAY across track 2's end, track 3's pregap (silence) into its file
        a0 = naud;
        play(398, 405);
        subq(0);
        check(q_st == 8'h11, $sformatf("  playing: audio status %02x", q_st));
        wait_status(8'h13, 400);
        check(q_st == 8'h13, $sformatf("  done: audio status %02x", q_st));
        subq(0);
        check(q_st == 8'h15, $sformatf("  then: audio status %02x", q_st));
        check_audio(a0, 398, 405, "  the samples, 398-404");

        // the place: track 2's pregap (INDEX 00: the relative address counts down), then playing
        a0 = naud;
        play(240, 260);
        repeat (100000) @(posedge clk);
        subq(0);
        check(q_st == 8'h11 && q_trk == 2 && q_ctl == 8'h10 &&
              ((q_idx == 0 && $signed(q_rel) == $signed(q_abs - 250)) || (q_idx == 1 && q_rel == q_abs - 250)) &&
              q_abs >= 240 && q_abs < 260,
              $sformatf("READ SUB-CHANNEL, LBA: %02x, track %0d index %0d, at %0d, relative %0d", q_st, q_trk, q_idx,
                        q_abs, $signed(q_rel)));
        subq(1);
        check(q_st == 8'h11 && q_trk == 2 && q_abs[31:24] == 0 && q_abs[23:0] >= msf(240 + 150) && q_abs[23:0] < msf(260 + 150),
              $sformatf("  MSF: at %06x, relative %06x, index %0d", q_abs[23:0], q_rel[23:0], q_idx));
        // PAUSE: the place holds; RESUME
        set_cdb(8'h4b, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        expect_end("PAUSE");
        subq(0);
        n = q_abs;
        repeat (200000) @(posedge clk);
        subq(0);
        check(q_st == 8'h12 && q_abs == n, $sformatf("  paused: %02x, at %0d (%0d)", q_st, q_abs, n));
        set_cdb(8'h4b, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0);
        packet(16'hfffe);
        expect_end("RESUME");
        subq(0);
        check(q_st == 8'h11, $sformatf("  playing: %02x", q_st));
        wait_status(8'h13, 600);
        check_audio(a0, 240, 260, "  the samples, 240-259 (paused once)");
        // RESUME when not paused: a command sequence error
        set_cdb(8'h4b, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0);
        packet(16'hfffe);
        expect_end("RESUME, nothing paused", 5);

        // STOP; a READ stops play too
        play(300, 390);
        repeat (50000) @(posedge clk);
        set_cdb(8'h4e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        expect_end("STOP PLAY");
        subq(0);
        check(q_st == 8'h15, $sformatf("  audio status %02x", q_st));
        play(300, 390);
        repeat (50000) @(posedge clk);
        raw_read(20, 1, 16'hfffe);
        subq(0);
        check(q_st == 8'h15, $sformatf("  a READ stopped it: audio status %02x", q_st));
        // PLAY of a data track: ILLEGAL MODE; past the lead-out: out of range
        set_cdb(8'h45, 0, 0, 0, 0, 50, 0, 0, 2, 0, 0, 0);
        packet(16'hfffe);
        expect_end("PLAY AUDIO (10) of the data track", 5);
        sense(key, asc);
        check(asc == 8'h64, $sformatf("  REQUEST SENSE: %0x/%02x", key, asc));
        set_cdb(8'h45, 0, 0, 0, 8'h02, 8'hb0, 0, 0, 100, 0, 0, 0);   // 688 + 100
        packet(16'hfffe);
        expect_end("PLAY AUDIO (10) past the lead-out", 5);

        // MODE SELECT (6): page 0Eh, port 0 the right channel at half volume
        for (k = 0; k < 256; k++) dout[k] = 0;
        dout[3] = 8; dout[12] = 8'h0e; dout[13] = 8'h0e; dout[20] = 8'h02; dout[21] = 8'h80; dout[22] = 8'h02; dout[23] = 8'hff;
        set_cdb(8'h15, 8'h10, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe, 28);
        expect_end("MODE SELECT (6), page 0Eh");
        set_cdb(8'h1a, 0, 8'h0e, 0, 8'hff, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        check(nin == 20 && din[1] == 8'h03 && din[12] == 8'h02 && din[13] == 8'h80 && din[14] == 8'h02 && din[15] == 8'hff,
              $sformatf("MODE SENSE (6) 0Eh: medium %02x, ports %02x %02x %02x %02x", din[1], din[12], din[13], din[14], din[15]));
        a0 = naud;
        play(260, 262);
        wait_status(8'h13, 400);
        check_audio(a0, 260, 262, "  the samples at half volume, the right channel on both", 129, 1);
        dout[20] = 8'h01; dout[21] = 8'hff;
        set_cdb(8'h15, 8'h10, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe, 28);

        // PLAY while the hard disk reads: no gap
        a0 = naud;
        play(270, 282);
        repeat (60000) @(posedge clk);
        n = cd_stat[31:16];
        for (k = 0; k < 6; k++) read_hdd(2000 + 50 * k, 8);
        wait_status(8'h13, 600);
        check_audio(a0, 270, 282, "PLAY while the hard disk reads");
        check(cd_stat[31:16] == n, $sformatf("  samples the FIFO did not have meanwhile: %0d", cd_stat[31:16] - n));

        // the disc ejected: NOT READY
        qwr(28'h0000060, 16'd0);
        repeat (2000) @(posedge clk);
        set_cdb(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        packet(16'hfffe);
        expect_end("TEST UNIT READY, ejected", 2);

        if (errors == 0) $display("PASS: all checks");
        else $display("FAILED: %0d checks", errors);
        $finish;
    end
    initial begin
        #1500000000;
        $fatal(1, "timeout");
    end
endmodule
