// tb_inta: the mouse's IRQ12 against the CD-ROM's IRQ15 on the slave PIC, through the INTA
// bridge (pic.v, pic_inta_bridge.sv as patched by tools/z486_sources.py). The CPU takes the
// vector on its second INTA, the PIC acknowledges a clock later; IRQ12 rising in between must
// not be acknowledged in IRQ15's place, or its line stays high with no new edge and the mouse
// (and the keyboard behind it in the 8042) is dead for good. IRQ12 is swept across the whole
// INTA sequence; with HOLD=0 (vector_hold off, upstream's behaviour) the race must show, with
// HOLD=1 every case must serve both handlers and count no mismatched INTA.
// Run with Verilator (Icarus rejects pic.v's names used before their declarations), after
// tools/z486_sources.py:
//   $ verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -DHOLD=1 --top-module tb_inta \
//       -Mdir CORE/sim/build/vinta -o tb_inta CORE/sim/tb_inta.sv \
//       CORE/gen/z486_MiSTer/src/soc/pic.v CORE/gen/z486_MiSTer/src/pic_inta_bridge.sv &&
//   $ CORE/sim/build/vinta/tb_inta
`timescale 1ns / 1ps

`ifndef HOLD
`define HOLD 1
`endif

module tb_inta;

reg         clk = 1'b0;
reg         rst_n = 1'b0;
always #7.8125 clk = ~clk;

// the I/O bus to the PICs: one-clock strobes, as z486's iobus_adapter.sv gives; from the setup
// (t_) or the CPU's handlers (c_: EOIs to port 20h/A0h)
reg         t_address = 1'b0, t_write = 1'b0, t_master_cs = 1'b0, t_slave_cs = 1'b0;
reg   [7:0] t_data = 8'h00;
reg         c_write = 1'b0, c_master_cs = 1'b0, c_slave_cs = 1'b0;
wire        io_address   = c_write ? 1'b0 : t_address;
wire        io_write     = c_write | t_write;
wire  [7:0] io_writedata = c_write ? 8'h20 : t_data;
wire        io_master_cs = c_master_cs | t_master_cs;
wire        io_slave_cs  = c_slave_cs | t_slave_cs;
wire  [7:0] io_readdata;

reg         irq12 = 1'b0;                  // the 8042's: high until port 60h is read
reg         irq15 = 1'b0;                  // the CD-ROM's: high until its status is read

wire        interrupt_do, interrupt_done, vector_hold;
wire  [7:0] interrupt_vector;
wire [47:0] dbg_regs;
wire [15:0] mismatches, mismatch_last;

