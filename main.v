`timescale 1ns / 1ps

//============================================================================
// TOP MODULE
//============================================================================
module top_module (
    input  wire        CLK100MHZ,
    input  wire        BTNC,
    input  wire        BTNR, 
    input  wire        M_DATA,
    output wire        M_CLK,
    output wire        M_LRSEL,
    output wire [6:0]  seg,
    output wire [7:0]  an,
    output wire [15:0] LED
);
    wire clk = CLK100MHZ;
    wire rst = BTNC;

    wire pdm_bit_fall, pdm_bit_rise;
    wire pdm_fall_valid, pdm_rise_valid;
    
    mic_driver_dual u_mic (
        .clk(clk), .rst(rst),
        .mic_data(M_DATA),
        .mic_clk(M_CLK), .mic_lrsel(M_LRSEL),
        .pdm_bit_fall(pdm_bit_fall), .pdm_bit_rise(pdm_bit_rise),
        .fall_valid(pdm_fall_valid), .rise_valid(pdm_rise_valid)
    );

    wire [15:0] pcm_left, pcm_right;
    wire pcm_left_valid, pcm_right_valid;
    
    cic_filter u_cic_l (
        .clk(clk), .rst(rst),
        .pdm_in(pdm_bit_fall), .pdm_valid(pdm_fall_valid),
        .pcm_out(pcm_left), .pcm_valid(pcm_left_valid)
    );
    cic_filter u_cic_r (
        .clk(clk), .rst(rst),
        .pdm_in(pdm_bit_rise), .pdm_valid(pdm_rise_valid),
        .pcm_out(pcm_right), .pcm_valid(pcm_right_valid)
    );

    wire [15:0] amp_5k_l, amp_9k_l, amp_13k_l;
    wire [15:0] amp_5k_r, amp_9k_r, amp_13k_r;
    wire spectrum_valid;
    
    cordic_spectrum u_spectrum (
        .clk(clk), .rst(rst),
        .pcm_left(pcm_left), .pcm_right(pcm_right),
        .pcm_valid(pcm_left_valid),
        .amp_5k_l(amp_5k_l), .amp_9k_l(amp_9k_l), .amp_13k_l(amp_13k_l),
        .amp_5k_r(amp_5k_r), .amp_9k_r(amp_9k_r), .amp_13k_r(amp_13k_r),
        .valid_out(spectrum_valid)
    );

    wire [2:0] entropy_bits;
    wire entropy_valid;
    
    entropy_extractor u_entropy (
        .clk(clk), .rst(rst),
        .amp_5k_l(amp_5k_l), .amp_9k_l(amp_9k_l), .amp_13k_l(amp_13k_l),
        .amp_5k_r(amp_5k_r), .amp_9k_r(amp_9k_r), .amp_13k_r(amp_13k_r),
        .amp_valid(spectrum_valid),
        .entropy_bits(entropy_bits),
        .entropy_valid(entropy_valid)
    );

    wire [31:0] random_num;
    wire random_ready;
    
    bit_accumulator u_accum (
        .clk(clk), .rst(rst),
        .bits_in(entropy_bits),
        .bits_valid(entropy_valid),
        .random_out(random_num),
        .ready(random_ready)
    );

    // ============================================================
    // BTNR: зажата = заморозка, отпущена = обновление
    // BTNC: сброс в 0
    // ============================================================
    reg btn_s1 = 0, btn_s2 = 0;
    always @(posedge clk) begin
        btn_s1 <= BTNR;
        btn_s2 <= btn_s1;
    end
    wire btn_held = btn_s2;

    reg [31:0] display_val = 0;

    always @(posedge clk) begin
        if (rst) begin
            display_val <= 0;
        end else begin
            if (!btn_held && random_ready)
                display_val <= random_num;
        end
    end

    seven_seg_driver u_display (
        .clk(clk), .rst(rst),
        .data(display_val),
        .seg(seg), .an(an)
    );
    assign LED = display_val[15:0];
endmodule

//============================================================================
// MIC DRIVER
//============================================================================
module mic_driver_dual (
    input  wire clk, rst,
    input  wire mic_data,
    output wire mic_clk, mic_lrsel,
    output reg  pdm_bit_fall, pdm_bit_rise,
    output reg  fall_valid, rise_valid
);
    assign mic_lrsel = 1'b0;
    reg [5:0] cnt = 0;
    reg mclk = 0;

    always @(posedge clk) begin
        if (rst) begin cnt<=0; mclk<=0; end
        else if (cnt == 6'd41) begin cnt<=0; mclk<=0; end
        else begin cnt<=cnt+1; if (cnt==6'd20) mclk<=1; end
    end
    assign mic_clk = mclk;

    reg s1=0,s2=0,s3=0;
    always @(posedge clk) begin s1<=mic_data; s2<=s1; s3<=s2; end

    reg md=0;
    always @(posedge clk) md<=mclk;
    wire fe = md & ~mclk;
    wire re = ~md & mclk;

    always @(posedge clk) begin
        if (rst) begin
            pdm_bit_fall<=0; pdm_bit_rise<=0;
            fall_valid<=0; rise_valid<=0;
        end else begin
            fall_valid<=0; rise_valid<=0;
            if (fe) begin pdm_bit_fall<=s3; fall_valid<=1; end
            if (re) begin pdm_bit_rise<=s3; rise_valid<=1; end
        end
    end
endmodule


//============================================================================
// CIC FILTER
//============================================================================
module cic_filter (
    input  wire        clk, rst,
    input  wire        pdm_in,
    input  wire        pdm_valid,
    output reg  [15:0] pcm_out,
    output reg         pcm_valid
);
    localparam DECIM = 50;
    reg [5:0] dc = 0;
    always @(posedge clk) begin
        if (rst) dc<=0;
        else if (pdm_valid) dc<=(dc==DECIM-1)?6'd0:dc+1;
    end
    wire dtick = (dc==DECIM-1) && pdm_valid;

    wire signed [23:0] ps = pdm_in ? 24'sd1 : -24'sd1;
    reg signed [23:0] i1=0,i2=0,i3=0,i4=0;
    always @(posedge clk) begin
        if (rst) begin i1<=0;i2<=0;i3<=0;i4<=0; end
        else if (pdm_valid) begin
            i1<=i1+ps; i2<=i2+i1; i3<=i3+i2; i4<=i4+i3;
        end
    end

    reg signed [23:0] cd1=0,co1=0; reg cv1=0;
    reg signed [23:0] cd2=0,co2=0; reg cv2=0;
    reg signed [23:0] cd3=0,co3=0; reg cv3=0;
    reg signed [23:0] cd4=0,co4=0; reg cv4=0;

    always @(posedge clk) begin
        if (rst) begin
            cd1<=0;co1<=0;cv1<=0; cd2<=0;co2<=0;cv2<=0;
            cd3<=0;co3<=0;cv3<=0; cd4<=0;co4<=0;cv4<=0;
            pcm_out<=0; pcm_valid<=0;
        end else begin
            cv1<=dtick;
            if (dtick) begin co1<=i4-cd1; cd1<=i4; end
            cv2<=cv1;
            if (cv1) begin co2<=co1-cd2; cd2<=co1; end
            cv3<=cv2;
            if (cv2) begin co3<=co2-cd3; cd3<=co2; end
            cv4<=cv3;
            if (cv3) begin co4<=co3-cd4; cd4<=co3; end
            pcm_valid<=cv4;
            if (cv4) pcm_out<=co4[23:8];
            else pcm_valid<=0;
        end
    end
endmodule


//============================================================================
// CORDIC CORE
//============================================================================
module cordic_core (
    input  wire        clk, rst,
    input  wire signed [17:0] theta,
    input  wire        go,
    output reg  signed [17:0] c_out, s_out,
    output reg         rdy
);
    reg signed [17:0] atan_rom [0:15];
    initial begin
        atan_rom[0]=18'sd16384; atan_rom[1]=18'sd9672;
        atan_rom[2]=18'sd5110;  atan_rom[3]=18'sd2594;
        atan_rom[4]=18'sd1302;  atan_rom[5]=18'sd651;
        atan_rom[6]=18'sd326;   atan_rom[7]=18'sd163;
        atan_rom[8]=18'sd81;    atan_rom[9]=18'sd41;
        atan_rom[10]=18'sd20;   atan_rom[11]=18'sd10;
        atan_rom[12]=18'sd5;    atan_rom[13]=18'sd3;
        atan_rom[14]=18'sd1;    atan_rom[15]=18'sd1;
    end
    localparam signed [17:0] K = 18'sd39797;
    reg signed [17:0] x,y,z;
    reg [4:0] i;
    reg busy;

    always @(posedge clk) begin
        if (rst) begin
            x<=0;y<=0;z<=0;i<=0;busy<=0;rdy<=0;c_out<=0;s_out<=0;
        end else begin
            rdy<=0;
            if (go && !busy) begin
                x<=K; y<=0; z<=theta; i<=0; busy<=1;
            end else if (busy) begin
                if (i<5'd16) begin
                    if (!z[17]) begin
                        x<=x-(y>>>i); y<=y+(x>>>i); z<=z-atan_rom[i[3:0]];
                    end else begin
                        x<=x+(y>>>i); y<=y-(x>>>i); z<=z+atan_rom[i[3:0]];
                    end
                    i<=i+1;
                end else begin
                    c_out<=x; s_out<=y; rdy<=1; busy<=0;
                end
            end
        end
    end
endmodule


//============================================================================
// CORDIC SPECTRUM - 3 бина ? 2 канала
//============================================================================
module cordic_spectrum (
    input  wire        clk, rst,
    input  wire [15:0] pcm_left, pcm_right,
    input  wire        pcm_valid,
    output reg  [15:0] amp_5k_l, amp_9k_l, amp_13k_l,
    output reg  [15:0] amp_5k_r, amp_9k_r, amp_13k_r,
    output reg         valid_out
);
    localparam N = 64;
    localparam [5:0] BIN0=6'd7, BIN1=6'd12, BIN2=6'd18;

    localparam S_COLLECT=0, S_SETUP=1, S_CORDIC=2, S_WAIT=3,
               S_ACCUM=4, S_MAG=5, S_NEXT=6, S_DONE=7;
    reg [2:0] state = S_COLLECT;

    reg signed [15:0] bl [0:63];
    reg signed [15:0] br [0:63];
    reg [5:0] col_cnt = 0;

    reg [2:0] chan = 0;
    reg [5:0] n = 0;
    reg [5:0] cur_bin;

    reg signed [31:0] re_acc, im_acc;
    reg cordic_go = 0;
    wire signed [17:0] cordic_cos, cordic_sin;
    wire cordic_rdy;

    wire [11:0] kn = cur_bin * n;
    wire signed [17:0] angle = -$signed({kn, 6'b0});

    cordic_core u_c (
        .clk(clk),.rst(rst),
        .theta(angle),.go(cordic_go),
        .c_out(cordic_cos),.s_out(cordic_sin),.rdy(cordic_rdy)
    );

    reg signed [15:0] cur_samp;
    wire signed [33:0] p_re = cur_samp * cordic_cos;
    wire signed [33:0] p_im = cur_samp * cordic_sin;

    reg [15:0] results [0:5];

    always @(*) begin
        case (chan)
            3'd0,3'd3: cur_bin = BIN0;
            3'd1,3'd4: cur_bin = BIN1;
            3'd2,3'd5: cur_bin = BIN2;
            default: cur_bin = BIN0;
        endcase
    end

    integer j;
    always @(posedge clk) begin
        if (rst) begin
            state<=S_COLLECT; col_cnt<=0; chan<=0; n<=0;
            re_acc<=0; im_acc<=0; cordic_go<=0; valid_out<=0;
            amp_5k_l<=0;amp_9k_l<=0;amp_13k_l<=0;
            amp_5k_r<=0;amp_9k_r<=0;amp_13k_r<=0;
            for(j=0;j<6;j=j+1) results[j]<=0;
        end else begin
            cordic_go<=0; valid_out<=0;
            case (state)
                S_COLLECT: begin
                    if (pcm_valid) begin
                        bl[col_cnt]<=$signed(pcm_left);
                        br[col_cnt]<=$signed(pcm_right);
                        if (col_cnt==N-1) begin
                            col_cnt<=0; chan<=0; state<=S_SETUP;
                        end else col_cnt<=col_cnt+1;
                    end
                end
                S_SETUP: begin
                    n<=0; re_acc<=0; im_acc<=0; state<=S_CORDIC;
                end
                S_CORDIC: begin
                    cur_samp <= (chan<3) ? bl[n] : br[n];
                    cordic_go<=1; state<=S_WAIT;
                end
                S_WAIT: begin
                    if (cordic_rdy) state<=S_ACCUM;
                end
                S_ACCUM: begin
                    re_acc <= re_acc + (p_re>>>16);
                    im_acc <= im_acc - (p_im>>>16);
                    if (n==N-1) state<=S_MAG;
                    else begin n<=n+1; state<=S_CORDIC; end
                end
                S_MAG: begin
                    begin: mc
                        reg [31:0] ar,ai;
                        reg [15:0] mx,mn;
                        ar = re_acc[31] ? (~re_acc+1) : re_acc;
                        ai = im_acc[31] ? (~im_acc+1) : im_acc;
                        mx = (ar[23:8]>ai[23:8]) ? ar[23:8] : ai[23:8];
                        mn = (ar[23:8]>ai[23:8]) ? ai[23:8] : ar[23:8];
                        results[chan] = mx + (mn>>1);
                    end
                    state<=S_NEXT;
                end
                S_NEXT: begin
                    if (chan==3'd5) begin
                        amp_5k_l<=results[0]; amp_9k_l<=results[1]; amp_13k_l<=results[2];
                        amp_5k_r<=results[3]; amp_9k_r<=results[4]; amp_13k_r<=results[5];
                        state<=S_DONE;
                    end else begin
                        chan<=chan+1; state<=S_SETUP;
                    end
                end
                S_DONE: begin valid_out<=1; state<=S_COLLECT; end
            endcase
        end
    end
endmodule


//============================================================================
// ENTROPY EXTRACTOR - 3 бита за раз + Von Neumann на каждый бит
//============================================================================
module entropy_extractor (
    input  wire        clk, rst,
    input  wire [15:0] amp_5k_l, amp_9k_l, amp_13k_l,
    input  wire [15:0] amp_5k_r, amp_9k_r, amp_13k_r,
    input  wire        amp_valid,
    output reg  [2:0]  entropy_bits,
    output reg         entropy_valid
);
    // Сырые биты из амплитуд
    wire bit_a = amp_5k_l[0] ^ amp_9k_l[0] ^ amp_13k_l[0] ^
                 amp_5k_l[1] ^ amp_9k_l[1] ^ amp_13k_l[1];

    wire bit_b = amp_5k_r[0] ^ amp_9k_r[0] ^ amp_13k_r[0] ^
                 amp_5k_r[1] ^ amp_9k_r[1] ^ amp_13k_r[1];

    wire bit_c = amp_5k_l[2] ^ amp_9k_l[2] ^ amp_13k_l[2] ^
                 amp_5k_r[2] ^ amp_9k_r[2] ^ amp_13k_r[2];

    // Von Neumann для каждого канала
    reg prev_a = 0, prev_b = 0, prev_c = 0;
    reg have_a = 0, have_b = 0, have_c = 0;

    wire emit_a = amp_valid && have_a && (prev_a != bit_a);
    wire emit_b = amp_valid && have_b && (prev_b != bit_b);
    wire emit_c = amp_valid && have_c && (prev_c != bit_c);

    wire fill_bit = emit_a ? prev_a : 
                    emit_b ? prev_b : 
                    emit_c ? prev_c : 1'b0;

    wire [2:0] bits_out = {
        emit_a ? prev_a : fill_bit ^ 1'b1,
        emit_b ? prev_b : fill_bit,
        emit_c ? prev_c : fill_bit ^ 1'b1
    };

    wire any_emit = emit_a || emit_b || emit_c;

    always @(posedge clk) begin
        if (rst) begin
            prev_a <= 0; prev_b <= 0; prev_c <= 0;
            have_a <= 0; have_b <= 0; have_c <= 0;
            entropy_bits <= 3'b000;
            entropy_valid <= 1'b0;
        end else begin
            entropy_valid <= 1'b0;

            if (amp_valid) begin
                if (any_emit) begin
                    entropy_bits  <= bits_out;
                    entropy_valid <= 1'b1;
                end

                if (!have_a) begin prev_a <= bit_a; have_a <= 1'b1; end
                else             have_a <= 1'b0;

                if (!have_b) begin prev_b <= bit_b; have_b <= 1'b1; end
                else             have_b <= 1'b0;

                if (!have_c) begin prev_c <= bit_c; have_c <= 1'b1; end
                else             have_c <= 1'b0;
            end
        end
    end
endmodule

module bit_accumulator (
    input  wire        clk, rst,
    input  wire [2:0]  bits_in,
    input  wire        bits_valid,
    output reg  [31:0] random_out,
    output reg         ready
);
    reg [31:0] sr    = 0;
    reg [31:0] lfsr1 = 32'hACE1BADD;
    reg [31:0] lfsr2 = 32'h13579BDF;
    reg [31:0] crc   = 32'hFFFFFFFF;
    reg [5:0]  bc    = 0;

    wire fb1 = lfsr1[31] ^ lfsr1[21] ^ lfsr1[1]  ^ lfsr1[0];
    wire fb2 = lfsr2[31] ^ lfsr2[28] ^ lfsr2[19] ^ lfsr2[0];

    function [31:0] crc_step;
        input [31:0] c;
        input        b;
        begin
            if (c[31] ^ b)
                crc_step = {c[30:0], 1'b0} ^ 32'h04C11DB7;
            else
                crc_step = {c[30:0], 1'b0};
        end
    endfunction

    // Сигналы для hash
    reg        hash_go = 0;
    reg [31:0] hash_input = 0;
    wire [31:0] hash_result;
    wire        hash_done;

    avalanche_hash u_hash (
        .clk(clk), .rst(rst),
        .in(hash_input),
        .in_valid(hash_go),
        .out(hash_result),
        .out_valid(hash_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            sr    <= 0;
            lfsr1 <= 32'hACE1BADD;
            lfsr2 <= 32'h13579BDF;
            crc   <= 32'hFFFFFFFF;
            bc    <= 0;
            random_out <= 0;
            ready <= 0;
            hash_go <= 0;
            hash_input <= 0;
        end else begin
            ready <= 0;
            hash_go <= 0;
            
            lfsr1 <= {lfsr1[30:0], fb1};
            lfsr2 <= {lfsr2[30:0], fb2};

            // Hash результат готов через 2 такта
            if (hash_done) begin
                random_out <= hash_result;
                ready <= 1;
            end
            
            if (bits_valid) begin
                sr <= {sr[28:0], bits_in};
                
                crc <= crc_step(
                           crc_step(
                               crc_step(crc, bits_in[2]),
                               bits_in[1]),
                           bits_in[0]);
                
                if (bc >= 6'd30) begin
                    hash_input <= {sr[28:0], bits_in} ^ lfsr1 ^ lfsr2 ^ crc;
                    hash_go <= 1;
                    bc <= 0;
                end else begin
                    bc <= bc + 3;
                end
            end
        end
    end
endmodule

//============================================================================
// AVALANCHE HASH (Robert Jenkins integer hash)
//============================================================================
module avalanche_hash (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] in,
    input  wire        in_valid,
    output reg  [31:0] out,
    output reg         out_valid
);
    // Stage 1: 3 операции (1 такт)
    wire [31:0] a1 = in + ~(in << 15);    // key += ~(key << 15)
    wire [31:0] a2 = a1 ^ (a1 >> 10);     // key ^= (key >> 10)
    wire [31:0] a3 = a2 + (a2 << 3);      // key += (key << 3)

    reg [31:0] pipe1;
    reg        pipe1_valid;

    always @(posedge clk) begin
        if (rst) begin
            pipe1       <= 0;
            pipe1_valid <= 0;
        end else begin
            pipe1       <= a3;
            pipe1_valid <= in_valid;
        end
    end

    // Stage 2: 3 операции (1 такт)
    wire [31:0] b1 = pipe1 ^ (pipe1 >> 6);    // key ^= (key >> 6)
    wire [31:0] b2 = b1 + ~(b1 << 11);        // key += ~(key << 11)
    wire [31:0] b3 = b2 ^ (b2 >> 16);         // key ^= (key >> 16)

    always @(posedge clk) begin
        if (rst) begin
            out       <= 0;
            out_valid <= 0;
        end else begin
            out       <= b3;
            out_valid <= pipe1_valid;
        end
    end
endmodule
//============================================================================
// 7-SEGMENT DRIVER
//============================================================================
module seven_seg_driver (
    input  wire        clk, rst,
    input  wire [31:0] data,
    output reg  [6:0]  seg,
    output reg  [7:0]  an
);
    reg [19:0] rc = 0;
    wire [2:0] ds = rc[19:17];
    reg [3:0] hd;
    always @(posedge clk) begin
        if (rst) rc<=0; else rc<=rc+1;
    end
    always @(*) begin
        case(ds)
            0: begin an=8'b11111110; hd=data[3:0];   end
            1: begin an=8'b11111101; hd=data[7:4];   end
            2: begin an=8'b11111011; hd=data[11:8];  end
            3: begin an=8'b11110111; hd=data[15:12]; end
            4: begin an=8'b11101111; hd=data[19:16]; end
            5: begin an=8'b11011111; hd=data[23:20]; end
            6: begin an=8'b10111111; hd=data[27:24]; end
            7: begin an=8'b01111111; hd=data[31:28]; end
            default: begin an=8'b11111111; hd=0; end
        endcase
    end
    always @(*) begin
        case(hd)
            0:seg=7'b1000000; 1:seg=7'b1111001; 2:seg=7'b0100100; 3:seg=7'b0110000;
            4:seg=7'b0011001; 5:seg=7'b0010010; 6:seg=7'b0000010; 7:seg=7'b1111000;
            8:seg=7'b0000000; 9:seg=7'b0010000;10:seg=7'b0001000;11:seg=7'b0000011;
           12:seg=7'b1000110;13:seg=7'b0100001;14:seg=7'b0000110;15:seg=7'b0001110;
            default:seg=7'b1111111;
        endcase
    end
endmodule