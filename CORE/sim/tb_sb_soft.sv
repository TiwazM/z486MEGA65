// CORE/sv/sb_soft.sv, the Sound Blaster DSP's output stage, on clk_audio (24.576 MHz):
//   1. a continuous stream (44.1 kHz, DOOM's way): out = in, sample for sample
//   2. back-to-back effects with 10 ms gaps: out = in throughout, the gaps included
//   3. a sharp attack (0 to full scale in one sample, a shotgun's): out = in
//   4. a pause and a resume of the same stream after 10 ms: out = in
//   5. a sound that stops on +20000 (held): out = in for 20 ms, then glides to 0, no step
//      over 1/1000 of full scale per 48 kHz tick, 0 within 250 ms
//   6. the DSP mutes from -20000 (in drops to 0 at once): out glides to 0, no step over
//      1/200 of full scale, 0 within 60 ms
//   7. the stage off: out = in, through a stop and a mute
// Run: iverilog -g2012 -o tb CORE/sv/sb_soft.sv CORE/sim/tb_sb_soft.sv && vvp tb
// (CORE/sim/run_sb_soft.sh)

`timescale 1ns / 1ps

module tb_sb_soft;

reg         clk = 1'b0;
reg         on = 1'b1;
reg  [15:0] in_l = 16'd0, in_r = 16'd0;
reg         newt = 1'b0;
reg         mute = 1'b0;
wire [15:0] out_l, out_r;

always #20.345 clk = ~clk;                 // 24.576 MHz

sb_soft dut (
    .clk(clk), .on(on), .in_l(in_l), .in_r(in_r), .newt(newt), .mute(mute),
    .out_l(out_l), .out_r(out_r)
);

integer errors = 0;
integer mism   = 0;                         // samples where out differed from in (exact cases)
integer maxstep = 0;                        // the largest change of out per clock (fades)
reg  [15:0] last_out;
reg         exact = 1'b0;                   // out must follow in

// out follows in one clock later
reg [15:0] in_d;
always @(posedge clk) begin
    in_d <= in_l;
    if (exact && out_l !== in_d) mism = mism + 1;
    if ($signed(out_l) - $signed(last_out) > maxstep)  maxstep = $signed(out_l) - $signed(last_out);
    if ($signed(last_out) - $signed(out_l) > maxstep)  maxstep = $signed(last_out) - $signed(out_l);
    last_out <= out_l;
end

task automatic check(input bit ok, input string what);
    if (ok) $display("ok    %s", what);
    else begin $display("FAIL  %s", what); errors = errors + 1; end
endtask

// one DSP output sample, then wait a sample period (44.1 kHz: 557 clocks)
task automatic sample(input [15:0] v);
    @(negedge clk);
    in_l = v; in_r = v; newt = ~newt;
    repeat (557) @(posedge clk);
endtask

task automatic wait_ms(input integer ms);
    repeat (ms * 24576) @(posedge clk);
endtask

integer i;
real    ph;

initial begin
    last_out = 16'd0;
    repeat (10) @(posedge clk);

    // 1. a continuous stream: a 440 Hz sine at 0.8 of full scale, 0.5 s
    exact = 1; mism = 0;
    for (i = 0; i < 22050; i = i + 1) begin
        ph = 2.0 * 3.14159265 * 440.0 * i / 44100.0;
        sample($rtoi(26000.0 * $sin(ph)));
    end
    check(mism == 0, $sformatf("1. a continuous stream: out = in (%0d samples differed)", mism));

    // 2. back-to-back effects: 30 ms bursts of noise-like samples, 10 ms gaps (held level)
    mism = 0;
    repeat (5) begin
        for (i = 0; i < 1323; i = i + 1) sample($urandom_range(0, 65535));
        wait_ms(10);
    end
    check(mism == 0, $sformatf("2. effects with 10 ms gaps: out = in (%0d differed)", mism));

    // 3. a sharp attack: silence, then full scale at once, decaying
    mism = 0;
    for (i = 0; i < 100; i = i + 1) sample(16'd0);
    for (i = 0; i < 2000; i = i + 1) sample(((i & 1) ? -1 : 1) * (32767 - 16 * i));
    check(mism == 0, $sformatf("3. a sharp attack: out = in (%0d differed)", mism));

    // 4. a pause of 10 ms in a stream, then the same stream on
    mism = 0;
    for (i = 0; i < 2000; i = i + 1) sample($rtoi(20000.0 * $sin(2.0 * 3.14159265 * 300.0 * i / 44100.0)));
    wait_ms(10);
    for (i = 2000; i < 4000; i = i + 1) sample($rtoi(20000.0 * $sin(2.0 * 3.14159265 * 300.0 * i / 44100.0)));
    check(mism == 0, $sformatf("4. a 10 ms pause and the stream again: out = in (%0d differed)", mism));
    exact = 0;

    // 5. a sound that stops on +20000: held
    sample(16'd20000);
    repeat (24576 * 19) @(posedge clk);
    check(out_l == 16'd20000, $sformatf("5. stopped on +20000: still %0d after 19 ms", $signed(out_l)));
    maxstep = 0;
    wait_ms(250);
    check(out_l == 16'd0, $sformatf("   0 within 250 ms (%0d)", $signed(out_l)));
    check(maxstep <= 33, $sformatf("   no step over 1/1000 of full scale (largest %0d)", maxstep));

    // 6. the DSP mutes from -20000: in drops to 0 at once
    for (i = 0; i < 100; i = i + 1) sample(-16'sd20000);
    maxstep = 0;
    @(negedge clk) mute = 1; in_l = 16'd0; in_r = 16'd0;
    wait_ms(60);
    check(out_l == 16'd0, $sformatf("6. a mute from -20000: 0 within 60 ms (%0d)", $signed(out_l)));
    check(maxstep <= 164, $sformatf("   no step over 1/200 of full scale (largest %0d)", maxstep));
    @(negedge clk) mute = 0;

    // 7. the stage off: a stop and a mute pass as they are
    on = 0; exact = 1; mism = 0;
    for (i = 0; i < 200; i = i + 1) sample(16'd15000);
    wait_ms(40);
    @(negedge clk) mute = 1; in_l = 16'd0; in_r = 16'd0;
    wait_ms(5);
    @(negedge clk) mute = 0;
    check(mism == 0 && out_l == 16'd0, $sformatf("7. the stage off: out = in through a stop and a mute (%0d differed)", mism));

    if (errors == 0) $display("PASS: all checks");
    else             $display("FAILED: %0d checks", errors);
    $finish;
end

endmodule
