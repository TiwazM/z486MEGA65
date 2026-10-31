// z486 for MEGA65: a second-level cache between the PC's memory port and the SDRAM.
//
// Between system.sv's ext_mem0 (the CPU's L1 line fills, its write-through stores and its
// uncached reads, through main_memory.sv) and the SDRAM controller's port 0. After MegaMac's
// ap040_l2.v: direct-mapped, 2^IDX_BITS lines of 16 bytes (14: 256 KB, as on many 486 boards)
// in block RAM, tagged by the physical address, write-through without write-allocate.
//
//   * A line fill (line_read: 4 words from the requested one, wrapping, as sdram.v answers
//     it) looks the line up: a hit is ready three clocks after the request and answers a word
//     a clock from the fifth (the decision and the words leave registers: the L1 sits in the
//     CPU's pblock); a miss goes to the SDRAM, and its four words are kept on their way to the
//     CPU.
//   * A store goes to the SDRAM as before and updates the line's bytes when the line is here,
//     so the SDRAM stays the truth. Uncached reads (bursts that are no line) pass through.
//   * DMA writes go to the SDRAM's port 1, past the cache: each one drops its line (by the
//     index alone, which may drop another line of the same index). They wait in a 4-entry
//     queue for the next idle clock, before any lookup; a line fill whose line has one waiting
//     is a miss; a full queue sweeps the whole cache.
//   * One request at a time: z486's L1 waits for every answer, so a hit never overtakes a
//     miss. The cache takes the next request when the last word of the previous one is out.
//   * Every write to the RAMs happens in the clock of the state that makes it (MegaMac's L2
//     once let a lookup read a line in the clock its store was still on the way): a lookup
//     after a store or a fill reads the new bytes.
//   * enable = 0, and while the tags are swept (at reset, at every 0 -> 1 of enable): every
//     request passes through, nothing is looked up or kept.
//
// hits / misses count the line fills.
//
// Licensed under GPL v3

module guest_l2 #(
    parameter IDX_BITS = 14                  // log2 of the lines: 14 = 256 KB
) (
    input             clk,
    input             reset,
    input             enable,

    // the CPU side (system.sv's ext_mem0)
    input             u_valid,
    output            u_ready,
    input             u_write,
    input      [31:0] u_addr,
    input      [31:0] u_din,
    input       [3:0] u_be,
    input       [7:0] u_burstcount,
    input             u_line_read,
    output     [31:0] u_dout,
    output            u_resp_valid,

    // the SDRAM side (sdram.v's port 0)
    output            d_valid,
    input             d_ready,
    output            d_write,
    output     [31:0] d_addr,
    output     [31:0] d_din,
    output      [3:0] d_be,
    output      [7:0] d_burstcount,
    output            d_line_read,
    input      [31:0] d_dout,
    input             d_resp_valid,

    // a DMA write into the RAM, accepted by port 1 this clock
    input             dma_we,
    input      [31:0] dma_addr,

    output reg [31:0] hits,
    output reg [31:0] misses
);

localparam integer LINES    = 1 << IDX_BITS;
localparam integer TAG_BITS = 23 - IDX_BITS;          // physical addresses of 27 bits (128 MB)

function automatic [IDX_BITS-1:0] idx_of(input [31:0] a);
    idx_of = a[IDX_BITS+3:4];
endfunction

function automatic [TAG_BITS-1:0] tag_of(input [31:0] a);
    tag_of = a[26:IDX_BITS+4];
endfunction

localparam [3:0] S_IDLE  = 4'd0,
                 S_LOOK  = 4'd1,      // a line fill: the tag and the line are being read
                 S_HITR  = 4'd2,      // a hit: ready
                 S_HIT   = 4'd3,      // its four words
                 S_FREQ  = 4'd4,      // a miss: the request to the SDRAM
                 S_FILL  = 4'd5,      // its words, kept on their way
                 S_ALLOC = 4'd6,      // the line into the cache
                 S_WLOOK = 4'd7,      // a store went: update the line if it is here
                 S_PASS  = 4'd8;      // a request that passes: its words

