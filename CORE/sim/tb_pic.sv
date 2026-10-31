// tb_pic: the reboot race of the keyboard's IRQ1 against the Bochs BIOS's PIC setup (pic.v).
// The BIOS sets up the keyboard before the PICs; a key released in between leaves IRQ1 high when
// ICW1 clears IRR. The 8259 must still deliver it once IMR lets it through (the MEGA65 patch in
// tools/z486_sources.py), or the keyboard stays dead. Also checks that a request rising after
// the setup comes through, and that a high line is served once, not again after the EOI.
// Run by CORE/sim/run_ps2.sh (tb_pic); EXPECT_FAIL=1 runs it against upstream's pic.v, where
// the first check must fail.
`timescale 1ns / 1ps

module tb_pic;

reg         clk = 1'b0;
reg         rst_n = 1'b0;
reg         io_address = 1'b0;
reg         io_read = 1'b0;
wire  [7:0] io_readdata;
reg         io_write = 1'b0;
reg   [7:0] io_writedata = 8'h00;
reg         io_master_cs = 1'b0;
reg         io_slave_cs = 1'b0;
reg  [15:0] interrupt_input = 16'h0000;
wire        interrupt_do;
wire  [7:0] interrupt_vector;
reg         interrupt_done = 1'b0;

integer     errors = 0;

pic dut (
    .clk(clk), .rst_n(rst_n),
    .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
    .io_write(io_write), .io_writedata(io_writedata),
    .io_master_cs(io_master_cs), .io_slave_cs(io_slave_cs),
    .interrupt_input(interrupt_input),
    .interrupt_do(interrupt_do), .interrupt_vector(interrupt_vector),
    .interrupt_done(interrupt_done)
);

always #7.8125 clk = ~clk;

// an OUT to the master (port 20h/21h) or the slave (A0h/A1h): a one-clock strobe, as z486's
// I/O bus gives (iobus_adapter.sv)
task out_pic(input slave, input a0, input [7:0] v);
begin
    @(posedge clk);
    io_master_cs <= ~slave; io_slave_cs <= slave; io_address <= a0; io_writedata <= v;
    io_write <= 1'b1;
    @(posedge clk);
    io_write <= 1'b0; io_master_cs <= 1'b0; io_slave_cs <= 1'b0;
    repeat (4) @(posedge clk);
end
endtask

// post_init_pic of the Bochs BIOS (F000:8BCE in boot0.rom)
task bios_init_pic;
begin
    out_pic(0, 0, 8'h11); out_pic(1, 0, 8'h11);
    out_pic(0, 1, 8'h08); out_pic(1, 1, 8'h70);
    out_pic(0, 1, 8'h04); out_pic(1, 1, 8'h02);
    out_pic(0, 1, 8'h01); out_pic(1, 1, 8'h01);
    out_pic(0, 1, 8'hB8); out_pic(1, 1, 8'h8F);
end
endtask

// waits for the PIC to request an interrupt, takes it (the CPU's INTA) and returns its vector;
// 8'hFF when none comes
task take_irq(output [7:0] vec);
    integer n;
begin
    vec = 8'hFF;
    for (n = 0; n < 50 && vec == 8'hFF; n = n + 1) begin
        @(posedge clk);
        if (interrupt_do) begin
            vec = interrupt_vector;
            interrupt_done <= 1'b1;
            @(posedge clk);
            interrupt_done <= 1'b0;
        end
    end
    repeat (4) @(posedge clk);
end
endtask

task check(input [7:0] got, input [7:0] want, input [8*48-1:0] what);
begin
    if (got !== want) begin
        $display("FAIL: %0s: vector %02X, expected %02X", what, got, want);
        errors = errors + 1;
    end else
        $display("ok:   %0s: vector %02X", what, got);
end
endtask

reg [7:0] vec;

initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    repeat (4) @(posedge clk);

    // a warm boot: the old OS left the PICs set up, then the BIOS runs keyboard_init, and the
    // key release arrives before post_init_pic: the 8042 raises IRQ1 and holds it
    bios_init_pic;
    interrupt_input[1] <= 1'b1;            // the 8042's IRQ1, a byte in its output buffer
    repeat (10) @(posedge clk);
    // (masked or not, the old setup may take it; the BIOS runs with IF=0, so nobody does)
    bios_init_pic;
    take_irq(vec);
    check(vec, 8'h09, "IRQ1 high across the PIC setup");
    out_pic(0, 0, 8'h20);                  // EOI; the handler read port 60h:
    interrupt_input[1] <= 1'b0;            // the 8042 drops IRQ1

    // the next key: a new edge after the setup
    repeat (10) @(posedge clk);
    interrupt_input[1] <= 1'b1;
    take_irq(vec);
    check(vec, 8'h09, "IRQ1 rising after the setup");

    // a line that stays high is served once: after the EOI, no second interrupt
    out_pic(0, 0, 8'h20);
    take_irq(vec);
    check(vec, 8'hFF, "no repeat while IRQ1 stays high");
    interrupt_input[1] <= 1'b0;

    // the slave: the mouse's IRQ12 after the setup, then high across it, through the cascade
    interrupt_input[12] <= 1'b1;
    take_irq(vec);
    check(vec, 8'h74, "IRQ12 rising after the setup");
    out_pic(1, 0, 8'h20); out_pic(0, 0, 8'h20);
    interrupt_input[12] <= 1'b0;
    repeat (10) @(posedge clk);
    interrupt_input[12] <= 1'b1;
    repeat (10) @(posedge clk);
    bios_init_pic;
    take_irq(vec);
    check(vec, 8'h74, "IRQ12 high across the PIC setup");
    out_pic(1, 0, 8'h20); out_pic(0, 0, 8'h20);
    interrupt_input[12] <= 1'b0;

    if (errors == 0) $display("tb_pic: PASS");
    else             $display("tb_pic: FAIL (%0d)", errors);
    $finish;
end

endmodule
