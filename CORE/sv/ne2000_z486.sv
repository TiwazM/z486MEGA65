//
// z486 for MEGA65: an NE2000 network card at 300h (32 ports), IRQ 10, on system.sv's I/O byte
// bus. The card is georgemog's ao486 port of apolkosnik's Minimig NE2000 / RTL8019AS model
// (ne2000/ne2000_core.v, ne2000_packet_ram.v and its ISA glue ne2000_isa.v; GPL-3,
// github.com/georgemog/ao486_MiSTer branch ne2000 a3d5953), unchanged; its network side is
// ne2k_host.sv (in place of MiSTer's ne2000d) in front of eth_port.vhd's MAC.
//
// Ports (from the base): 00-0F the DP8390's registers, 10-17 the remote-DMA data port, 18-1F
// the reset port (a read resets the card). Drivers move frames through the data port with
// 16-bit IN/OUT (REP INSW/OUTSW, DCR word mode). iobus_adapter.sv makes every CPU access a
// run of byte cycles (310h, then 311h for a word); ne2000_isa.v wants a 16-bit access in one
// cycle (io_32), as ao486's bus gives it. So a data-port byte that is the low half of a word
// (the CPU's byte enables say so: io_cpu_be, from the adapter) reads the whole word from the
// card and keeps its high byte for the next cycle; for a write the low byte waits and the
// high byte's cycle writes the word. A doubleword is two words; a single byte is a byte.
// Registers are bytes. The adapter waits (io_hold) while the card answers.
//
// The menu switches the card (enable): off, nothing answers at 300h (system.sv), the card and
// its network side are held in reset and the PHY too (eth_port.vhd).
//
`default_nettype none

module ne2000_z486 #(
    parameter int CLK_HZ = 64_000_000
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,             // the menu's "Network card"

    // system.sv's I/O byte bus (iobus_adapter.sv: one-clock strobes, data the clock after)
    input  wire        io_cs,              // 300-31F (registered with the address)
    input  wire [15:0] io_address,
    input  wire        io_read,
    input  wire        io_write,
    input  wire  [7:0] io_writedata,
    input  wire  [3:0] io_cpu_be,          // the CPU access's byte enables (the adapter's)
    output wire  [7:0] io_readdata,
    output wire        io_hold,
    output wire        irq,                // IRQ 10

    input  wire [47:0] mac,                // the station address (eth_port.vhd, from the DNA)

    // eth_port.vhd's streams (clk50)
    input  wire        clk50,
    input  wire        rst50,
    input  wire        rx_start,
    input  wire        rx_valid,
    input  wire  [7:0] rx_byte,
    input  wire        rx_end,
    input  wire        rx_ok,
    output wire        tx_start,
    output wire [10:0] tx_len,
    input  wire [10:0] tx_addr,
    output wire  [7:0] tx_data,
    input  wire        tx_busy
);

wire card_reset = reset || !enable;

// ---------------------------------------------------------------------------------------------
// The byte cycles as the card's accesses
// ---------------------------------------------------------------------------------------------

wire       acc      = io_cs && (io_read || io_write);
wire [1:0] bi       = io_address[1:0];
wire       dataport = (io_address[4:3] == 2'b10);
wire       word_lo  = dataport && !io_address[0] && io_cpu_be[bi + 2'd1];   // a word's low byte
wire       word_hi  = dataport &&  io_address[0] && io_cpu_be[bi - 2'd1];   // and its high byte

wire       isa_read  = acc && io_read  && !word_hi;      // the high byte is the kept one
wire       isa_write = acc && io_write && !word_lo;      // the low byte waits for it
wire       isa_32    = (io_read && word_lo) || (io_write && word_hi);

reg  [7:0] lo_byte = 8'h00;
reg        sel_hi = 1'b0;
always @(posedge clk) begin
    if (acc && io_write && word_lo) lo_byte <= io_writedata;
    if (acc && io_read) sel_hi <= word_hi;
end

wire [31:0] isa_rdata;
wire        isa_wait;
wire        card_irq;

// The card's last answer: a word's high byte stays there until the next access
assign io_readdata = sel_hi ? isa_rdata[15:8] : isa_rdata[7:0];
assign io_hold     = isa_read || isa_write || isa_wait;
assign irq         = enable && card_irq;

// ---------------------------------------------------------------------------------------------
// The card and its network side
// ---------------------------------------------------------------------------------------------

wire        dma_req, dma_write, dma_wide, dma_uds, dma_lds, dma_ready;
wire [15:1] dma_addr;
wire [15:0] dma_wdata, dma_rdata;
wire [63:0] dma_wdata64, dma_rdata64;

ne2000_isa #(
    .DEBUG_APERTURE   (1'b0)
) card (
    .clk              (clk),
    .reset            (card_reset),
    .io_address       ({1'b0, io_address[4:0]}),
    .io_read          (isa_read),
    .io_write         (isa_write),
    .io_writedata     (isa_32 ? {16'h0000, io_writedata, lo_byte} : {24'h000000, io_writedata}),
    .io_32            (isa_32),
    .io_readdata      (isa_rdata),
    .io_wait          (isa_wait),
    .irq              (card_irq),
    .eth_dma_ready    (dma_ready),
    .eth_dma_rdata    (dma_rdata),
    .eth_dma_rdata64  (dma_rdata64),
    .eth_dma_req      (dma_req),
    .eth_dma_write    (dma_write),
    .eth_dma_addr     (dma_addr),
    .eth_dma_wdata    (dma_wdata),
    .eth_dma_wide     (dma_wide),
    .eth_dma_wdata64  (dma_wdata64),
    .eth_dma_uds      (dma_uds),
    .eth_dma_lds      (dma_lds)
);

ne2k_host #(
    .CLK_HZ           (CLK_HZ)
) host (
    .clk              (clk),
    .reset            (card_reset),
    .enable           (enable),
    .mac              (mac),
    .dma_req          (dma_req),
    .dma_write        (dma_write),
    .dma_addr         (dma_addr),
    .dma_wdata        (dma_wdata),
    .dma_wide         (dma_wide),
    .dma_wdata64      (dma_wdata64),
    .dma_uds          (dma_uds),
    .dma_lds          (dma_lds),
    .dma_ready        (dma_ready),
    .dma_rdata        (dma_rdata),
    .dma_rdata64      (dma_rdata64),
    .clk50            (clk50),
    .rst50            (rst50),
    .rx_start         (rx_start),
    .rx_valid         (rx_valid),
    .rx_byte          (rx_byte),
    .rx_end           (rx_end),
    .rx_ok            (rx_ok),
    .tx_start         (tx_start),
    .tx_len           (tx_len),
    .tx_addr          (tx_addr),
    .tx_data          (tx_data),
    .tx_busy          (tx_busy)
);

endmodule

`default_nettype wire
