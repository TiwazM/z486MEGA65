// tb_i8042_aux: Linux's mouse port probe (drivers/input/serio/i8042.c, i8042_check_aux) against
// z486's 8042 (ps2.v as patched by tools/z486_sources.py). Linux loops 5Ah back with D3 while the
// mouse port is still off (command byte bit 5); then it checks that A7/A8 switch the port, and
// that IRQ12 brings back A5h, looped with the port on. When the D3 byte waited in the mouse's
// FIFO like a mouse's bytes do while the port is off, the A8 check read it as the command byte,
// the IRQ12 test timed out behind the real one, and Linux took the port for absent (TinyCore's
// X without a pointer, 2026-11-14). Twice: with the mouse's FIFO empty, and with a packet's
// bytes waiting in it (sent with the port on, then the port off).
// Run by CORE/sim/run_ps2.sh (tb_i8042_aux).
`timescale 1ns / 1ps

module tb_i8042_aux;

reg         clk = 1'b0;
reg         rst_n = 1'b0;
always #5 clk = ~clk;

reg   [3:0] addr = 4'd0;
reg         rd = 1'b0, wr = 1'b0;
reg   [7:0] wd = 8'h00;
wire  [7:0] rdata;
wire        irq_k, irq_m;
wire        kco, kdo, mco, mdo;
reg         dev_clk = 1'b1, dev_dat = 1'b1;     // the mouse's side of its lines (wired AND)

integer     errors = 0;

ps2 dut (
    .clk(clk), .rst_n(rst_n), .irq_keyb(irq_k), .irq_mouse(irq_m),
    .io_address(addr), .io_read(rd), .io_readdata(rdata), .io_write(wr), .io_writedata(wd),
    .io_cs(1'b1), .ctl_cs(1'b0), .output_a20_enable(), .output_reset_n(), .a20_enable(),
    .ps2_kbclk(kco), .ps2_kbdat(kdo), .ps2_kbclk_out(kco), .ps2_kbdat_out(kdo),
    .ps2_mouseclk(mco & dev_clk), .ps2_mousedat(mdo & dev_dat),
    .ps2_mouseclk_out(mco), .ps2_mousedat_out(mdo),
    .dbg_state(), .dbg_fifo());

task automatic outb(input [3:0] a, input [7:0] v);
    @(negedge clk); addr = a; wd = v; wr = 1'b1;
    @(negedge clk); wr = 1'b0;
    repeat (20) @(negedge clk);
endtask

task automatic inb(input [3:0] a, output [7:0] v);
    @(negedge clk); addr = a; rd = 1'b1;
    @(negedge clk); rd = 1'b0; v = rdata;
    repeat (20) @(negedge clk);
endtask

// The mouse sends a byte: start bit, 8 data bits, odd parity, stop bit (12.5 kHz)
task automatic dev_send(input [7:0] b);
    reg [10:0] f;
    f = {1'b1, ~^b, b, 1'b0};
    for (int i = 0; i < 11; i++) begin
        dev_dat = f[i]; #20000; dev_clk = 1'b0; #40000; dev_clk = 1'b1; #20000;
    end
    dev_dat = 1'b1; #100000;
endtask

reg [7:0] st, d;

// i8042_wait_write / i8042_wait_read
task automatic wait_write(output bit err);
    err = 1;
    for (int n = 0; n < 5000 && err; n++) begin inb(4, st); if (!st[1]) err = 0; end
endtask
task automatic wait_read(output bit err);
    err = 1;
    for (int n = 0; n < 5000 && err; n++) begin inb(4, st); if (st[0]) err = 0; end
endtask

// i8042_command: a command, np parameter bytes (p), nr reply bytes (r); loop: AUX_LOOP, whose
// reply must come with the status's mouse bit (I8042_STR_AUXDATA)
task automatic command(input [7:0] cmd, input int np, input [7:0] p, input int nr, input bit loop,
                       output [7:0] r, output bit err);
    r = p;
    wait_write(err);
    if (!err) outb(4, cmd);
    if (!err && np) begin wait_write(err); if (!err) outb(0, p); end
    if (!err && nr) begin
        wait_read(err);
        if (err)                 $display("      %02x: timeout", cmd);
        else if (loop && !st[5]) begin $display("      %02x: not the mouse's (status %02x)", cmd, st); err = 1; end
        else begin inb(0, r); $display("      %02x -> %02x (status %02x)", cmd, r, st); end
    end
endtask

task automatic flush;
    inb(4, st);
    while (st[0]) begin inb(0, d); inb(4, st); end
endtask

// i8042_check_aux, as Linux 6.x runs it
task automatic check_aux(input string what);
    reg [7:0] param, ctr;
    bit err, err2, broken, irq_ok;
    $display("%s:", what);
    flush;
    command(8'hD3, 1, 8'h5A, 1, 1, param, err);              // AUX_LOOP 5Ah, the port off
    broken = 0;
    if (err || param != 8'h5A) begin
        $error("D3 5Ah did not come back as the mouse's byte"); errors++;
        command(8'hA9, 0, 0, 1, 0, param, err2);            // AUX_TEST (Linux's fallback)
        if (!err) broken = 1;
    end
    command(8'hA7, 0, 0, 0, 0, param, err);                 // AUX_DISABLE
    command(8'h20, 0, 0, 1, 0, ctr, err);
    if (err || !ctr[5]) begin $error("A7: command byte %02x, the port not off", ctr); errors++; end
    command(8'hA8, 0, 0, 0, 0, param, err);                 // AUX_ENABLE
    command(8'h20, 0, 0, 1, 0, ctr, err);
    if (err || ctr[5]) begin $error("A8: command byte %02x, the port not on", ctr); errors++; end
    if (!broken) begin
        ctr = (ctr & ~8'h20) | 8'h02;                       // i8042_enable_aux_port
        command(8'h60, 1, ctr, 0, 0, param, err);
        command(8'hD3, 1, 8'hA5, 0, 0, param, err);         // the IRQ12 test
        irq_ok = 0;
        for (int t = 0; t < 20000 && !irq_ok; t++) begin
            @(negedge clk);
            if (irq_m) begin
                inb(4, st);
                if (st[0]) begin
                    inb(0, d);
                    $display("      IRQ12: %02x (%s)", d, st[5] ? "mouse" : "keyboard");
                    if (d == 8'hA5 && st[5]) irq_ok = 1;
                end
            end
        end
        if (!irq_ok) begin $error("no IRQ12 with A5h"); errors++; end
    end
    flush;
    if (errors == 0) $display("ok    %s: Linux finds the mouse port", what);
endtask

reg [7:0] p;
bit e;
initial begin
    repeat (10) @(negedge clk); rst_n = 1'b1; repeat (10) @(negedge clk);
    // the BIOS: self test, command byte 74h (the mouse port off, no IRQs)
    command(8'hAA, 0, 0, 1, 0, p, e);
    command(8'h60, 1, 8'h74, 0, 0, p, e);
    check_aux("the mouse's FIFO empty");

    // a packet with the port on, then the port off: the bytes not read wait in the FIFO
    command(8'h60, 1, 8'h54, 0, 0, p, e);
    #300000;
    dev_send(8'h08); dev_send(8'h01); dev_send(8'h02);
    command(8'h60, 1, 8'h74, 0, 0, p, e);
    flush;
    $display("      bytes waiting in the mouse's FIFO with the port off: %0d", dut.mouse_fifo_counter);
    if (dut.mouse_fifo_counter == 0) begin $error("no bytes waiting: the case is not tested"); errors++; end
    check_aux("a packet's bytes waiting");

    if (errors == 0) $display("PASS: all checks");
    else             $display("FAILED: %0d checks", errors);
    $finish;
end

endmodule
