`timescale 1ns / 1ps

module tb_main;
    reg clk = 0;
    reg rst = 1;
    reg mic_data = 0;

    wire mic_clk, mic_lrsel;
    wire [6:0] seg;
    wire [7:0] an;
    wire [15:0] led;

    top_module uut (
        .CLK100MHZ(clk), .BTNC(rst), .M_DATA(mic_data),
        .M_CLK(mic_clk), .M_LRSEL(mic_lrsel),
        .seg(seg), .an(an), .LED(led)
    );

    always #5 clk = ~clk;

    // PDM имитация
    reg [31:0] lfsr = 32'hDEADBEEF;
    reg mp = 0;
    always @(posedge clk) begin
        mp <= mic_clk;
        if (mic_clk != mp) begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            mic_data <= lfsr[0] ^ lfsr[7] ^ lfsr[15] ^ lfsr[23];
        end
    end

    // Счётчики
    integer log_file;
    integer num_count = 0;
    integer pcm_count = 0;
    integer spec_count = 0;
    integer ent_count = 0;

    // ЛОКАЛЬНЫЕ копии сигналов для записи
    reg [31:0] captured_random;
    reg captured_valid;

    initial begin
        log_file = $fopen("random_output.txt", "w");
        if (log_file == 0) begin
            $display("ERROR: Cannot open random_output.txt for writing!");
            $finish;
        end
        $display("File opened successfully");
    end

    // Захват сигналов из UUT в локальные регистры
    always @(posedge clk) begin
        captured_valid <= uut.random_ready;
        if (uut.random_ready) begin
            captured_random <= uut.random_num;
        end
    end

    always @(posedge clk) begin
        if (!rst && captured_valid) begin
            num_count = num_count + 1;
            
            $fdisplay(log_file, "%08X", captured_random);
            $fflush(log_file); 
            
            $display("[%0t] *** RANDOM #%0d: %08X ***", $time, num_count, captured_random);
        end
    end

    // Мониторинг остальных сигналов
    always @(posedge clk) begin
        if (!rst) begin
            if (uut.pcm_left_valid) begin
                pcm_count = pcm_count + 1;
                if (pcm_count <= 3)
                    $display("[%0t] PCM#%0d L=%04X", $time, pcm_count, uut.pcm_left);
                if (pcm_count == 64)
                    $display("[%0t] 64 PCM - buffer full", $time);
            end
            
            if (uut.spectrum_valid) begin
                spec_count = spec_count + 1;
                if (spec_count <= 5 || spec_count % 50 == 0)
                    $display("[%0t] SPEC#%0d 5k=%04X 9k=%04X 13k=%04X",
                             $time, spec_count, uut.amp_5k_l, uut.amp_9k_l, uut.amp_13k_l);
            end
            
            if (uut.entropy_valid) begin
                ent_count = ent_count + 1;
                if (ent_count <= 10 || ent_count % 100 == 0)
                    $display("[%0t] ENT#%0d bits=%03b", $time, ent_count, uut.entropy_bits);
            end
        end
    end

    initial begin
        $display("==========================================");
        $display(" PRNG Testbench - 5000 ms RUN");
        $display("==========================================");
        
        rst = 1;
        repeat (200) @(posedge clk);
        rst = 0;
        $display("[%0t] Reset released", $time);

        repeat (50) begin
            #100_000_000;  // 100 ms
            $display("[%0t] Status: pcm=%0d spec=%0d ent=%0d rnd=%0d",
                     $time, pcm_count, spec_count, ent_count, num_count);
        end

        $display("");
        $display("==========================================");
        $display(" FINAL RESULTS:");
        $display("   PCM samples:     %0d", pcm_count);
        $display("   Spectrum blocks: %0d", spec_count);
        $display("   Entropy events:  %0d", ent_count);
        $display("   Random numbers:  %0d", num_count);
        $display("==========================================");
        
        $fclose(log_file);
        $display("File closed, exiting...");
        
        $finish;
    end
endmodule