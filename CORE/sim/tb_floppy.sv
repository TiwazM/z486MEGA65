`timescale 1ns/1ps

// z486 for MEGA65
//
// Testbench: floppy drive A: from the SD card. z486_MiSTer's floppy.v (the PC's FDC, driven
// through its real I/O adapter with DMA, after z486_MiSTer's tests/tb_floppy_io.sv) and rtc.v
// (the CMOS) against pc_mgmt.vhd (the management bus) and fdd_sd.vhd (the image file through
// the SD engine port), with a model of the SD host controller's engine port behind them. The
// image's extent map has two extents, so the cluster arithmetic is checked; the engine model
// fails one read once and preempts one write once, so the retries are too. CMOS: the bytes the
// BIOS reads and their checksum. CORE/sim/run_floppy.sh runs it with xsim.
//
// Licensed under GPL v3

module tb_floppy;
    // the PC's clock (64 MHz) and QNICE's (50 MHz)
    reg clk = 0;
    always #7.8125 clk = ~clk;
    reg qclk = 0;
    always #10 qclk = ~qclk;
    reg reset_n = 0;
    reg qrst = 1;

    // ------------------------------------------------------------------------------------------
    // The PC: I/O adapter, FDC, CMOS
    // ------------------------------------------------------------------------------------------
    reg [31:2] cpu_addr = 0;
    reg [3:0] cpu_be = 0;
    reg [31:0] cpu_din = 0;
    wire [31:0] cpu_dout;
    reg cpu_io_rd = 0, cpu_io_wr = 0;
    wire cpu_io_ready;
    wire [15:0] io_address;
    wire io_read, io_write;
    wire [7:0] io_writedata, fdc_readdata, rtc_readdata;
    wire fdc_sel = io_address[15:3] == (16'h3f0 >> 3);
    wire rtc_sel = io_address[15:1] == (16'h070 >> 1);
    iobus_adapter adapter (
        .clk(clk), .reset_n(reset_n),
        .cpu_addr(cpu_addr), .cpu_be(cpu_be), .cpu_din(cpu_din),
        .cpu_dout(cpu_dout), .cpu_io_rd(cpu_io_rd), .cpu_io_wr(cpu_io_wr),
        .cpu_io_ready(cpu_io_ready), .io_address(io_address),
        .io_read(io_read), .io_write(io_write),
        .io_writedata(io_writedata),
        .io_readdata(fdc_sel ? fdc_readdata : rtc_sel ? rtc_readdata : 8'hff),
        .ide_readdata(32'd0), .ide_hold(1'b0),
        .direct_readdata(8'hff), .direct_handled(1'b0)
    );

    wire [15:0] mgmt_address, mgmt_writedata, mgmt_readdata;
    wire mgmt_read, mgmt_write;
    wire [1:0] request;
    wire irq, dma_req, fdd0_inserted;
    reg dma_ack = 0, dma_tc = 0;
    reg [7:0] dma_readdata = 0;
    wire [7:0] dma_writedata;
    floppy fdc (
        .clk(clk), .rst_n(reset_n), .io_address(io_address[2:0]),
        .io_read(io_read && fdc_sel), .io_write(io_write && fdc_sel),
        .io_writedata(io_writedata), .io_readdata(fdc_readdata),
        .fdd0_inserted(fdd0_inserted),
        .dma_req(dma_req), .dma_ack(dma_ack), .dma_tc(dma_tc),
        .dma_readdata(dma_readdata), .dma_writedata(dma_writedata),
        .mgmt_address(mgmt_address[3:0]), .mgmt_fddn(mgmt_address[7]),
        .mgmt_write(mgmt_write && mgmt_address[15:8] == 8'hF2),
        .mgmt_read(mgmt_read && mgmt_address[15:8] == 8'hF2),
        .mgmt_writedata(mgmt_writedata), .mgmt_readdata(mgmt_readdata),
        .wp(2'b00), .clock_rate(28'd64000000), .request(request), .irq(irq)
    );
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
    wire [15:0] sd_req_lba;
    wire [8:0] buf_addr;
    wire buf_we;
    wire [7:0] buf_wd, buf_rd;
    wire m_mounted, m_wp;
    wire [7:0] m_cyl, m_spt;
    wire [15:0] m_total;
    wire [1:0] m_heads;
    wire [3:0] m_gen;
    // RTC: 12:34:56, 30.10.26, a Friday (MEGA65: 0 = Monday), the update toggle 0
    wire [64:0] rtc_word = {1'b0, 8'h40, 8'h04, 8'h26, 8'h10, 8'h30, 8'h12, 8'h34, 8'h56};

    pc_mgmt #(.G_CLK_HZ(6400000)) mgmt (          // the eject wait 10 ms instead of 100
        .clk_i(clk), .rst_i(!reset_n),
        .mgmt_address_o(mgmt_address), .mgmt_read_o(mgmt_read), .mgmt_write_o(mgmt_write),
        .mgmt_writedata_o(mgmt_writedata), .mgmt_readdata_i(mgmt_readdata),
        .fdd_request_i(request), .rtc_i(rtc_word),
        .fdd_mounted_i(m_mounted), .fdd_wp_i(m_wp), .fdd_cyl_i(m_cyl), .fdd_spt_i(m_spt),
        .fdd_total_i(m_total), .fdd_heads_i(m_heads), .fdd_gen_i(m_gen),
        .sd_req_o(sd_req), .sd_req_wr_o(sd_req_wr), .sd_req_lba_o(sd_req_lba),
        .sd_done_i(sd_done), .sd_err_i(sd_err),
        .buf_addr_o(buf_addr), .buf_we_o(buf_we), .buf_wd_o(buf_wd), .buf_rd_i(buf_rd)
    );

    reg [27:0] q_addr = 0;
    reg [15:0] q_wdata = 0;
    reg q_ce = 0, q_we = 0;
    wire [15:0] q_rdata;
    wire q_wait;
    wire [63:0] q2c;
    wire [75:0] c2q;
    fdd_sd #(.G_QNICE_HZ(50000000)) sd (
        .qnice_clk_i(qclk), .qnice_rst_i(qrst),
        .qnice_addr_i(q_addr), .qnice_data_i(q_wdata), .qnice_ce_i(q_ce), .qnice_we_i(q_we),
        .qnice_data_o(q_rdata), .qnice_wait_o(q_wait),
        .sd_q2c_i(q2c), .sd_c2q_o(c2q),
        .mnt_mounted_o(m_mounted), .mnt_wp_o(m_wp), .mnt_cyl_o(m_cyl), .mnt_spt_o(m_spt),
        .mnt_total_o(m_total), .mnt_heads_o(m_heads), .mnt_gen_o(m_gen),
        .req_i(sd_req), .req_wr_i(sd_req_wr), .req_lba_i(sd_req_lba),
        .done_o(sd_done), .done_err_o(sd_err),
        .main_clk_i(clk), .buf_addr_i(buf_addr), .buf_we_i(buf_we), .buf_wd_i(buf_wd),
        .buf_rd_o(buf_rd)
    );

    // ------------------------------------------------------------------------------------------
    // The image: base 1000, 4 sectors per cluster, extents (10, 1) and (50, 1000)
    // ------------------------------------------------------------------------------------------
    function automatic integer blk(input integer lba);
        integer c;
        c = lba / 4;
        blk = 1000 + ((c == 0) ? 10 : 50 + c - 1) * 4 + lba % 4;
    endfunction
    function automatic [7:0] sdbyte(input integer b, input integer i);
        sdbyte = 8'(b * 7 ^ i ^ (i >> 8) ^ 8'h5a);
    endfunction
    function automatic [7:0] pattern(input integer n);
        pattern = 8'(n ^ (n >> 8) ^ 8'ha5);
    endfunction

    // ------------------------------------------------------------------------------------------
    // The SD engine port (sdhost_pkg's bits): ready; a START moves one block after a while
    // ------------------------------------------------------------------------------------------
    reg e_busy = 0, e_done = 0, e_err = 0, e_blk = 0, e_rdwe = 0;
    reg [8:0] e_rdidx = 0, e_wridx = 0;
    reg [7:0] e_rddata = 0;
    assign q2c = {e_wridx, 16'd0, e_rddata, e_rdidx, 16'd0, e_rdwe, e_blk, e_err, e_done,
                  e_busy, 1'b1};
    integer fail_read_blk = -1;           // this block fails once
    integer preempt_write = 1;            // the first write is preempted once
    integer eng_reads = 0, eng_writes = 0;
    integer write_errors = 0;
    integer expect_write_lba [integer];   // block -> the LBA whose DMA bytes it must get
    always begin
        integer b, i;
        bit wr;
        @(posedge qclk);
        if (c2q[0]) begin
            b = c2q[34:3];
            wr = c2q[1];
            if (c2q[50:35] != 1) $fatal(1, "engine: count %0d", c2q[50:35]);
            e_busy <= 1;
            repeat (40) @(posedge qclk);
            if (!wr && b == fail_read_blk) begin
                fail_read_blk = -1;
                $display("  engine: block %0d fails once", b);
                e_done <= 1; e_err <= 1; @(posedge qclk); e_done <= 0; e_err <= 0;
            end else if (wr && preempt_write) begin
                preempt_write = 0;
                $display("  engine: write of block %0d preempted once", b);
                e_done <= 1; @(posedge qclk); e_done <= 0;
            end else if (!wr) begin
                for (i = 0; i < 512; i++) begin
                    e_rdwe <= 1; e_rdidx <= i; e_rddata <= sdbyte(b, i);
                    @(posedge qclk);
                end
                e_rdwe <= 0;
                e_blk <= 1; @(posedge qclk); e_blk <= 0;
                e_done <= 1; @(posedge qclk); e_done <= 0;
                eng_reads++;
            end else begin
                // the byte named by WRIDX is there one clock later (a block RAM's output after
                // the edge that takes the address): sampled mid-clock, away from that edge
                for (i = 0; i < 512; i++) begin
                    e_wridx <= i;
                    @(posedge qclk);
                    @(negedge qclk);
                    if (!expect_write_lba.exists(b)) begin
                        if (i == 0) $error("engine: write to unexpected block %0d", b);
                        write_errors++;
                    end else if (c2q[74:67] !== pattern(expect_write_lba[b] * 512 + i)) begin
                        if (write_errors < 5)
                            $error("engine: block %0d byte %0d = %02x", b, i, c2q[74:67]);
                        write_errors++;
                    end
                end
                @(posedge qclk);
                e_blk <= 1; @(posedge qclk); e_blk <= 0;
                e_done <= 1; @(posedge qclk); e_done <= 0;
                eng_writes++;
            end
            e_busy <= 0;
        end
    end

    // ------------------------------------------------------------------------------------------
    // QNICE writes (fdd_sd samples them on the falling edge) and the PC's I/O
    // ------------------------------------------------------------------------------------------
    task automatic qwr(input [27:0] a, input [15:0] d);
        @(posedge qclk);
        q_addr <= a; q_wdata <= d; q_ce <= 1; q_we <= 1;
        @(posedge qclk);
        q_ce <= 0; q_we <= 0;
    endtask
    task automatic write8(input [15:0] port, input [7:0] value);
        @(negedge clk);
        cpu_addr = port[15:2]; cpu_be = 4'b0001 << port[1:0];
        cpu_din = {4{value}}; cpu_io_wr = 1;
        do @(posedge clk); while (!cpu_io_ready);
        @(negedge clk); cpu_io_wr = 0;
        repeat (2) @(posedge clk);
    endtask
    task automatic read8(input [15:0] port, output [7:0] value);
        @(negedge clk);
        cpu_addr = port[15:2]; cpu_be = 4'b0001 << port[1:0]; cpu_io_rd = 1;
        do @(posedge clk); while (!cpu_io_ready);
        value = 8'(cpu_dout >> (port[1:0] * 8));
        @(negedge clk); cpu_io_rd = 0;
        repeat (2) @(posedge clk);
    endtask
    task automatic command_byte(input [7:0] value);
        reg [7:0] status;
        do read8(16'h3f4, status); while (status[7:6] != 2'b10);
        write8(16'h3f5, value);
    endtask
    task automatic cmos_rd(input [6:0] index, output [7:0] value);
        write8(16'h070, {1'b0, index});
        read8(16'h071, value);
    endtask

    // DMA: delayed acknowledgments, terminal count on the last byte (tb_floppy_io.sv)
    integer dma_count = 0, dma_gap = 0, dma_lba0 = 0, dma_errors = 0;
    bit dma_to_pc = 0;
    always @(negedge clk) begin
        dma_ack = 0; dma_tc = 0;
        if (reset_n && dma_req) begin
            if (dma_gap != 0) dma_gap--;
            else begin
                if (dma_count >= 1024) $fatal(1, "extra DMA byte");
                if (dma_to_pc && dma_writedata !== sdbyte(blk(dma_lba0 + dma_count / 512), dma_count % 512)) begin
                    if (dma_errors < 5)
                        $error("DMA byte %0d (LBA %0d): %02x != %02x", dma_count,
                               dma_lba0 + dma_count / 512, dma_writedata,
                               sdbyte(blk(dma_lba0 + dma_count / 512), dma_count % 512));
                    dma_errors++;
                end
                dma_readdata = pattern((dma_lba0 + dma_count / 512) * 512 + dma_count % 512);
                dma_ack = 1; dma_tc = (dma_count == 1023);
                dma_count++; dma_gap = 3 + dma_count % 7;
            end
        end
    end

    // Two sectors on A:, from cylinder 0 head 0 sector s (LBA s - 1)
    task automatic transfer(input integer s, input bit read_disk);
        reg [7:0] value;
        integer k;
        dma_to_pc = read_disk;
        dma_count = 0; dma_lba0 = s - 1;
        if (!read_disk) begin
            expect_write_lba[blk(s - 1)] = s - 1;
            expect_write_lba[blk(s)] = s;
        end
        write8(16'h3f2, 8'h1c);
        command_byte(8'h07); command_byte(8'h00);           // recalibrate
        wait (irq);
        command_byte(8'h08);
        read8(16'h3f5, value); read8(16'h3f5, value);
        command_byte(read_disk ? 8'h46 : 8'h45);
        command_byte(8'h00);
        command_byte(0); command_byte(0); command_byte(s[7:0]);
        command_byte(2); command_byte(s[7:0] + 1); command_byte(8'h1b); command_byte(8'hff);
        wait (irq);
        if (dma_count != 1024) $fatal(1, "incomplete transfer dma=%0d", dma_count);
        for (k = 0; k < 7; k++) begin
            read8(16'h3f5, value);
            if (k == 0 && value[7:6] != 0) $fatal(1, "bad ST0 %02x", value);
            if ((k == 1 || k == 2) && value != 0) $fatal(1, "bad ST%0d %02x", k, value);
        end
        $display("ok    %s LBA %0d-%0d", read_disk ? "read " : "write", s - 1, s);
    endtask

    integer errors = 0;
    initial begin
        reg [7:0] v, b10, b14, b15, b16, hi, lo;
        integer sum, k;
        repeat (5) @(negedge clk);
        reset_n = 1;
        repeat (5) @(posedge qclk);
        qrst = 0;

        // the firmware's FDD_PREP: the map (window 1), the registers, MODE last
        qwr(28'h0001000, 16'd2);
        qwr(28'h0001001, 16'd10); qwr(28'h0001002, 16'd0); qwr(28'h0001003, 16'd1); qwr(28'h0001004, 16'd0);
        qwr(28'h0001005, 16'd50); qwr(28'h0001006, 16'd0); qwr(28'h0001007, 16'd1000); qwr(28'h0001008, 16'd0);
        qwr(28'h0000001, 16'd2880); qwr(28'h0000002, 16'd0);
        qwr(28'h0000003, 16'd1000); qwr(28'h0000004, 16'd0);
        qwr(28'h0000005, 16'd2);
        qwr(28'h0000006, 16'd80); qwr(28'h0000007, 16'd18); qwr(28'h0000008, 16'd2);
        qwr(28'h0000000, 16'd1);

        wait (fdd0_inserted);
        $display("ok    A: inserted after %0t", $time);

        // the CMOS the BIOS reads
        cmos_rd(7'h10, b10); cmos_rd(7'h14, b14); cmos_rd(7'h15, b15); cmos_rd(7'h16, b16);
        if (b10 != 8'h44 || b15 != 8'h80 || b16 != 8'h02 || b14[0] != 1) begin
            $error("CMOS 10h %02x 14h %02x 15h %02x 16h %02x", b10, b14, b15, b16); errors++;
        end else
            $display("ok    CMOS drives %02x, equipment %02x, base memory %02x%02x", b10, b14, b16, b15);
        sum = 0;
        for (k = 16'h10; k <= 16'h2D; k++) begin cmos_rd(k[6:0], v); sum += v; end
        cmos_rd(7'h2E, hi); cmos_rd(7'h2F, lo);
        if ({hi, lo} != 16'(sum)) begin
            $error("CMOS checksum %02x%02x, the bytes add up to %04x", hi, lo, 16'(sum)); errors++;
        end else
            $display("ok    CMOS checksum %02x%02x", hi, lo);
        cmos_rd(7'h00, v); cmos_rd(7'h02, hi); cmos_rd(7'h04, lo);
        $display("      CMOS time %02x:%02x:%02x", lo, hi, v);
        cmos_rd(7'h07, v); cmos_rd(7'h08, hi); cmos_rd(7'h09, lo);
        $display("      CMOS date %02x.%02x.%02x", v, hi, lo);

        command_byte(8'h03); command_byte(8'hdf); command_byte(8'h02);   // specify
        transfer(1, 1);                       // LBA 0-1: the first extent
        fail_read_blk = blk(4);
        transfer(5, 1);                       // LBA 4-5: the second extent, one failure
        transfer(1, 0);                       // write LBA 0-1, preempted once
        if (dma_errors != 0) begin $error("%0d DMA bytes wrong", dma_errors); errors++; end
        if (write_errors != 0) begin $error("%0d written bytes wrong", write_errors); errors++; end
        if (eng_reads != 4 || eng_writes != 2) begin
            $error("engine: %0d reads, %0d writes", eng_reads, eng_writes); errors++;
        end
        if (errors == 0) $display("PASS: all checks");
        else $display("FAILED: %0d checks", errors);
        $finish;
    end
    initial begin
        #400000000;
        $fatal(1, "timeout: FDC state %0d dma %0d", fdc.state, dma_count);
    end
endmodule