reg           [3:0] state;
reg          [31:0] hit_word;                         // a hit's word to the CPU, a clock later
reg                 hit_valid;
reg          [31:0] c_addr;
reg          [31:0] c_din;
reg           [3:0] c_be;
reg           [7:0] c_left;                           // words still to come (S_PASS)
reg           [1:0] c_k;                              // words answered (S_HIT) or taken (S_FILL)
reg          [31:0] fill_buf [0:3];

reg                 sweeping;
reg  [IDX_BITS-1:0] sweep_idx;
reg                 enable_r;
wire                cache_on = enable_r && !sweeping;

// ---------------------------------------------------------------------------------------------
// The DMA writes' queue of lines to drop
// ---------------------------------------------------------------------------------------------

reg  [IDX_BITS-1:0] dq [0:3];
reg           [3:0] dq_v;
wire                dq_any  = |dq_v;
wire                dq_full = &dq_v;
wire          [1:0] dq_pick = dq_v[0] ? 2'd0 : dq_v[1] ? 2'd1 : dq_v[2] ? 2'd2 : 2'd3;
wire          [1:0] dq_free = !dq_v[0] ? 2'd0 : !dq_v[1] ? 2'd1 : !dq_v[2] ? 2'd2 : 2'd3;
wire                dq_go   = (state == S_IDLE) && cache_on && dq_any;

// ---------------------------------------------------------------------------------------------
// The RAMs: a tag (bit TAG_BITS = valid) and four words per line, read a clock after the
// address; written in the clock of the state that writes
// ---------------------------------------------------------------------------------------------

reg  [IDX_BITS-1:0] rd_idx;
reg    [TAG_BITS:0] tag_q;
wire                tag_hit = tag_q[TAG_BITS] && tag_q[TAG_BITS-1:0] == tag_of(c_addr);

