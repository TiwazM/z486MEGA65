//
// z486 for MEGA65: the NE2000's network side, in hardware. ne2000_core.v (georgemog's ao486
// port of apolkosnik's Minimig NE2000) talks to a 64 KB "mailbox" through its eth_dma_* port;
// on MiSTer that window is in DDR and a Linux service (ne2000d, Main_MiSTer) bridges it to the
// DE10-Nano's eth0. The MEGA65 has no ARM, but the FPGA owns the PHY: this module is the
// service, answering the card's mailbox transfers from block RAM and moving the frames to and
// from eth_mac.vhd (Megamiga's RMII MAC) on the 50 MHz RMII clock.
//
// The mailbox as the card uses it (byte offsets; a 16-bit transfer carries byte 2k in [15:8]
// and byte 2k+1 in [7:0]; numbers are little-endian there, frames in wire order; a wide
// transfer is four such words, lane L = bits [16L+15:16L] = bytes 8n+2L, 8n+2L+1):
//   1000      flags: the host's byte (RX_AVAIL 04h = frames queued), the card's byte (1001)
//   104C-1051 the station address (read at every card reset; read-only here: the card later
//             writes its register mirror over it, and a soft reset must find the real one)
//   1088      heartbeat (u32, never 0)     108C  signature CAFEBABEh: the card sends only
//             while both say a host is there, else a transmit ends with TXE
//   2C04      RX head (the card's: written when it has taken a slot)
//   2C06      RX tail (the host's: the next slot it fills)
//   2C08      TX request sequence (written after a frame: send slot seq mod 8)
//   2C20+2s   RX slot lengths (16)          2C40+2s  TX slot lengths (8)
//   3000      TX slots, 8 x 600h            9000     RX slots, 16 x 600h
// Everything else is acknowledged: writes dropped, reads 0 (the card's register mirror and
// diagnostics, 1004-1081 and 1100-111D, are for MiSTer's tools).
//
// RX: 4 physical slots of 2 KB (logical slot s in (s + base) mod 4, so at most 4 frames wait;
// the card drains one in a few microseconds). A frame is offered a free slot before it arrives; the
// writer (clk50) takes frames to the card's address or broadcast, FCS good, 64..1518 bytes
// with the FCS (stored without it), and drops the rest - as ne2000d does: the card filters
// nothing. TX: all 8 slots (the card never waits for a frame to be sent; a write into a slot
// still waiting holds the transfer instead). A read of the station address means the card is
// starting up (reset): the RX queue is emptied, so no old frames are delivered again; the slot
// on offer then becomes the new first one (base), so the next frame isn't lost.
//
// Between the clocks: request/acknowledge toggles (never reset: a reset on one side can't
// make them disagree) with their values held steady while they cross (CORE.xdc bounds those
// paths, as for Megamiga's eth_card.vhd).
//
`default_nettype none

module ne2k_host #(
    parameter int CLK_HZ = 64_000_000
) (
    input  wire        clk,
    input  wire        reset,              // clk: the card's reset (or the card switched off)
    input  wire        enable,             // the card is on: frames are received
    input  wire [47:0] mac,                // the station address, [47:40] first on the wire

    // ne2000_core.v's mailbox port (clk): req held until a one-clock ready, read data with it
    input  wire        dma_req,
    input  wire        dma_write,
    input  wire [15:1] dma_addr,
    input  wire [15:0] dma_wdata,
    input  wire        dma_wide,
    input  wire [63:0] dma_wdata64,
    input  wire        dma_uds,            // active low: byte 2k ([15:8])
    input  wire        dma_lds,            // active low: byte 2k+1 ([7:0])
    output reg         dma_ready = 1'b0,
    output reg  [15:0] dma_rdata = 16'h0000,
    output reg  [63:0] dma_rdata64 = 64'h0,

    // eth_mac.vhd (clk50)
    input  wire        clk50,
    input  wire        rst50,
    input  wire        rx_start,
    input  wire        rx_valid,
    input  wire  [7:0] rx_byte,
    input  wire        rx_end,
    input  wire        rx_ok,
    output reg         tx_start = 1'b0,
    output reg  [10:0] tx_len = 11'd0,
    input  wire [10:0] tx_addr,
    output wire  [7:0] tx_data,
    input  wire        tx_busy
);

// ---------------------------------------------------------------------------------------------
// The buffers: even and odd bytes in their own RAMs (a 16-bit word is one entry of each)
// ---------------------------------------------------------------------------------------------

// TX: 3000-5FFF of the window (12 KB; 16 KB of RAM: eth_mac reads a byte ahead), written by
// the card (clk), read by eth_mac (clk50)
reg  [7:0] tx_even [0:8191];
reg  [7:0] tx_odd  [0:8191];
reg        txm_we_e, txm_we_o;
reg [12:0] txm_waddr;
reg  [7:0] txm_wd_e, txm_wd_o;

always @(posedge clk) begin
    if (txm_we_e) tx_even[txm_waddr] <= txm_wd_e;
    if (txm_we_o) tx_odd[txm_waddr]  <= txm_wd_o;
end

reg [13:0] tx_raddr;
reg  [7:0] tx_q_e, tx_q_o;
reg        tx_q_sel;
always @(posedge clk50) begin
    tx_q_e   <= tx_even[tx_raddr[13:1]];
    tx_q_o   <= tx_odd[tx_raddr[13:1]];
    tx_q_sel <= tx_raddr[0];
end
assign tx_data = tx_q_sel ? tx_q_o : tx_q_e;

// RX: 4 slots x 2 KB, written by the frame writer (clk50), read by the card (clk)
reg  [7:0] rx_even [0:4095];
reg  [7:0] rx_odd  [0:4095];
reg        rxw_we;
reg [12:0] rxw_addr;
reg  [7:0] rxw_d;
always @(posedge clk50) begin
    if (rxw_we && !rxw_addr[0]) rx_even[rxw_addr[12:1]] <= rxw_d;
    if (rxw_we &&  rxw_addr[0]) rx_odd[rxw_addr[12:1]]  <= rxw_d;
end

reg [11:0] rxm_raddr;
reg  [7:0] rx_q_e, rx_q_o;
always @(posedge clk) begin
    rx_q_e <= rx_even[rxm_raddr];
    rx_q_o <= rx_odd[rxm_raddr];
end

// ---------------------------------------------------------------------------------------------
// The handshakes between the clocks (toggles: never reset)
// ---------------------------------------------------------------------------------------------

// RX: clk offers a free slot (offer_tgl, offer_slot); clk50 answers when a frame is in it
// (used_tgl = offer_tgl then, with done_len)
reg        offer_tgl = 1'b0;
reg  [1:0] offer_slot = 2'd0;
reg        used_tgl = 1'b0;
reg [10:0] done_len = 11'd0;

// TX: clk hands one frame to clk50 (job_tgl, job_slot, job_len); clk50 answers when it's out
reg        job_tgl = 1'b0;
reg  [2:0] job_slot = 3'd0;
reg [10:0] job_len = 11'd0;
reg        job_ack = 1'b0;

(* ASYNC_REG = "TRUE" *) reg [1:0] used_s = 2'b00;
(* ASYNC_REG = "TRUE" *) reg [1:0] jack_s = 2'b00;
always @(posedge clk) begin
    used_s <= {used_s[0], used_tgl};
    jack_s <= {jack_s[0], job_ack};
end
wire used_now = used_s[1];
wire jack_now = jack_s[1];

reg en_q = 1'b0;                        // the card on and out of reset (registered to cross)
always @(posedge clk) en_q <= enable && !reset;

(* ASYNC_REG = "TRUE" *) reg [1:0] offer_s = 2'b00;
(* ASYNC_REG = "TRUE" *) reg [1:0] job_s = 2'b00;
(* ASYNC_REG = "TRUE" *) reg [1:0] en_s = 2'b00;
always @(posedge clk50) begin
    offer_s <= {offer_s[0], offer_tgl};
    job_s   <= {job_s[0], job_tgl};
    en_s    <= {en_s[0], en_q};
end

// ---------------------------------------------------------------------------------------------
// clk: the queues
// ---------------------------------------------------------------------------------------------

reg  [3:0] rx_head = 4'd0;              // the card's (2C04)
reg  [3:0] rx_tail = 4'd0;              // ours (2C06)
reg [10:0] rx_lens [0:15];
reg  [1:0] rx_base = 2'd0;              // logical slot 0's physical one
reg        used_seen = 1'b0;
wire [3:0] rx_waiting = rx_tail - rx_head;
wire       offer_open = (offer_tgl != used_now);

reg [10:0] tx_lens [0:7];
reg [15:0] tx_seq = 16'h0000;
reg  [7:0] tx_busy_slot = 8'h00;        // queued or being sent: a write into it waits
reg  [2:0] jq_slot [0:7];
reg [10:0] jq_len  [0:7];
reg  [2:0] jq_rd = 3'd0, jq_wr = 3'd0;
reg  [3:0] jq_cnt = 4'd0;
reg        jack_seen = 1'b0;
wire       job_open = (job_tgl != jack_now);

reg [31:0] heartbeat = 32'd1;
reg [15:0] hb_div = 16'd0;

reg  [7:0] card_flags = 8'h00;          // the card's byte of 1000-1001 (1001)

integer i;
initial begin
    for (i = 0; i < 16; i = i + 1) rx_lens[i] = 11'd0;
    for (i = 0; i < 8; i = i + 1) begin tx_lens[i] = 11'd0; jq_slot[i] = 3'd0; jq_len[i] = 11'd0; end
end

// ---------------------------------------------------------------------------------------------
// clk: the mailbox port
// ---------------------------------------------------------------------------------------------

localparam [1:0] M_IDLE = 2'd0, M_WORD = 2'd1, M_CAP = 2'd2, M_ACK = 2'd3;
reg  [1:0] mst = M_IDLE;
reg        m_wr, m_wide;
reg        m_uds, m_lds;
reg [15:0] m_off;                       // byte offset of the word in hand
reg  [1:0] m_idx;                       // its lane in a wide transfer
reg [15:0] m_wdata;
reg [63:0] m_wdata64;

// The slot a window offset is in (600h slots from a base): RX 16, TX 8
function automatic [3:0] slot_of(input [15:0] rel);
    integer k;
    begin
        slot_of = 4'd0;
        for (k = 1; k < 16; k = k + 1)
            if (rel >= k * 16'h0600) slot_of = k[3:0];
    end
endfunction

wire        in_tx   = (m_off >= 16'h3000) && (m_off < 16'h6000);
wire        in_rx   = (m_off >= 16'h9000) && (m_off < 16'hF000);
wire [15:0] tx_rel  = m_off - 16'h3000;
wire [15:0] rx_rel  = m_off - 16'h9000;
wire  [3:0] rx_sl   = slot_of(rx_rel);
wire [15:0] rx_in   = rx_rel - ({6'd0, rx_sl, 10'd0} + {7'd0, rx_sl, 9'd0});
wire  [2:0] tx_sl   = slot_of(tx_rel);
wire [15:0] m_word  = m_wide ? m_wdata64[{m_idx, 4'd0} +: 16] : m_wdata;
wire [15:0] m_num   = {m_wdata[7:0], m_wdata[15:8]};      // a number the card writes
wire        tx_hold = in_tx && m_wr && tx_busy_slot[tx_sl];

always @(*) begin
    rxm_raddr = {rx_sl[1:0] + rx_base, rx_in[10:1]};
    txm_waddr = tx_rel[13:1];
    txm_wd_e  = m_word[15:8];
    txm_wd_o  = m_word[7:0];
    txm_we_e  = (mst == M_WORD) && m_wr && in_tx && !tx_hold && (m_wide || !m_uds);
    txm_we_o  = (mst == M_WORD) && m_wr && in_tx && !tx_hold && (m_wide || !m_lds);
end

// A control word as read (numbers little-endian: byte 2k the low one)
function automatic [15:0] le16(input [15:0] n);
    le16 = {n[7:0], n[15:8]};
endfunction

reg [15:0] ctrl_word;
always @(*) begin
    ctrl_word = 16'h0000;
    case (m_off)
        16'h1000: ctrl_word = {(rx_tail != rx_head) ? 8'h04 : 8'h00, card_flags};
        16'h104C: ctrl_word = mac[47:32];
        16'h104E: ctrl_word = mac[31:16];
        16'h1050: ctrl_word = mac[15:0];
        16'h1088: ctrl_word = le16(heartbeat[15:0]);
        16'h108A: ctrl_word = le16(heartbeat[31:16]);
        16'h108C: ctrl_word = le16(16'hBABE);
        16'h108E: ctrl_word = le16(16'hCAFE);
        16'h2C04: ctrl_word = le16({12'd0, rx_head});
        16'h2C06: ctrl_word = le16({12'd0, rx_tail});
        16'h2C08: ctrl_word = le16(tx_seq);
        default: begin
            if (m_off >= 16'h2C20 && m_off < 16'h2C40)
                ctrl_word = le16({5'd0, rx_lens[m_off[4:1]]});
            else if (m_off >= 16'h2C40 && m_off < 16'h2C50)
                ctrl_word = le16({5'd0, tx_lens[m_off[3:1]]});
        end
    endcase
end

wire [15:0] rd_word = in_rx ? {rx_q_e, rx_q_o} : in_tx ? 16'h0000 : ctrl_word;

// clk50's answers, seen here
wire rx_done_ev  = (used_now != used_seen);
wire tx_done_ev  = (jack_now != jack_seen);

// The card's writes that move the queues (taken in M_WORD)
wire w_ctrl      = (mst == M_WORD) && m_wr && !in_tx && !in_rx;
wire w_head      = w_ctrl && (m_off == 16'h2C04);
wire w_seq       = w_ctrl && (m_off == 16'h2C08);
wire w_txlen     = w_ctrl && (m_off >= 16'h2C40) && (m_off < 16'h2C50);
wire w_flags     = w_ctrl && (m_off == 16'h1000) && !m_lds;
// A read of the station address: the card is starting (a reset): empty the RX queue
wire r_mac0      = (mst == M_WORD) && !m_wr && (m_off == 16'h104C);
wire [10:0] seq_len = tx_lens[m_num[2:0]];                 // the staged frame's length
wire push_ok     = (seq_len != 11'd0) && (jq_cnt != 4'd8);

always @(posedge clk) begin
    dma_ready <= 1'b0;

    // The heartbeat: about once a millisecond, never 0
    hb_div <= hb_div + 16'd1;
    if (hb_div == 16'hFFFF)
        heartbeat <= (heartbeat == 32'hFFFFFFFF) ? 32'd1 : heartbeat + 32'd1;

    case (mst)
        M_IDLE: if (dma_req) begin
            m_wr      <= dma_write;
            m_wide    <= dma_wide;
            m_uds     <= dma_uds;
            m_lds     <= dma_lds;
            m_off     <= {dma_addr, 1'b0};
            m_idx     <= 2'd0;
            m_wdata   <= dma_wdata;
            m_wdata64 <= dma_wdata64;
            mst       <= M_WORD;
        end
        M_WORD: if (!tx_hold) mst <= M_CAP;       // a write into a slot still waiting holds
        M_CAP: begin
            if (!m_wr) begin
                if (m_wide) dma_rdata64[{m_idx, 4'd0} +: 16] <= rd_word;
                else        dma_rdata <= rd_word;
            end
            if (m_wide && m_idx != 2'd3) begin
                m_idx <= m_idx + 2'd1;
                m_off <= m_off + 16'd2;
                mst   <= M_WORD;
            end else begin
                dma_ready <= 1'b1;
                mst       <= M_ACK;
            end
        end
        M_ACK: mst <= M_IDLE;                     // the card drops req with the ready
    endcase

    if (w_flags) card_flags <= m_word[7:0];
    // a TX length: 1..1536 bytes (ne2000d's bound), else the frame isn't sent
    if (w_txlen) tx_lens[m_off[3:1]] <= (m_num <= 16'd1536) ? m_num[10:0] : 11'd0;
    if (w_seq) tx_seq <= m_num;

    // RX: the card took slots up to head
    if (w_head) rx_head <= m_num[3:0];

    // RX: a frame is in the offered slot
    if (rx_done_ev) begin
        used_seen <= used_now;
        rx_lens[rx_tail] <= done_len;
        rx_tail <= rx_tail + 4'd1;
    end
    // RX: offer the next slot when none is open and one is free
    if (!offer_open && !rx_done_ev && enable && !reset && rx_waiting < 4'd4 && !r_mac0) begin
        offer_slot <= rx_tail[1:0] + rx_base;
        offer_tgl  <= !offer_tgl;
    end

    // TX: queue a staged frame (seq mod 8), hand the queue's head to clk50 one at a time
    if (w_seq && push_ok) begin
        jq_slot[jq_wr] <= m_num[2:0];
        jq_len[jq_wr]  <= seq_len;
        jq_wr <= jq_wr + 3'd1;
        tx_busy_slot[m_num[2:0]] <= 1'b1;
    end
    if (tx_done_ev) begin
        jack_seen <= jack_now;
        tx_busy_slot[job_slot] <= 1'b0;
    end
    if (!job_open && !tx_done_ev && jq_cnt != 4'd0) begin
        job_slot <= jq_slot[jq_rd];
        job_len  <= jq_len[jq_rd];
        job_tgl  <= !job_tgl;
        jq_rd    <= jq_rd + 3'd1;
    end
    jq_cnt <= jq_cnt + ((w_seq && push_ok) ? 4'd1 : 4'd0)
                     - ((!job_open && !tx_done_ev && jq_cnt != 4'd0) ? 4'd1 : 4'd0);

    // Empty the RX queue at the card's start (its reset) and at ours. The slot on offer (or
    // the next one) becomes logical slot 0: a frame coming into it now is the first after
    // the reset (a frame being answered this very clock is dropped with the old ones)
    if (r_mac0 || reset) begin
        rx_head <= 4'd0;
        rx_tail <= 4'd0;
        rx_base <= offer_open ? offer_slot : rx_tail[1:0] + rx_base;
    end
    if (reset) begin
        mst          <= M_IDLE;
        dma_ready    <= 1'b0;
        card_flags   <= 8'h00;
        tx_seq       <= 16'h0000;
        jq_rd        <= 3'd0;
        jq_wr        <= 3'd0;
        jq_cnt       <= 4'd0;
        tx_busy_slot <= 8'h00;
    end
end

// ---------------------------------------------------------------------------------------------
// clk50: the frame writer and the sender
// ---------------------------------------------------------------------------------------------

function automatic [7:0] mac_byte(input [47:0] m, input [2:0] n);
    case (n)
        3'd0: mac_byte = m[47:40];
        3'd1: mac_byte = m[39:32];
        3'd2: mac_byte = m[31:24];
        3'd3: mac_byte = m[23:16];
        3'd4: mac_byte = m[15:8];
        default: mac_byte = m[7:0];
    endcase
endfunction

reg        rx_act = 1'b0;
reg [10:0] rx_ptr = 11'd0;
reg  [1:0] rx_slot = 2'd0;
reg        rx_uc = 1'b0, rx_bc = 1'b0;
reg        rx_full = 1'b0;                     // past 2047 bytes: too long anyway
wire       offer_here = (offer_s[1] != used_tgl) && en_s[1];

always @(posedge clk50) begin
    rxw_we <= 1'b0;
    if (rst50) begin
        rx_act <= 1'b0;
    end else if (rx_start) begin
        rx_act  <= offer_here;
        rx_ptr  <= 11'd0;
        rx_full <= 1'b0;
        rx_slot <= offer_slot;
        rx_uc   <= 1'b1;
        rx_bc   <= 1'b1;
    end else if (rx_act) begin
        if (rx_valid && !rx_full) begin
            rxw_we   <= 1'b1;
            rxw_addr <= {rx_slot, rx_ptr};
            rxw_d    <= rx_byte;
            if (rx_ptr < 11'd6) begin
                if (rx_byte != mac_byte(mac, rx_ptr[2:0])) rx_uc <= 1'b0;
                if (rx_byte != 8'hFF) rx_bc <= 1'b0;
            end
            if (rx_ptr == 11'd2047) rx_full <= 1'b1;
            else rx_ptr <= rx_ptr + 11'd1;
        end
        if (rx_end) begin
            rx_act <= 1'b0;
            if (rx_ok && (rx_uc || rx_bc) && !rx_full &&
                rx_ptr >= 11'd64 && rx_ptr <= 11'd1518) begin
                done_len <= rx_ptr - 11'd4;
                used_tgl <= offer_s[1];          // the slot is used: answer the offer
            end
        end
    end
end

// The sender: one frame at a time from its slot (slot x 600h + eth_mac's address)
localparam [1:0] T_IDLE = 2'd0, T_START = 2'd1, T_RUN = 2'd2, T_END = 2'd3;
reg  [1:0] tst = T_IDLE;
reg [13:0] t_base = 14'd0;
reg        job_seen = 1'b0;

always @(*) tx_raddr = t_base + {3'd0, tx_addr};

always @(posedge clk50) begin
    tx_start <= 1'b0;
    if (rst50) begin
        tst <= T_IDLE;
    end else case (tst)
        T_IDLE: if (job_s[1] != job_seen && !tx_busy) begin
            job_seen <= job_s[1];
            t_base   <= {1'b0, job_slot, 10'd0} + {2'b00, job_slot, 9'd0};
            tx_len   <= job_len;
            tx_start <= 1'b1;
            tst      <= T_START;
        end
        T_START: if (tx_busy) tst <= T_RUN;         // the MAC took it
        T_RUN:   if (!tx_busy) tst <= T_END;        // sent, gap included
        T_END: begin
            job_ack <= job_seen;
            tst     <= T_IDLE;
        end
    endcase
end

endmodule

`default_nettype wire
