// z486 for MEGA65
//
// tb_floppy_err: z486_sources.py's floppy.v patch: FORMAT on the internal drive (registers 8-12,
// register 7 per ID), real_speed (an image's sector waits for its slot
// of a turning disk and for an implied seek's steps); for the internal floppy drive (fdd_phys.vhd):
// register 1 (the waiting sector's cylinder, head, sector), register 6 (an error ends the
// command: IRQ 6, the result phase with ST0 40h + head, ST1, ST2, C H R N, then ready for the
// next command; with nothing waiting it does nothing), DIR bit 7 from ext_chg. Reads
// CORE/gen's patched floppy.v (tools/z486_sources.py writes it); CORE/sim/run_floppy_err.sh
// runs it with Icarus Verilog.
//
// Licensed under GPL v3

`timescale 1ns/1ps
module tb;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  reg [2:0] io_address = 0; reg io_read = 0, io_write = 0; reg [7:0] io_writedata = 0;
  wire [7:0] io_readdata;
  reg [3:0] mgmt_address = 0; reg mgmt_fddn = 0, mgmt_write = 0, mgmt_read = 0; reg [15:0] mgmt_writedata = 0;
  wire [15:0] mgmt_readdata; wire [1:0] request; wire irq; wire dma_req;
  wire [1:0] drv_motor; wire drv_sel; wire [15:0] drv_cyl;
  reg [1:0] ext_chg_en = 2'b00, ext_chg = 2'b00;
  reg real_speed = 0;
  integer errors = 0;
  floppy dut(.clk(clk), .rst_n(rst_n), .dma_req(dma_req), .dma_ack(1'b0), .dma_tc(1'b0), .dma_readdata(8'd0),
    .dma_writedata(), .irq(irq), .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
    .io_write(io_write), .io_writedata(io_writedata), .fdd0_inserted(), .mgmt_address(mgmt_address),
    .mgmt_fddn(mgmt_fddn), .mgmt_write(mgmt_write), .mgmt_writedata(mgmt_writedata), .mgmt_read(mgmt_read),
    .mgmt_readdata(mgmt_readdata), .wp(2'b00), .clock_rate(28'd1000000), .request(request),
    .drv_motor(drv_motor), .drv_sel(drv_sel), .drv_cyl(drv_cyl), .ext_chg_en(ext_chg_en), .ext_chg(ext_chg),
    .real_speed(real_speed));
  task iow(input [2:0] a, input [7:0] d); begin
    @(posedge clk); io_address <= a; io_writedata <= d; io_write <= 1; @(posedge clk); io_write <= 0; repeat(3) @(posedge clk); end endtask
  task ior(input [2:0] a, output [7:0] d); begin
    @(posedge clk); io_address <= a; repeat(2) @(posedge clk); d = io_readdata; io_read <= 1; @(posedge clk); io_read <= 0; repeat(3) @(posedge clk); end endtask
  task mw(input [3:0] a, input [15:0] d); begin
    @(posedge clk); mgmt_address <= a; mgmt_writedata <= d; mgmt_write <= 1; @(posedge clk); mgmt_write <= 0; @(posedge clk); end endtask
  task mr(input [3:0] a); begin
    @(posedge clk); mgmt_address <= a; mgmt_read <= 1; @(posedge clk); mgmt_read <= 0; @(posedge clk); end endtask
  task check(input ok, input [8*60-1:0] what); begin
    if (ok) $display("ok   %0s", what); else begin $display("FAIL %0s", what); errors = errors + 1; end end endtask
  reg [7:0] b, st0, st1, st2, c, h, r, n;
  integer i, j, k, t;
  initial begin
    repeat(5) @(posedge clk); rst_n = 1; repeat(5) @(posedge clk);
    // media in A:: 80 cyl, 18 spt, 2880, 2 heads, present
    mw(2, 80); mw(3, 36); mw(4, 6048); mw(5, 2); mw(1, 0); mw(0, 1);
    iow(2, 8'h1C);                         // DOR: motor A, enable, DMA, drive 0
    iow(5, 8'h03); iow(5, 8'hDF); iow(5, 8'h02);   // SPECIFY (DMA mode)
    // READ DATA: MT MFM SK, drive 0 head 1, C=5 H=1 R=3 N=2 EOT=18 GPL=1B DTL=FF
    iow(5, 8'hE6); iow(5, 8'h04); iow(5, 8'd5); iow(5, 8'd1); iow(5, 8'd3); iow(5, 8'd2); iow(5, 8'd18); iow(5, 8'h1B); iow(5, 8'hFF);
    repeat(400) @(posedge clk);
    check(request == 2'b01, "a read request");
    mgmt_address <= 1; repeat(3) @(posedge clk);
    check(mgmt_readdata == {8'd5, 1'b1, 7'd3}, "register 1: C 5, H 1, R 3");
    check(drv_cyl[7:0] == 5, "drv_cyl: A: on 5");
    mw(6, 16'h2020);                       // DE, DD
    repeat(10) @(posedge clk);
    check(request == 2'b00, "the request gone after the error");
    check(irq == 1, "IRQ 6");
    ior(4, b); check(b[7:6] == 2'b11 && b[4] == 1, "MSR: result phase (RQM, DIO, busy)");
    ior(5, st0); ior(5, st1); ior(5, st2); ior(5, c); ior(5, h); ior(5, r); ior(5, n);
    check(st0 == 8'h44, "ST0 44 (abnormal, head 1)");
    check(st1 == 8'h20 && st2 == 8'h20, "ST1 20, ST2 20");
    check(c == 5 && h == 1 && r == 3 && n == 2, "C H R N 5 1 3 2");
    ior(4, b); check(b[7:6] == 2'b10 && b[4] == 0, "MSR: ready for the next command");
    // a second read, answered with 'not found'
    iow(5, 8'hE6); iow(5, 8'h00); iow(5, 8'd7); iow(5, 8'd0); iow(5, 8'd9); iow(5, 8'd2); iow(5, 8'd18); iow(5, 8'h1B); iow(5, 8'hFF);
    repeat(400) @(posedge clk);
    check(request == 2'b01, "a second read request");
    mw(6, 16'h0004);
    repeat(10) @(posedge clk);
    ior(5, st0); ior(5, st1); ior(5, st2);
    check(st0 == 8'h40 && st1 == 8'h04 && st2 == 8'h00, "ST0 40 ST1 04 ST2 00");
    repeat(4) ior(5, b);
    // register 6 while nothing waits: no effect
    mw(6, 16'h0001); repeat(10) @(posedge clk);
    ior(4, b); check(b[7:6] == 2'b10, "register 6 with nothing waiting: ignored");
    // a read (non-DMA) that ends at the end of the track on head 1 (MT): the result says C+1 as
    // an 82077's does, the head (drv_cyl) stays where the read was
    iow(5, 8'h03); iow(5, 8'hDF); iow(5, 8'h03);   // SPECIFY: non-DMA
    iow(5, 8'hE6); iow(5, 8'h04); iow(5, 8'd5); iow(5, 8'd1); iow(5, 8'd18); iow(5, 8'd2); iow(5, 8'd18); iow(5, 8'h1B); iow(5, 8'hFF);
    repeat(400) @(posedge clk);
    check(request == 2'b01, "a read of C 5 H 1 R 18 (the track's end)");
    for (i = 0; i < 512; i = i + 1) mw(15, i[7:0]);
    for (i = 0; i < 512; i = i + 1) begin
      j = 0; b = 0;
      while (b[7] == 0 && j < 2000) begin ior(4, b); j = j + 1; end
      ior(5, b);
    end
    j = 0; b = 0;
    while (b[7:6] != 2'b11 && j < 400000) begin ior(4, b); j = j + 1; end
    ior(5, st0); ior(5, st1); ior(5, st2); ior(5, c); ior(5, h); ior(5, r); ior(5, n);
    check(st0[7:6] == 2'b00 && st1 == 0 && st2 == 0, "the read done");
    check(c == 6 && r == 1, "result C 6, R 1 (C+1 at the track's end on head 1)");
    check(drv_cyl[7:0] == 5, "drv_cyl: the head still on 5");
    // a write to the internal drive (ext_chg_en): each sector waits, its FIFO emptied, until
    // register 7 says it is on the disk; an error then (register 6) ends the command
    ext_chg_en = 2'b01; ext_chg = 2'b00;
    iow(5, 8'hC5); iow(5, 8'h04); iow(5, 8'd5); iow(5, 8'd1); iow(5, 8'd17); iow(5, 8'd2); iow(5, 8'd18); iow(5, 8'h1B); iow(5, 8'hFF);
    for (k = 0; k < 2; k = k + 1) begin
      for (i = 0; i < 512; i = i + 1) begin
        j = 0; b = 0;
        while (b[7] == 0 && j < 2000) begin ior(4, b); j = j + 1; end
        iow(5, i[7:0]);
      end
      j = 0;
      while (request != 2'b10 && j < 400000) begin @(posedge clk); j = j + 1; end
      check(request == 2'b10, k == 0 ? "write: a request for C 5 H 1 R 17" : "write: then R 18");
      mgmt_address <= 1; repeat(3) @(posedge clk);
      check(mgmt_readdata == {8'd5, 1'b1, k == 0 ? 7'd17 : 7'd18}, "write: register 1 says that sector");
      for (i = 0; i < 512; i = i + 1) mr(15);
      repeat(200) @(posedge clk);
      check(request == 2'b10, "write: the FIFO empty, the request held");
      if (k == 0) begin
        mw(7, 16'h0001);
        repeat(20) @(posedge clk);
        check(request == 2'b00, "write: register 7, the request gone (the next sector)");
      end
    end
    mw(6, 16'h0010);                      // OR: the write cut short
    repeat(10) @(posedge clk);
    check(request == 2'b00, "write: register 6 ends it");
    j = 0; b = 0;
    while (b[7:6] != 2'b11 && j < 400000) begin ior(4, b); j = j + 1; end
    ior(5, st0); ior(5, st1); ior(5, st2); ior(5, c); ior(5, h); ior(5, r); ior(5, n);
    check(st0 == 8'h44 && st1 == 8'h10 && st2 == 8'h00, "write: ST0 44 ST1 10 ST2 00");
    check(c == 5 && h == 1 && r == 18, "write: C H R 5 1 18 (the sector that failed)");
    ext_chg_en = 2'b00;
    iow(5, 8'h07); iow(5, 8'h00);                  // RECALIBRATE
    repeat(400) @(posedge clk);
    check(drv_cyl[7:0] == 0, "drv_cyl: 0 after RECALIBRATE");
    iow(5, 8'h0F); iow(5, 8'h00); iow(5, 8'd9);    // SEEK 9
    repeat(400) @(posedge clk);
    check(drv_cyl[7:0] == 9, "drv_cyl: 9 after SEEK");
    j = 0; while (irq == 0 && j < 600000) begin @(posedge clk); j = j + 1; end
    iow(5, 8'h08); ior(5, st0); ior(5, c);         // SENSE INTERRUPT: the seek done
    check(st0 == 8'h20 && c == 9, "SEEK 9 done (ST0 20, PCN 9)");
    // real_speed (clock_rate 1000000: a turn in 200000 clocks, 36 slots of 5556 (this media's
    // 36 sectors per track); a step unit
    // at 250 kbit/s, data_rate 2, 2000 clocks; SPECIFY DF: (16 - 13) units a step): an image's
    // sector waits until it has passed under the head
    real_speed = 1;
    iow(5, 8'hE6); iow(5, 8'h00); iow(5, 8'd9); iow(5, 8'd0); iow(5, 8'd5); iow(5, 8'd2); iow(5, 8'd18); iow(5, 8'h1B); iow(5, 8'hFF);
    t = 0; while (request == 2'b00 && t < 600000) begin @(posedge clk); t = t + 1; end
    $display("     real speed, C 9 R 5: the request after %0d clocks", t);
    check(request == 2'b01 && dut.rs_last == 4, "real speed: R 5 after slot 4 has passed");
    check(t > 0 && t <= 200000 + 400, "real speed: within a turn");
    mw(6, 16'h0004); repeat(10) @(posedge clk); repeat(7) ior(5, b);
    // the next sector of the same track: one slot later, give or take the command's bytes
    iow(5, 8'hE6); iow(5, 8'h00); iow(5, 8'd9); iow(5, 8'd0); iow(5, 8'd6); iow(5, 8'd2); iow(5, 8'd18); iow(5, 8'h1B); iow(5, 8'hFF);
    t = 0; while (request == 2'b00 && t < 600000) begin @(posedge clk); t = t + 1; end
    $display("     real speed, C 9 R 6: the request after %0d clocks", t);
    check(request == 2'b01 && dut.rs_last == 5 && t < 5557, "real speed: R 6 one slot after R 5");
    mw(6, 16'h0004); repeat(10) @(posedge clk); repeat(7) ior(5, b);
    // an implied seek of 2 cylinders: 2 x 3 + 15 = 21 units (42000 clocks), then the slot
    iow(5, 8'hE6); iow(5, 8'h00); iow(5, 8'd11); iow(5, 8'd0); iow(5, 8'd1); iow(5, 8'd2); iow(5, 8'd18); iow(5, 8'h1B); iow(5, 8'hFF);
    repeat(5) @(posedge clk);
    check(dut.rs_seek >= 20 && dut.rs_seek <= 21, "real speed: C 11, an implied seek of 21 units");
    t = 0; while (request == 2'b00 && t < 600000) begin @(posedge clk); t = t + 1; end
    $display("     real speed, C 11 R 1: the request after %0d clocks", t);
    check(request == 2'b01 && dut.rs_last == 0 && t >= 40000, "real speed: R 1 after the seek and slot 0");
    check(drv_cyl[7:0] == 11, "real speed: drv_cyl 11");
    mw(6, 16'h0004); repeat(10) @(posedge clk); repeat(7) ior(5, b);
    // the internal drive (ext_chg_en) is a real one: no wait
    ext_chg_en = 2'b01;
    iow(5, 8'hE6); iow(5, 8'h00); iow(5, 8'd11); iow(5, 8'd0); iow(5, 8'd9); iow(5, 8'd2); iow(5, 8'd18); iow(5, 8'h1B); iow(5, 8'hFF);
    t = 0; while (request == 2'b00 && t < 600000) begin @(posedge clk); t = t + 1; end
    check(request == 2'b01 && t < 400, "real speed: the internal drive's request at once");
    mw(6, 16'h0004); repeat(10) @(posedge clk); repeat(7) ior(5, b);
    ext_chg_en = 2'b00; real_speed = 0;
    // FORMAT on the internal drive (non-DMA): 3 sectors (the mount has 36), gap 3 54h, filler
    // F6, the IDs on cylinder 12 with the head on 11 (the implied seek the Bochs BIOS relies
    // on); each ID in registers 8-12, held until register 7, then the result
    ext_chg_en = 2'b01;
    iow(5, 8'h4D); iow(5, 8'h00); iow(5, 8'h02); iow(5, 8'd3); iow(5, 8'h54); iow(5, 8'hF6);
    for (k = 0; k < 3; k = k + 1) begin
      for (i = 0; i < 4; i = i + 1) begin
        j = 0; b = 0;
        while (b[7] == 0 && j < 2000) begin ior(4, b); j = j + 1; end
        iow(5, i == 0 ? 8'd12 : i == 1 ? 8'd0 : i == 2 ? 8'd1 + k[7:0] : 8'd2);
      end
      j = 0;
      while (request != 2'b10 && j < 4000) begin @(posedge clk); j = j + 1; end
      check(request == 2'b10, k == 0 ? "format: a write request for the first ID" : "format: the next ID");
      mgmt_address <= 8; repeat(3) @(posedge clk);
      check(mgmt_readdata[15] == 1 && mgmt_readdata[7:0] == 12, "format: register 8 (FORMAT, the head sought to 12)");
      mgmt_address <= 9; repeat(3) @(posedge clk);
      check(mgmt_readdata == 16'h0354, "format: register 9 (3 sectors, gap 3 54h)");
      mgmt_address <= 10; repeat(3) @(posedge clk);
      check(mgmt_readdata == {8'd12, 8'd0}, "format: register 10 (C 12, H 0)");
      mgmt_address <= 11; repeat(3) @(posedge clk);
      check(mgmt_readdata == {8'd1 + k[7:0], 8'd2}, "format: register 11 (R, N 2)");
      mgmt_address <= 12; repeat(3) @(posedge clk);
      check(mgmt_readdata == {8'd3 - k[7:0], 8'hF6}, "format: register 12 (IDs left, filler F6)");
      repeat(200) @(posedge clk);
      check(request == 2'b10, "format: held until register 7");
      mw(7, 16'h0001);
      repeat(20) @(posedge clk);
      check(request == 2'b00, "format: register 7, the request gone");
    end
    j = 0; b = 0;
    while (b[7:6] != 2'b11 && j < 400000) begin ior(4, b); j = j + 1; end
    ior(5, st0); ior(5, st1); ior(5, st2); ior(5, c); ior(5, h); ior(5, r); ior(5, n);
    check(st0[7:6] == 2'b00 && st1 == 0 && st2 == 0, "format: done, ST0 normal");
    check(drv_cyl[7:0] == 12, "format: drv_cyl 12 (the implied seek)");
    ext_chg_en = 2'b00;
    // DIR bit 7
    ior(7, b); check(b[7] == 0, "DIR: the image's change line (media present, read done)");
    ext_chg_en = 2'b01; ext_chg = 2'b01; ior(7, b); check(b[7] == 1, "DIR: the internal drive's line, active");
    ext_chg = 2'b00; ior(7, b); check(b[7] == 0, "DIR: the internal drive's line, inactive");
    if (errors == 0) $display("PASS"); else $display("FAILED %0d", errors);
    $finish;
  end
endmodule
