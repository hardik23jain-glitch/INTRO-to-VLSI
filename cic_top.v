`timescale 1ns / 1ps
// Task 1: 3rd-order CIC decimator (R = 2048, M = 1) with 20-bit output
module cic_top (
    input  wire               clk,
    input  wire               reset,      // synchronous, active high
    input  wire               enable,
    input  wire signed [1:0]  bits,       // sigma-delta stream: -1, 0, +1
    output reg  signed [19:0] dout,       // 20-bit result
    output reg                outready    // one-clock pulse per output sample
);
    localparam integer R      = 2048;
    localparam integer PHASE  = 1000;         // sets when the output register updates
    localparam integer W      = 35;           // 2 + 3*log2(2048) bits (Hogenauer)
    localparam integer GSHIFT = 28;
    // output gain = 57343 = 2^16 - 2^13 - 1, built from shifts and adds (no multiplier)

    // 1) capture the input on the falling edge (avoids a race with the testbench)
    reg signed [1:0] bits_q;
    always @(negedge clk) begin
        if (reset) bits_q <= 2'sd0;
        else       bits_q <= bits;
    end

    // 2) three integrators at the full clock rate (wrap-around arithmetic)
    reg signed [W-1:0] i1, i2, i3;
    always @(posedge clk) begin
        if (reset) begin
            i1 <= 0;  i2 <= 0;  i3 <= 0;
        end else if (enable) begin
            i1 <= i1 + bits_q;
            i2 <= i2 + i1;
            i3 <= i3 + i2;
        end
    end

    // 3) down-sample by R: one strobe every 2048 clocks
    reg [10:0] cnt;
    reg        strobe;
    always @(posedge clk) begin
        if (reset) begin
            cnt    <= R-1-PHASE;
            strobe <= 1'b0;
        end else if (enable) begin
            cnt    <= (cnt == R-1) ? 11'd0 : cnt + 11'd1;
            strobe <= (cnt == R-1);
        end
    end

    // 4) three combs, running only on the strobe
    reg  signed [W-1:0] d1, d2, d3, y;
    reg                 y_valid;
    wire signed [W-1:0] c1 = i3 - d1;
    wire signed [W-1:0] c2 = c1 - d2;
    wire signed [W-1:0] c3 = c2 - d3;
    always @(posedge clk) begin
        if (reset) begin
            d1 <= 0;  d2 <= 0;  d3 <= 0;  y <= 0;  y_valid <= 1'b0;
        end else begin
            y_valid <= strobe;
            if (strobe) begin
                d1 <= i3;  d2 <= c1;  d3 <= c2;
                y  <= c3;
            end
        end
    end

    // 5) scale to 20 bits: dout = round(y * 57343 / 2^28), clipped to 20 bits
    localparam signed [51:0] MAXV = 52'sd524287;
    localparam signed [51:0] MINV = -52'sd524288;
    localparam signed [19:0] OMAX = 20'sh7FFFF;
    localparam signed [19:0] OMIN = 20'sh80000;
    wire signed [51:0] y_ext  = y;
    wire signed [51:0] prod   = (y_ext <<< 16) - (y_ext <<< 13) - y_ext;   // y * 57343
    wire signed [51:0] shf    = (prod + 52'sd134217728) >>> GSHIFT;   // + 2^27, then shift

    always @(posedge clk) begin
        if (reset) begin
            dout     <= 20'sd0;
            outready <= 1'b0;
        end else begin
            outready <= y_valid;
            if (y_valid)
                dout <= (shf > MAXV) ? OMAX : (shf < MINV) ? OMIN : shf[19:0];
        end
    end
endmodule