wire                tag_we   = sweeping || dq_go || (state == S_ALLOC && cache_on);
wire [IDX_BITS-1:0] tag_widx = sweeping ? sweep_idx : dq_go ? dq[dq_pick] : idx_of(c_addr);
wire   [TAG_BITS:0] tag_wd   = (state == S_ALLOC && !sweeping && !dq_go) ? {1'b1, tag_of(c_addr)}
                                                                         : {(TAG_BITS+1){1'b0}};

wire                alloc_we = (state == S_ALLOC) && cache_on;
wire                store_we = (state == S_WLOOK) && cache_on && tag_hit;
wire          [3:0] data_we  = alloc_we ? 4'b1111 : store_we ? (4'b0001 << c_addr[3:2]) : 4'b0000;
wire          [3:0] data_be  = alloc_we ? 4'b1111 : c_be;

(* ram_style = "block" *) reg [TAG_BITS:0] tag_ram [0:LINES-1];

always @(posedge clk) begin
    if (tag_we)
        tag_ram[tag_widx] <= tag_wd;
    tag_q <= tag_ram[rd_idx];
end

wire [31:0] data_q [0:3];

genvar w;
generate
    for (w = 0; w < 4; w = w + 1) begin : g_word
        (* ram_style = "block" *) reg [31:0] ram [0:LINES-1];
        reg  [31:0] q;
        wire [31:0] wd = alloc_we ? fill_buf[w] : c_din;
        integer b;
        always @(posedge clk) begin
            for (b = 0; b < 4; b = b + 1)
                if (data_we[w] && data_be[b])
                    ram[idx_of(c_addr)][b*8 +: 8] <= wd[b*8 +: 8];
            q <= ram[rd_idx];
        end
        assign data_q[w] = q;
    end
endgenerate

// ---------------------------------------------------------------------------------------------
// The requests
// ---------------------------------------------------------------------------------------------

wire u_fill = u_line_read && !u_write;

// The request goes to the SDRAM as the CPU presents it (it holds it until ready): from idle
// for everything but a line fill with the cache on, and for a miss
wire fwd_idle = (state == S_IDLE) && u_valid && !dq_go && !(cache_on && u_fill);
assign d_valid      = fwd_idle || (state == S_FREQ);
assign d_write      = u_write;
assign d_addr       = u_addr;
assign d_din        = u_din;
assign d_be         = u_be;
assign d_burstcount = u_burstcount;
assign d_line_read  = u_line_read;

// A hit: the tag matches and no DMA write of the line waits or arrives now
wire look_dma = (dq_v[0] && dq[0] == idx_of(c_addr)) || (dq_v[1] && dq[1] == idx_of(c_addr)) ||
                (dq_v[2] && dq[2] == idx_of(c_addr)) || (dq_v[3] && dq[3] == idx_of(c_addr)) ||
                (dma_we && idx_of(dma_addr) == idx_of(c_addr));
wire look_hit = cache_on && tag_hit && !look_dma;

assign u_ready      = (d_valid && d_ready) || (state == S_HITR);
assign u_resp_valid = hit_valid || ((state == S_FILL || state == S_PASS) && d_resp_valid);
assign u_dout       = hit_valid ? hit_word : d_dout;

always @(*)
    rd_idx = (state == S_IDLE) ? idx_of(u_addr) : idx_of(c_addr);

always @(posedge clk) begin
    case (state)
        S_IDLE:
            if (!dq_go && u_valid) begin
                c_addr <= u_addr;
                c_din  <= u_din;
                c_be   <= u_be;
                c_left <= u_burstcount;
                c_k    <= 2'd0;
                if (cache_on && u_fill)
                    state <= S_LOOK;
                else if (d_ready)
                    state <= u_write ? (cache_on ? S_WLOOK : S_IDLE) : S_PASS;
            end

        S_LOOK:
            if (look_hit) begin
                hits  <= hits + 1'd1;
                state <= S_HITR;
            end else begin
                misses <= misses + 1'd1;
                state  <= S_FREQ;
            end

        S_HITR:
            state <= S_HIT;

        S_HIT: begin
            c_k <= c_k + 1'd1;
            if (c_k == 2'd3)
                state <= S_IDLE;
        end

        S_FREQ:
            if (d_ready)
                state <= S_FILL;

        S_FILL:
            if (d_resp_valid) begin
                fill_buf[c_addr[3:2] + c_k] <= d_dout;
                c_k <= c_k + 1'd1;
                if (c_k == 2'd3)
                    state <= S_ALLOC;
            end

        S_ALLOC:                       // (alloc_we writes the line in this clock)
            state <= S_IDLE;

        S_WLOOK:                       // (store_we updates the line in this clock)
            state <= S_IDLE;

        S_PASS:
            if (d_resp_valid) begin
                c_left <= c_left - 1'd1;
                if (c_left <= 8'd1)
                    state <= S_IDLE;
            end
    endcase

    // A hit's words, a clock behind S_HIT (the last one is out in the next request's first
    // clock, long before that request's own first word)
    hit_valid <= (state == S_HIT);
    hit_word  <= data_q[c_addr[3:2] + c_k];

    // The DMA queue: the entry that leaves, the one that comes (into a slot free before this
    // clock, never the one leaving); a full queue sweeps everything
    if (dq_go)
        dq_v[dq_pick] <= 1'b0;
    if (dma_we && cache_on) begin
        if (dq_full) begin
            sweeping  <= 1'b1;
            sweep_idx <= {IDX_BITS{1'b0}};
        end else begin
            dq[dq_free]   <= idx_of(dma_addr);
            dq_v[dq_free] <= 1'b1;
        end
    end

    // The sweep
    enable_r <= enable;
    if (enable && !enable_r) begin
        sweeping  <= 1'b1;
        sweep_idx <= {IDX_BITS{1'b0}};
    end
    if (sweeping) begin
        sweep_idx <= sweep_idx + 1'd1;
        dq_v      <= 4'b0000;
        if (&sweep_idx)
            sweeping <= 1'b0;
    end

    if (reset) begin
        state     <= S_IDLE;
        hit_valid <= 1'b0;
        sweeping  <= 1'b1;
        sweep_idx <= {IDX_BITS{1'b0}};
        enable_r  <= 1'b0;
        dq_v      <= 4'b0000;
        hits      <= 32'd0;
        misses    <= 32'd0;
    end
end

endmodule
