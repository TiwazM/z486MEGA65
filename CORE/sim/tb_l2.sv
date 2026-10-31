// z486 for MEGA65
//
// Testbench: the L2 cache (CORE/sv/guest_l2.sv) between a model of z486's L1 (one request at
// a time: line fills of 4 words wrapping from the requested one, stores of 1/2/4 bytes, plain
// reads of 1..4 words) and a model of sdram.v's port 0 (accepts after 0..3 clocks, answers
// after 2..7, words in wrap order for a line read, a read ordered at its acceptance), with DMA
// writes into the same memory at random times (port 1, past the cache) and the cache switched
// off and on now and then. Every word the CPU gets is checked against the memory as it was in
// the clock its request was accepted. A 16-line cache over 4 KB: in the first half the
// addresses spread over all of it with many DMA writes (lines collide and leave all the time),
// in the second half they stay within 512 bytes with few DMA writes (mostly hits).
// CORE/sim/run_l2.sh runs it with Vivado's xsim.
//
// Licensed under GPL v3


module tb_l2;

localparam integer WORDS = 1024;                     // 4 KB of memory
localparam integer REQS  = 40000;

reg clk = 1'b0;
always #7.8125 clk = ~clk;                           // 64 MHz

reg         reset = 1'b1;
reg         enable = 1'b1;

reg         u_valid = 1'b0;
wire        u_ready;
reg         u_write = 1'b0;
reg  [31:0] u_addr = 32'd0;
reg  [31:0] u_din = 32'd0;
reg   [3:0] u_be = 4'd0;
reg   [7:0] u_burstcount = 8'd0;
reg         u_line_read = 1'b0;
wire [31:0] u_dout;
wire        u_resp_valid;

wire        d_valid;
reg         d_ready = 1'b0;
wire        d_write;
wire [31:0] d_addr;
wire [31:0] d_din;
wire  [3:0] d_be;
wire  [7:0] d_burstcount;
wire        d_line_read;
reg  [31:0] d_dout = 32'd0;
reg         d_resp_valid = 1'b0;

reg         dma_we = 1'b0;
reg  [31:0] dma_addr = 32'd0;
reg  [31:0] dma_data = 32'd0;
reg   [3:0] dma_be = 4'd0;

wire [31:0] hits, misses;

guest_l2 #(.IDX_BITS(4)) dut (
    .clk(clk), .reset(reset), .enable(enable),
    .u_valid(u_valid), .u_ready(u_ready), .u_write(u_write), .u_addr(u_addr), .u_din(u_din),
    .u_be(u_be), .u_burstcount(u_burstcount), .u_line_read(u_line_read), .u_dout(u_dout),
    .u_resp_valid(u_resp_valid),
    .d_valid(d_valid), .d_ready(d_ready), .d_write(d_write), .d_addr(d_addr), .d_din(d_din),
    .d_be(d_be), .d_burstcount(d_burstcount), .d_line_read(d_line_read), .d_dout(d_dout),
    .d_resp_valid(d_resp_valid),
    .dma_we(dma_we), .dma_addr(dma_addr),
    .hits(hits), .misses(misses)
);

// ---------------------------------------------------------------------------------------------
// The memory: what the SDRAM holds (written at the clock edge that ends the clock in which a
// write was accepted)
// ---------------------------------------------------------------------------------------------

reg [31:0] mem [0:WORDS-1];

function automatic [31:0] merge(input [31:0] old, input [31:0] nw, input [3:0] be);
    integer b;
    merge = old;
    for (b = 0; b < 4; b = b + 1)
        if (be[b]) merge[b*8 +: 8] = nw[b*8 +: 8];
endfunction

