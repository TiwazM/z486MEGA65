// The Sound Blaster DSP's output stage (MEGA65; z486_mega65.sv, on clk_audio, 24.576 MHz).
// z486's DSP (sound_dsp.v) holds its last sample when it stops (a DMA pause, the end of a
// transfer) and drops to 0 when it mutes (speaker off in SB Pro mode, the 80h silence): a level
// a sound ends on stays until the next sound jumps away from it, and a mute steps from it;
// either jump goes out as a pop (King's Quest VI's speech, the end of a WAV in an editor). A
// real card's output capacitors let such a level drift off. Here:
//   * while the DSP outputs samples (newt toggles), they pass as they are: DOOM's stream, and
//     back-to-back effects with gaps under 20 ms, are untouched;
//   * no new sample for 20 ms (stopped or paused): the level glides to 0, ~21 ms time constant,
//     so the next sound starts from 0 (a stream resumed after that starts from 0 too, as a real
//     card's would once its capacitors have let go);
//   * mute (the DSP holds its output at 0): from the level it had, to 0 in ~2.7 ms time constant.
// on = 0: in to out as they are. Fades go per 48 kHz tick (clk / 512), exponentially, the last
// LSBs one per tick. CORE/sim/tb_sb_soft.sv.

`default_nettype none

module sb_soft #(
    parameter integer IDLE_TICKS = 960,   // 20 ms of 48 kHz ticks
    parameter integer IDLE_SHIFT = 10,    // the stopped level's time constant: 2^10 ticks, 21 ms
    parameter integer MUTE_SHIFT = 7      // a mute's: 2^7 ticks, 2.7 ms
) (
    input  wire        clk,
    input  wire        on,
    input  wire [15:0] in_l,               // signed samples, the DSP's (sample_sb_l/r)
    input  wire [15:0] in_r,
    input  wire        newt,               // toggles with each sample the DSP outputs
    input  wire        mute,               // the DSP holds its output at 0
    output reg  [15:0] out_l,              // out = in one clock later while the DSP plays
    output reg  [15:0] out_r
);

function automatic [15:0] fade(input [15:0] x, input integer k);
    reg signed [15:0] xs, d;
    begin
        xs = x;
        d  = xs >>> k;
        if (d == 16'sd0 && xs > 16'sd0) d = 16'sd1;    // positive: no stalling short of 0
        fade = xs - d;                                  // negative: >>> gives -1, 0 is reached
    end
endfunction

reg  [8:0] div  = 9'd0;
reg        newt_d = 1'b0;
reg  [9:0] idle = 10'd0;
wire       tick = div == 9'd511;

always @(posedge clk) begin
    div    <= div + 1'd1;
    newt_d <= newt;
    if (newt != newt_d)                    idle <= 10'd0;
    else if (tick && idle != IDLE_TICKS)   idle <= idle + 1'd1;
    if (!on || (!mute && idle != IDLE_TICKS)) begin
        out_l <= in_l;                     // playing (or the stage off): as they are
        out_r <= in_r;
    end else if (tick) begin
        out_l <= fade(out_l, mute ? MUTE_SHIFT : IDLE_SHIFT);
        out_r <= fade(out_r, mute ? MUTE_SHIFT : IDLE_SHIFT);
    end
end

endmodule

`default_nettype wire