pic dut_pic (
    .clk(clk), .rst_n(rst_n),
    .io_address(io_address), .io_read(1'b0), .io_readdata(io_readdata),
    .io_write(io_write), .io_writedata(io_writedata),
    .io_master_cs(io_master_cs), .io_slave_cs(io_slave_cs),
    .interrupt_input({irq15, 2'b00, irq12, 12'h000}),
    .interrupt_do(interrupt_do), .interrupt_vector(interrupt_vector),
    .interrupt_done(interrupt_done),
    .vector_hold(vector_hold), .dbg_regs(dbg_regs)
);

wire        cpu_intr, inta_ready;
wire [31:0] inta_din;
reg         cpu_inta = 1'b0;

pic_inta_bridge dut_bridge (
    .clk(clk), .reset_n(rst_n),
    .pic_interrupt_do(interrupt_do), .pic_interrupt_vector(interrupt_vector),
    .pic_interrupt_done(interrupt_done),
    .cpu_intr(cpu_intr), .cpu_inta(cpu_inta), .cpu_inta_din(inta_din),
    .cpu_inta_ready(inta_ready),
    .vector_hold_en(`HOLD != 0), .vector_hold(vector_hold),
    .dbg_mismatches(mismatches), .dbg_mismatch_last(mismatch_last)
);

// The CPU (z486's bus_unit.sv): an INTA cycle stays up until the clock it sees ready; two of
// them, a few clocks apart; then the handler: it serves its device (the line drops) and sends
// non-specific EOIs to the slave and the master, as the BIOS and the CD-ROM driver do
localparam C_IDLE = 0, C_A1 = 1, C_GAP = 2, C_A2 = 3, C_RUN = 4, C_EOI_S = 5, C_EOI_M = 6,
           C_DONE = 7;
reg   [2:0] cs = C_IDLE;
reg   [7:0] cnt = 8'd0;
reg   [7:0] vec = 8'h00;
reg         cpu_en = 1'b0;
integer     served12 = 0, served15 = 0;

always @(posedge clk) begin
    c_write <= 1'b0; c_master_cs <= 1'b0; c_slave_cs <= 1'b0;
    if (!rst_n) begin
        cs <= C_IDLE;
        cpu_inta <= 1'b0;
    end else case (cs)
        C_IDLE:  if (cpu_en && cpu_intr) begin cpu_inta <= 1'b1; cs <= C_A1; end
        C_A1:    if (inta_ready) begin cpu_inta <= 1'b0; cnt <= 8'd2; cs <= C_GAP; end
        C_GAP:   if (cnt == 0) begin cpu_inta <= 1'b1; cs <= C_A2; end else cnt <= cnt - 1'd1;
        C_A2:    if (inta_ready) begin
                     cpu_inta <= 1'b0; vec <= inta_din[7:0]; cnt <= 8'd20; cs <= C_RUN;
                 end
        C_RUN:   if (cnt == 0) begin
                     if (vec == 8'h74) begin irq12 <= 1'b0; served12 = served12 + 1; end
                     if (vec == 8'h77) begin irq15 <= 1'b0; served15 = served15 + 1; end
                     cs <= C_EOI_S;
                 end else cnt <= cnt - 1'd1;
        C_EOI_S: begin c_slave_cs <= 1'b1; c_write <= 1'b1; cs <= C_EOI_M; end
        C_EOI_M: begin c_master_cs <= 1'b1; c_write <= 1'b1; cnt <= 8'd4; cs <= C_DONE; end
        C_DONE:  if (cnt == 0) cs <= C_IDLE; else cnt <= cnt - 1'd1;
    endcase
end

// an OUT to the master (port 20h/21h) or the slave (A0h/A1h) while the CPU model is off
task out_pic(input slave, input a0, input [7:0] v);
begin
    @(posedge clk);
    t_master_cs <= ~slave; t_slave_cs <= slave; t_address <= a0; t_data <= v; t_write <= 1'b1;
    @(posedge clk);
    t_write <= 1'b0; t_master_cs <= 1'b0; t_slave_cs <= 1'b0;
    repeat (2) @(posedge clk);
end
endtask

// the Bochs BIOS's PIC setup, then everything unmasked
task init_pic;
begin
    out_pic(0, 0, 8'h11); out_pic(1, 0, 8'h11);
    out_pic(0, 1, 8'h08); out_pic(1, 1, 8'h70);
    out_pic(0, 1, 8'h04); out_pic(1, 1, 8'h02);
    out_pic(0, 1, 8'h01); out_pic(1, 1, 8'h01);
    out_pic(0, 1, 8'h00); out_pic(1, 1, 8'h00);
end
endtask

integer k, lost, bad_total, s12, s15;

initial begin
    lost = 0;
    bad_total = 0;
    for (k = 0; k < 40; k = k + 1) begin
        cpu_en <= 1'b0; irq12 <= 1'b0; irq15 <= 1'b0; rst_n <= 1'b0;
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);
        init_pic;
        s12 = served12; s15 = served15;
        cpu_en <= 1'b1;
        irq15 <= 1'b1;                     // the CD-ROM
        repeat (k) @(posedge clk);
        irq12 <= 1'b1;                     // the mouse, k clocks later
        repeat (300) @(posedge clk);
        bad_total = bad_total + mismatches;
        if (irq12 || irq15) begin
            lost = lost + 1;
            $display("k=%2d: LOST %s%s (IRQ15 served %0d, IRQ12 served %0d; mismatched INTAs %0d, last: CPU %02X, PIC %02X)",
                     k, irq12 ? "IRQ12 " : "", irq15 ? "IRQ15" : "",
                     served15 - s15, served12 - s12, mismatches, mismatch_last[15:8],
                     mismatch_last[7:0]);
        end
    end
    $display("tb_inta (HOLD=%0d): %0d of 40 cases lost an IRQ, %0d INTAs acknowledged another vector",
             `HOLD, lost, bad_total);
    if (`HOLD ? (lost == 0 && bad_total == 0) : (lost != 0))
        $display("tb_inta: PASS");
    else
        $display("tb_inta: FAIL");
    $finish;
end

endmodule