// the words of a request, in the order they come
function automatic [31:0] word_addr(input [31:0] a, input integer k, input line);
    if (line)
        word_addr = {a[31:4], a[3:2] + k[1:0], 2'b00};
    else
        word_addr = a + 4 * k;
endfunction

function automatic integer widx(input [31:0] a, input integer k, input line);
    reg [31:0] x;
    x = word_addr(a, k, line);
    widx = x[11:2];
endfunction

// ---------------------------------------------------------------------------------------------
// The SDRAM model's answers
// ---------------------------------------------------------------------------------------------

reg  [31:0] sd_q [0:15];
integer     sd_n = 0, sd_rd = 0, sd_wait = 0, sd_hold = 0;

// ---------------------------------------------------------------------------------------------
// The CPU model
// ---------------------------------------------------------------------------------------------

reg  [31:0] exp_q [0:3];
integer     exp_n = 0, got_n = 0;
integer     reqs = 0, errors = 0, words_checked = 0;
integer     cpu_state = 0;                           // 0 idle, 1 request out, 2 waiting for words
integer     cpu_gap = 0;
integer     i, k;
integer     n_fill = 0, n_store = 0, n_read = 0, n_dma = 0, n_toggle = 0;
integer     span;                                    // the CPU's addresses: 0 .. span - 1

initial begin
    for (i = 0; i < WORDS; i = i + 1)
        mem[i] = $random;
    repeat (4) @(posedge clk);
    reset <= 1'b0;
end

always @(posedge clk) if (!reset) begin
    // -- this clock's handshakes and words (the values of the clock that ends now) --------

    // the CPU's request accepted: what it must get, from the memory as it is now
    if (u_valid && u_ready) begin
        u_valid <= 1'b0;
        if (!u_write) begin
            for (k = 0; k < u_burstcount; k = k + 1)
                exp_q[k] = mem[widx(u_addr, k, u_line_read)];
            exp_n = u_burstcount;
            got_n = 0;
            cpu_state = 2;
        end else begin
            cpu_state = 0;
            cpu_gap = $urandom % 3;
        end
    end

    // a word to the CPU
    if (u_resp_valid) begin
        if (cpu_state != 2 || got_n >= exp_n) begin
            $display("FAIL  a word nobody asked for: %h", u_dout);
            errors = errors + 1;
        end else begin
            if (u_dout !== exp_q[got_n]) begin
                $display("FAIL  request %0d word %0d: %h, expected %h (state %0d)", reqs, got_n,
                         u_dout, exp_q[got_n], dut.state);
                errors = errors + 1;
            end
            words_checked = words_checked + 1;
            got_n = got_n + 1;
            if (got_n == exp_n) begin
                cpu_state = 0;
                cpu_gap = $urandom % 3;
            end
        end
    end

    // the SDRAM accepts: a read's words as the memory has them now; a store is applied
    if (d_valid && d_ready) begin
        if (d_write) begin
            mem[d_addr[11:2]] = merge(mem[d_addr[11:2]], d_din, d_be);
        end else begin
            for (k = 0; k < d_burstcount; k = k + 1)
                sd_q[k] = mem[widx(d_addr, k, d_line_read)];
            sd_n = d_burstcount;
            sd_rd = 0;
            sd_wait = 2 + $urandom % 6;
        end
    end

    // a DMA write accepted in this clock
    if (dma_we)
        mem[dma_addr[11:2]] = merge(mem[dma_addr[11:2]], dma_data, dma_be);

    // -- the next clock's inputs ----------------------------------------------------------

    // the SDRAM's answer words (now and then a gap)
    d_resp_valid <= 1'b0;
    if (sd_rd < sd_n) begin
        if (sd_wait > 0)
            sd_wait = sd_wait - 1;
        else if (($urandom % 8) != 0) begin
            d_resp_valid <= 1'b1;
            d_dout <= sd_q[sd_rd];
            sd_rd = sd_rd + 1;
        end
    end

    // the SDRAM's ready: after 0..3 clocks, never while it still answers
    d_ready <= 1'b0;
    if (d_valid && !(d_valid && d_ready) && sd_rd >= sd_n) begin
        if (sd_hold > 0)
            sd_hold = sd_hold - 1;
        else begin
            d_ready <= 1'b1;
            sd_hold = $urandom % 4;
        end
    end

    // DMA writes: about one in 12 clocks, into the same memory (one in 400 in the second half)
    dma_we <= 1'b0;
    if (($urandom % ((reqs < REQS / 2) ? 12 : 400)) == 0) begin
        dma_we   <= 1'b1;
        dma_addr <= {20'd0, $urandom % (WORDS * 4)} & 32'hFFF;
        dma_data <= $random;
        dma_be   <= (4'b0001 << ($urandom % 4));
        n_dma = n_dma + 1;
    end

    // the cache switched off and on now and then (seldom in the second half)
    if (($urandom % ((reqs < REQS / 2) ? 3000 : 60000)) == 0) begin
        enable <= ~enable;
        n_toggle = n_toggle + 1;
    end

    // the CPU's next request
    span = (reqs < REQS / 2) ? WORDS * 4 : 512;
    if (cpu_state == 0 && !(u_valid && u_ready)) begin
        if (cpu_gap > 0)
            cpu_gap = cpu_gap - 1;
        else if (reqs < REQS) begin
            reqs = reqs + 1;
            u_valid <= 1'b1;
            cpu_state = 1;
            k = $urandom % 10;
            if (k < 5) begin                               // a line fill
                u_write      <= 1'b0;
                u_line_read  <= 1'b1;
                u_burstcount <= 8'd4;
                u_addr       <= ($urandom % span) & 32'hFFC;
                u_be         <= 4'hF;
                n_fill = n_fill + 1;
            end else if (k < 8) begin                      // a store
                u_write      <= 1'b1;
                u_line_read  <= 1'b0;
                u_burstcount <= 8'd1;
                u_addr       <= ($urandom % span) & 32'hFFC;
                u_din        <= $random;
                case ($urandom % 4)
                    0: u_be <= 4'b0001 << ($urandom % 4);
                    1: u_be <= ($urandom % 2) ? 4'b0011 : 4'b1100;
                    default: u_be <= 4'b1111;
                endcase
                n_store = n_store + 1;
            end else begin                                 // a plain read
                u_write      <= 1'b0;
                u_line_read  <= 1'b0;
                u_burstcount <= 8'd1 + ($urandom % 4);
                u_addr       <= ($urandom % (span - 16)) & 32'hFFC;
                u_be         <= 4'hF;
                n_read = n_read + 1;
            end
        end else if (reqs == REQS) begin
            reqs = reqs + 1;
            $display("%0d requests (%0d line fills, %0d stores, %0d reads), %0d DMA writes, %0d switches",
                     REQS, n_fill, n_store, n_read, n_dma, n_toggle);
            $display("%0d words checked; line fills from the cache %0d, from the SDRAM %0d",
                     words_checked, hits, misses);
            if (errors == 0 && hits > 0 && misses > 0)
                $display("PASS: all checks");
            else
                $display("FAILED: %0d errors", errors);
            $finish;
        end
    end
end

// a request that never finishes
initial begin
    #50ms;
    $display("FAILED: timeout at request %0d (cpu %0d, l2 state %0d)", reqs, cpu_state, dut.state);
    $finish;
end

endmodule
