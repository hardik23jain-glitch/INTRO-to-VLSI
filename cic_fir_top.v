`timescale 1ns / 1ps
// Task 2: 3rd-order CIC decimator (R = 2048, M = 1) + 4-tap FIR droop compensator
//         running at the decimated rate (2 kHz), 20-bit output
module cic_fir_top (
    input  wire               clk,
    input  wire               reset,      // synchronous, active high
    input  wire               enable,
    input  wire signed [1:0]  bits,       // sigma-delta stream: -1, 0, +1
    output reg  signed [19:0] dout,       // 20-bit result
    output reg                outready    // one-clock pulse per output sample
);
    localparam integer R     = 2048;
    localparam integer PHASE = 1000;
    localparam integer W     = 35;        // 2 + 3*11  (Hogenauer bound)

    // FIR taps, 18-bit signed, 18 fractional bits (overall output gain is folded in)
    localparam signed [17:0] C0 =  18'sd12299;
    localparam signed [17:0] C1 = -18'sd8117;
    localparam signed [17:0] C2 =  18'sd4779;
    localparam signed [17:0] C3 = -18'sd1793;

    //------------------------------------------------------------------
    // CIC: input captured on the falling edge, 3 integrators, 3 combs
    //------------------------------------------------------------------
    reg signed [1:0] bits_q;
    always @(negedge clk) begin
        if (reset) bits_q <= 2'sd0;
        else       bits_q <= bits;
    end

    reg signed [W-1:0] i1, i2, i3;
    always @(posedge clk) begin
        if (reset) begin i1 <= 0; i2 <= 0; i3 <= 0; end
        else if (enable) begin
            i1 <= i1 + bits_q;
            i2 <= i2 + i1;
            i3 <= i3 + i2;
        end
    end

    reg [10:0] cnt;
    reg        strobe;
    always @(posedge clk) begin
        if (reset) begin cnt <= R-1-PHASE; strobe <= 1'b0; end
        else if (enable) begin
            cnt    <= (cnt == R-1) ? 11'd0 : cnt + 11'd1;
            strobe <= (cnt == R-1);
        end
    end

    reg  signed [W-1:0] d1, d2, d3, y;
    reg                 y_valid;
    wire signed [W-1:0] c1 = i3 - d1;
    wire signed [W-1:0] c2 = c1 - d2;
    wire signed [W-1:0] c3 = c2 - d3;
    always @(posedge clk) begin
        if (reset) begin d1 <= 0; d2 <= 0; d3 <= 0; y <= 0; y_valid <= 1'b0; end
        else begin
            y_valid <= strobe;
            if (strobe) begin d1 <= i3; d2 <= c1; d3 <= c2; y <= c3; end
        end
    end

    //------------------------------------------------------------------
    // FIR input: round the 35-bit CIC word to 28 bits (drop 7 LSBs)
    //------------------------------------------------------------------
    localparam signed [35:0] XMAX =  36'sd134217727;    //  2^27 - 1
    localparam signed [35:0] XMIN = -36'sd134217728;    // -2^27
    wire signed [35:0] y_r = y + 36'sd64;
    wire signed [35:0] y_s = y_r >>> 7;
    wire signed [27:0] xin = (y_s > XMAX) ? 28'sh7FFFFFF :
                             (y_s < XMIN) ? 28'sh8000000 : y_s[27:0];

    //------------------------------------------------------------------
    // FIR: one multiplier/accumulator shared by the 4 taps (>2000 clocks
    // are available per output sample, so tap k is handled on clock k)
    //------------------------------------------------------------------
    reg signed [27:0] x0, x1, x2, x3;       // x0 = newest sample
    reg signed [48:0] acc;
    reg        [1:0]  idx;
    reg        [1:0]  state;
    localparam [1:0] S_IDLE = 2'd0, S_MAC = 2'd1, S_OUT = 2'd2;

    reg signed [17:0] coef;
    reg signed [27:0] xsel;
    always @(*) begin
        case (idx)
            2'd0:    begin coef = C0; xsel = x0; end
            2'd1:    begin coef = C1; xsel = x1; end
            2'd2:    begin coef = C2; xsel = x2; end
            default: begin coef = C3; xsel = x3; end
        endcase
    end
    wire signed [48:0] term = coef * xsel;

    // output: round (18 fractional bits) and saturate to 20 bits
    localparam signed [48:0] YMAX =  49'sd524287;
    localparam signed [48:0] YMIN = -49'sd524288;
    wire signed [48:0] acc_r = acc + 49'sd131072;
    wire signed [48:0] acc_s = acc_r >>> 18;

    always @(posedge clk) begin
        if (reset) begin
            x0 <= 0; x1 <= 0; x2 <= 0; x3 <= 0;
            acc <= 0; idx <= 0; state <= S_IDLE;
            dout <= 20'sd0; outready <= 1'b0;
        end else begin
            outready <= 1'b0;
            case (state)
                S_IDLE: if (y_valid) begin
                    x0 <= xin; x1 <= x0; x2 <= x1; x3 <= x2;
                    acc <= 0; idx <= 0; state <= S_MAC;
                end
                S_MAC: begin
                    acc <= acc + term;
                    if (idx == 2'd3) state <= S_OUT;
                    else             idx   <= idx + 2'd1;
                end
                S_OUT: begin
                    dout     <= (acc_s > YMAX) ? 20'sh7FFFF :
                                (acc_s < YMIN) ? 20'sh80000 : acc_s[19:0];
                    outready <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule