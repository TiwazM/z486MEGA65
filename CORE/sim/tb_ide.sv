`timescale 1ns/1ps

// z486 for MEGA65
//
// Testbench: the hard disk from the SD card. z486_MiSTer's ide.v (the first IDE channel, driven
// through its real I/O adapter, 8-bit registers and the 16-bit data port) and rtc.v (the CMOS)
// against pc_mgmt.vhd (the management bus) and disk_sd.vhd (the image file through the SD engine
// port), with a model of the SD host controller's engine port behind them. The test does what
// the Bochs BIOS's ATA probe and INT 13h do: soft reset (the master, then the slave, which must
// read cylinder FFFFh), IDENTIFY, LBA28 reads across the image file's two extents, writes, SET
// MULTIPLE and READ MULTIPLE, an unknown command (aborted); and the CMOS's hard disk bytes.
// CORE/sim/run_disks.sh runs it with xsim.
//
// Licensed under GPL v3

module tb_ide #(
    // the engine model's pace: clocks per read byte, and clocks between a block's last byte
    // and its e_blk (the real engine: 2 and ~34, its CRC; 1 and 0: as fast as it goes)
    parameter int E_PER = 1,
    parameter int E_CRC = 0,
    // disk_sd's G_FAULT: every FAULT-th answer's first copy reads its last byte wrong (pc_mgmt
    // must copy it again)
    parameter int FAULT = 0,
    // disk_sd's G_LUTRAM: 1, the ring and the write buffer in LUT RAM
    parameter int LUTRAM = 0
);
    reg clk = 0;
    always #7.8125 clk = ~clk;              // the PC's 64 MHz
    reg qclk = 0;
    always #10 qclk = ~qclk;                // QNICE's 50 MHz
    reg reset_n = 0;
    reg qrst = 1;

    // ------------------------------------------------------------------------------------------
    // The PC: I/O adapter, IDE channel, CMOS
    // ------------------------------------------------------------------------------------------
    reg [31:2] cpu_addr = 0;
    reg [3:0] cpu_be = 0;
    reg [31:0] cpu_din = 0;
    wire [31:0] cpu_dout;
    reg cpu_io_rd = 0, cpu_io_wr = 0;
    wire cpu_io_ready;
    wire [15:0] io_address;
    wire io_read, io_write;
    wire [7:0] io_writedata, rtc_readdata;
    wire [3:0] w_address;
    wire w_read, w_write, w_32;
    wire [31:0] w_writedata, ide_readdata;
    wire ide_sel = io_address[15:3] == (16'h1f0 >> 3) || io_address == 16'h3f6;
    wire rtc_sel = io_address[15:1] == (16'h070 >> 1);
    iobus_adapter adapter (
        .clk(clk), .reset_n(reset_n),
        .cpu_addr(cpu_addr), .cpu_be(cpu_be), .cpu_din(cpu_din),
        .cpu_dout(cpu_dout), .cpu_io_rd(cpu_io_rd), .cpu_io_wr(cpu_io_wr),
        .cpu_io_ready(cpu_io_ready), .io_address(io_address),
        .io_read(io_read), .io_write(io_write), .io_writedata(io_writedata),
        .io_readdata(ide_sel ? ide_readdata[7:0] : rtc_sel ? rtc_readdata : 8'hff),
        .ide_address(w_address), .ide_read(w_read), .ide_write(w_write),
        .ide_writedata(w_writedata), .ide_readdata(ide_readdata), .ide_32(w_32),
        .ide_hold(1'b0), .direct_readdata(8'hff), .direct_handled(1'b0)
    );

    wire [15:0] mgmt_address, mgmt_writedata, mgmt_readdata, ide_mgmt_readdata;
    wire mgmt_read, mgmt_write;
    wire [2:0] ide_request;
    wire irq14, nodata;
    wire wide = w_read | w_write;
    ide ide0 (
        .clk(clk), .rst_n(reset_n), .irq(irq14), .drq(),
        .use_fast(1'b1), .no_data(nodata), .drive_en(),
        .io_address(wide ? w_address : {io_address[9], io_address[2:0]}),
        .io_read((io_read && ide_sel) || w_read), .io_readdata(ide_readdata),
        .io_write((io_write && ide_sel) || w_write),
        .io_writedata(wide ? w_writedata : {24'd0, io_writedata}),
        .io_32(wide ? w_32 : 1'b0), .io_wait(),
        .request(ide_request),
        .mgmt_address(mgmt_address[3:0]),
        .mgmt_write(mgmt_write && mgmt_address[15:8] == 8'hF0),
        .mgmt_writedata(mgmt_writedata),
        .mgmt_read(mgmt_read && mgmt_address[15:8] == 8'hF0),
        .mgmt_readdata(ide_mgmt_readdata)
    );
    assign mgmt_readdata = mgmt_address[15:8] == 8'hF0 ? ide_mgmt_readdata : 16'h0001;
    rtc u_rtc (
        .clk(clk), .rst_n(reset_n), .irq(),
        .io_address(io_address[0]), .io_read(io_read && rtc_sel), .io_readdata(rtc_readdata),
        .io_write(io_write && rtc_sel), .io_writedata(io_writedata),
        .bootcfg(6'd0), .ram_size(2'd2), .fpu_off(1'b0),
        .mgmt_address(mgmt_address[7:0]), .mgmt_write(mgmt_write && mgmt_address[15:8] == 8'hF4),
        .mgmt_writedata(mgmt_writedata[7:0]), .clock_rate(28'd64000000)
    );

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

    pc_mgmt #(.G_CLK_HZ(6400000)) mgmt (
        .clk_i(clk), .rst_i(!reset_n),
        .mgmt_address_o(mgmt_address), .mgmt_read_o(mgmt_read), .mgmt_write_o(mgmt_write),
        .mgmt_writedata_o(mgmt_writedata), .mgmt_readdata_i(mgmt_readdata),
        .fdd_request_i(2'b00), .ide_request_i(ide_request), .ide1_request_i(3'b000), .rtc_i(rtc_word), .mnt_i(mnt),
        .sd_req_o(sd_req), .sd_req_wr_o(sd_req_wr), .sd_req_unit_o(sd_req_unit),
        .sd_req_lba_o(sd_req_lba), .sd_req_cnt_o(sd_req_cnt), .sd_req_fresh_o(sd_req_fresh), .sd_done_i(sd_done), .sd_err_i(sd_err),
        .buf_addr_o(buf_addr), .buf_we_o(buf_we), .buf_wd_o(buf_wd), .buf_rd_i(buf_rd), .buf_bad_i(buf_bad)
    );

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
    // The image: 200000 sectors, base 9000, 8 sectors per cluster, extents (100, 10) and
    // (500, 100000): sectors 0..79 in the first, 80.. in the second
    // ------------------------------------------------------------------------------------------
    localparam integer TOTAL = 200000;
    function automatic integer blk(input integer lba);
        integer c;
        c = lba / 8;
        blk = 9000 + ((c < 10) ? 100 + c : 500 + c - 10) * 8 + lba % 8;
    endfunction
    function automatic [7:0] sdbyte(input integer b, input integer i);
        sdbyte = 8'(b * 7 ^ i ^ (i >> 8) ^ 8'h5a);
    endfunction
    function automatic [15:0] pattern(input integer lba, input integer w);
        pattern = 16'(lba * 1000 + w * 3 + 16'h1234);
    endfunction

    // The SD engine port: ready; a START moves COUNT blocks from ADDR on (a write: one), each
    // after a while; block k only once k < LIMIT (it waits), ABORT ends a read at the next block
    // boundary. RDBLK: the block within the transfer. preempt_after ends a read early after
    // that many blocks (as QNICE's own SD access does), err_block fails the transfer that
    // reaches that SD block once.
    reg e_busy = 0, e_done = 0, e_err = 0, e_blk = 0, e_rdwe = 0;
    reg [8:0] e_rdidx = 0, e_wridx = 0;
    reg [7:0] e_rddata = 0;
    reg [15:0] e_rdblk = 0;
    assign q2c = {e_wridx, 16'd0, e_rddata, e_rdidx, e_rdblk, e_rdwe, e_blk, e_err, e_done,
                  e_busy, 1'b1};
    integer eng_reads = 0, eng_blocks = 0, eng_writes = 0, eng_aborts = 0, write_errors = 0;
    integer preempt_after = -1, err_block = -1, max_ahead = 0;
    integer expect_write_lba [integer];
    always begin
        integer b, i, k, n;
        bit wr, stop;
        @(posedge qclk);
        if (c2q[0]) begin
            b = c2q[34:3];
            wr = c2q[1];
            n = c2q[50:35];
            e_busy <= 1;
            repeat (40) @(posedge qclk);
            if (!wr) begin
                eng_reads++;
                stop = 0;
                for (k = 0; k < n && !stop; k++) begin
                    while (!c2q[2] && k >= c2q[66:51]) @(posedge qclk);
                    if (c2q[2]) begin
                        stop = 1;
                    end else if (b + k == err_block) begin
                        err_block = -1;
                        e_err <= 1;
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
                        if (preempt_after > 0) begin
                            preempt_after--;
                            if (preempt_after == 0) begin preempt_after = -1; stop = 1; end
                        end
                    end
                end
                if (c2q[2]) eng_aborts++;
                repeat (10) @(posedge qclk);
            end else begin
                if (n != 1) $fatal(1, "engine: write count %0d", n);
                for (i = 0; i < 512; i++) begin
                    e_wridx <= i;
                    @(posedge qclk);
                    @(negedge qclk);
                    if (!expect_write_lba.exists(b)) begin
                        if (i == 0) $error("engine: write to unexpected block %0d", b);
                        write_errors++;
                    end else if (c2q[74:67] !== (i[0] ? pattern(expect_write_lba[b], i / 2) >> 8
                                                      : pattern(expect_write_lba[b], i / 2) & 8'hff)) begin
                        if (write_errors < 5)
                            $error("engine: block %0d byte %0d = %02x", b, i, c2q[74:67]);
                        write_errors++;
                    end
                end
                @(posedge qclk);
                eng_writes++;
                e_blk <= 1; @(posedge qclk); e_blk <= 0;
            end
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
    task automatic qrd(input [27:0] a, output [15:0] d);
        @(posedge qclk);
        q_addr <= a; q_ce <= 1; q_we <= 0;
        @(posedge qclk);
        d = q_rdata;
        q_ce <= 0;
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
    task automatic inw(output [15:0] v);
        reg [31:0] x;
        io_rd(16'h1f0, 4'b0011, x);
        v = x[15:0];
    endtask
    task automatic outw(input [15:0] v);
        io_wr(16'h1f0, {16'd0, v}, 4'b0011);
    endtask
    task automatic cmos_rd(input [6:0] index, output [7:0] v);
        outb(16'h070, {1'b0, index});
        inb(16'h071, v);
    endtask

    integer errors = 0;
    task automatic check(input bit ok, input string what);
        if (ok) $display("ok    %s", what);
        else begin $error("FAIL  %s", what); errors++; end
    endtask

    // the status once BSY is clear (BSY = 80h)
    task automatic wait_ready(output [7:0] st);
        integer k;
        for (k = 0; k < 20000; k++) begin
            inb(16'h1f7, st);
            if (!st[7]) return;
            repeat (20) @(posedge clk);
        end
        $fatal(1, "IDE: still busy, status %02x", st);
    endtask
    task automatic wait_drq(input string what);
        reg [7:0] st;
        wait_ready(st);
        if ((st & 8'hC9) != 8'h48) $fatal(1, "%s: status %02x, not DRQ", what, st);
    endtask

    // INT 13h: LBA28, `n` sectors from `lba`, one sector per DRQ block
    task automatic ata_cmd(input [7:0] cmd, input integer lba, input integer n);
        outb(16'h1f2, n[7:0]);
        outb(16'h1f3, lba[7:0]); outb(16'h1f4, lba[15:8]); outb(16'h1f5, lba[23:16]);
        outb(16'h1f6, 8'he0 | lba[27:24]);
        outb(16'h1f7, cmd);
    endtask
    task automatic read_sectors(input [7:0] cmd, input integer lba, input integer n);
        reg [15:0] w;
        reg [7:0] st;
        integer s, k, bad;
        bad = 0;
        ata_cmd(cmd, lba, n);
        for (s = 0; s < n; s++) begin
            wait_drq("read");
            for (k = 0; k < 256; k++) begin
                inw(w);
                if (w !== {sdbyte(blk(lba + s), 2 * k + 1), sdbyte(blk(lba + s), 2 * k)}) bad++;
            end
        end
        wait_ready(st);
        check(bad == 0 && (st & 8'hC9) == 8'h40,
              $sformatf("read %02x LBA %0d-%0d (%0d words wrong, status %02x)", cmd, lba, lba + n - 1, bad, st));
    endtask
    task automatic write_sectors(input integer lba, input integer n);
        reg [7:0] st;
        integer s, k;
        for (s = 0; s < n; s++) expect_write_lba[blk(lba + s)] = lba + s;
        ata_cmd(8'h30, lba, n);
        for (s = 0; s < n; s++) begin
            wait_drq("write");
            for (k = 0; k < 256; k++) outw(pattern(lba + s, k));
        end
        wait_ready(st);
        check((st & 8'hC9) == 8'h40 && write_errors == 0,
              $sformatf("write LBA %0d-%0d (status %02x, %0d bytes wrong)", lba, lba + n - 1, st, write_errors));
    endtask

    initial begin
        reg [7:0] v, sc, sn, cl, ch, st, er, hi, lo;
        reg [15:0] id [0:255];
        integer k, sum;
        reg [15:0] ck_good, ck_bad, ck_fixed, ck_fresh;
        repeat (5) @(negedge clk);
        reset_n = 1;
        repeat (5) @(posedge qclk);
        qrst = 0;

        // the firmware's DISK_PREP for the hard disk (unit 2): its map in window 2, its
        // registers at 0x40, MODE last
        qwr(28'h0002000, 16'd2);
        qwr(28'h0002001, 16'd100); qwr(28'h0002002, 16'd0); qwr(28'h0002003, 16'd10); qwr(28'h0002004, 16'd0);
        qwr(28'h0002005, 16'd500); qwr(28'h0002006, 16'd0); qwr(28'h0002007, 16'(100000)); qwr(28'h0002008, 16'(100000 >> 16));
        qwr(28'h0000041, 16'(TOTAL)); qwr(28'h0000042, 16'(TOTAL >> 16));
        qwr(28'h0000043, 16'd9000); qwr(28'h0000044, 16'd0);
        qwr(28'h0000045, 16'd3);
        qwr(28'h0000040, 16'd1);

        // the CMOS: 12h F0h, 19h 2Fh, the checksum
        for (k = 0; k < 200; k++) begin
            cmos_rd(7'h12, v);
            if (v == 8'hF0) break;
            repeat (500) @(posedge clk);
        end
        cmos_rd(7'h19, st);
        sum = 0;
        for (k = 16'h10; k <= 16'h2D; k++) begin cmos_rd(k[6:0], er); sum += er; end
        cmos_rd(7'h2E, hi); cmos_rd(7'h2F, lo);
        check(v == 8'hF0 && st == 8'h2F && {hi, lo} == 16'(sum),
              $sformatf("CMOS: 12h %02x, 19h %02x, checksum %02x%02x (sum %04x)", v, st, hi, lo, 16'(sum)));

        // soft reset, the master selected: the signature of an ATA disk
        outb(16'h1f6, 8'ha0);
        outb(16'h3f6, 8'h04); repeat (50) @(posedge clk); outb(16'h3f6, 8'h00);
        wait_ready(st);
        inb(16'h1f2, sc); inb(16'h1f3, sn); inb(16'h1f4, cl); inb(16'h1f5, ch);
        check(sc == 1 && sn == 1 && cl == 0 && ch == 0 && st == 8'h50,
              $sformatf("reset, master: %02x %02x %02x %02x, status %02x", sc, sn, cl, ch, st));

        // the slave selected: nothing there (cylinder FFFFh)
        outb(16'h1f6, 8'hb0);
        outb(16'h3f6, 8'h04); repeat (50) @(posedge clk); outb(16'h3f6, 8'h00);
        wait_ready(st);
        inb(16'h1f4, cl); inb(16'h1f5, ch);
        check(cl == 8'hff && ch == 8'hff, $sformatf("reset, slave: cylinder %02x%02x", ch, cl));

        // IDENTIFY
        outb(16'h1f6, 8'ha0);
        outb(16'h1f7, 8'hec);
        wait_drq("IDENTIFY");
        for (k = 0; k < 256; k++) inw(id[k]);
        wait_ready(st);
        check(id[1] == (TOTAL >> 12) && id[3] == 16 && id[6] == 256 && id[5] == 512 &&
              {id[61], id[60]} == TOTAL && id[27] == 16'h7A34 && id[47] == 16'h8001 &&
              id[49][9] && (st & 8'hC9) == 8'h40,
              $sformatf("IDENTIFY: C %0d H %0d S %0d, %0d sectors, model %04x, status %02x",
                        id[1], id[3], id[6], {id[61], id[60]}, id[27], st));

        // reads: across the two extents (79 | 80: two runs), then a single one far in
        k = eng_reads;
        read_sectors(8'h20, 78, 3);
        read_sectors(8'h20, 150000, 1);
        check(FAULT != 0 || (eng_reads - k == 3), $sformatf("reads across the extents: %0d SD reads", eng_reads - k));
        // 64 sectors in one SD read (twice the ring: the engine waits for the PC)
        k = eng_reads; sum = eng_blocks;
        read_sectors(8'h20, 1000, 64);
        check(FAULT != 0 || (eng_reads - k == 1 && eng_blocks - sum == 64),
              $sformatf("64 sectors: %0d SD reads, %0d blocks", eng_reads - k, eng_blocks - sum));
        // again, from the ring: the last 20 of them, no SD read
        k = eng_reads;
        read_sectors(8'h20, 1044, 20);
        check(FAULT != 0 || (eng_reads == k), $sformatf("from the ring: %0d SD reads", eng_reads - k));
        // one older than the ring holds: an SD read
        k = eng_reads;
        read_sectors(8'h20, 1010, 1);
        check(FAULT != 0 || (eng_reads - k == 1), $sformatf("older than the ring: %0d SD reads", eng_reads - k));
        // QNICE takes the card after 5 blocks: the rest in a second transfer
        k = eng_reads; preempt_after = 5;
        read_sectors(8'h20, 20000, 12);
        check(FAULT != 0 || (eng_reads - k == 2), $sformatf("preempted run: %0d SD reads", eng_reads - k));
        // a failing block: tried again from it
        k = eng_reads; sum = eng_blocks; err_block = blk(30003);
        read_sectors(8'h20, 30000, 8);
        check(FAULT != 0 || (err_block == -1 && eng_reads - k == 2 && eng_blocks - sum == 8),
              $sformatf("an SD error: %0d SD reads, %0d blocks", eng_reads - k, eng_blocks - sum));
        // writes drop the drive's run: the sectors are read from the card again
        read_sectors(8'h20, 4, 4);
        write_sectors(5, 2);
        k = eng_reads;
        read_sectors(8'h20, 5, 1);
        check(FAULT != 0 || (eng_reads - k == 1), $sformatf("after a write: %0d SD reads", eng_reads - k));
        // SET MULTIPLE (1), READ MULTIPLE
        outb(16'h1f2, 8'h01); outb(16'h1f6, 8'ha0); outb(16'h1f7, 8'hc6);
        wait_ready(st);
        check((st & 8'hC9) == 8'h40, $sformatf("SET MULTIPLE 1: status %02x", st));
        read_sectors(8'hc4, 1000, 2);
        // an unknown command: aborted
        outb(16'h1f6, 8'ha0); outb(16'h1f7, 8'hfa);
        wait_ready(st);
        inb(16'h1f1, er);
        check((st & 8'h01) && er == 8'h04, $sformatf("unknown command FAh: status %02x, error %02x", st, er));
        // the reads still work after it
        read_sectors(8'h21, 0, 1);
        check(eng_writes == 2, $sformatf("engine: %0d writes", eng_writes));
        // the ring's checksums: with FAULT, every wrong copy came again fresh from the card
        // (the SD read counts above do not hold then) and then matched
        qrd(28'h0000049, ck_good); qrd(28'h000004a, ck_bad); qrd(28'h000004b, ck_fixed);
        qrd(28'h000004f, ck_fresh);
        check(FAULT == 0 ? (ck_bad == 0 && ck_good > 0 && ck_fresh == 0) :
                           (ck_bad > 0 && ck_fixed == ck_bad && ck_fresh == ck_bad),
              $sformatf("ring checksums: %0d copies matched, %0d did not, %0d right when fresh from the card (%0d fresh reads)",
                        ck_good, ck_bad, ck_fixed, ck_fresh));
        if (errors == 0) $display("PASS: all checks");
        else $display("FAILED: %0d checks", errors);
        $finish;
    end
    initial begin
        #400000000;
        $fatal(1, "timeout");
    end
endmodule
