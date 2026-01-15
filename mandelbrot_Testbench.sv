/******************************************************************************/
/* Module:   Testbench                                                        */
/* Modified: Deccmber 2025                                                    */
/* Author:   L Rule                                                           */
/*                                                                            */
/* Description:                                                               */
/*                                                                            */
/* Mandlebrot drawing unit testbench: gets commands from input file, checks   */
/* the framestore writes against expected output files, and checks protocol   */
/* correctness with assertions.                                               */
/*                                                                            */
/******************************************************************************/

`timescale 1ns / 10ps

module unit_Testbench ();

    `define CLOCK_PERIOD 10
    `define MAX_CYCLES 1000
    `define TPD 1
    `define SCREEN_WIDTH 640
    `define SCREEN_HEIGHT 480
    `define NUM_OF_PIXELS (`SCREEN_WIDTH * `SCREEN_HEIGHT)
    `define BYTES_PER_PIXEL 2
    `define FRAMESTORE_SIZE (`NUM_OF_PIXELS * `BYTES_PER_PIXEL)
    `define MAX_ITERATIONS 4096
    `define TIMEOUT (`NUM_OF_PIXELS * `MAX_ITERATIONS * 8)

    reg         clk;
    reg         reset;

    // Command interface
    reg         req;
    wire        ack;
    reg  [31:0] r0;
    reg  [31:0] r1;
    reg  [31:0] r2;
    reg  [31:0] r3;
    reg  [31:0] r4;
    reg  [31:0] r5;
    reg  [31:0] r6;
    reg  [31:0] r7;

    // Status outputs
    wire        busy;
    wire        done;

    // Framestore interface
    wire        de_req;
    reg         de_ack;
    wire [17:0] de_addr;
    wire  [3:0] de_nbyte;
    wire [31:0] de_data;
    wire        de_rnw;

    // Framestore data output
    wire [31:0] de_w_data;
    reg [31:0] de_r_data;

    // Display status input
    reg [17:0]  display_base;
    reg [1:0]   display_mode;
    reg [9:0]   display_height;
    reg [9:0]   display_width;

    // State holding assertion variables
    reg         req_been_set;
    reg         ack_been_set;
    reg         de_req_been_set;

    // Timeout variables
    int         waiting;
    int         waiting_counter;
    int         busy_wait_counter;

    // Data correctness assertion variables
    reg  [17:0] old_de_addr;
    reg   [3:0] old_de_nbyte;
    reg  [31:0] old_de_data;

    // Input and output files
    int         input_file;
    int         output_file;
    int         ppm_file;

    // File reading variables
    string      line;
    int         test_counter;

    // Test inputs
    reg [31:0]  x_input, y_input;
    reg [31:0]  zoom_input;
    reg [31:0]  max_iterations;
    reg [15:0]  c1, c2, c3, c4, c5, c6;
    int         ack_rate_input;

    // Test outputs
    reg [15:0]  x_pixel_output, y_pixel_output;
    reg [15:0]  colour_pixel_output;

    // Frame store buffers
    reg [7:0]  framestore_test    [`NUM_OF_PIXELS * `BYTES_PER_PIXEL];
    reg [7:0]  framestore_golden  [`NUM_OF_PIXELS * `BYTES_PER_PIXEL];
    reg        pixel_accurate;
    reg [15:0] pixel;

    // Error logging files
    int         protocol_error_file;
    int         pixel_error_file;

    event file_close_event;

    int ack_delay_counter;

    // mandelbrot Unit Under Test
    mandelbrot_generator UUT (
        .clk        (clk),
        .reset      (reset),
        .req        (req),
        .ack        (ack),
        .r0         (r0),
        .r1         (r1),
        .r2         (r2),
        .r3         (r3),
        .r4         (r4),
        .r5         (r5),
        .r6         (r6),
        .r7         (r7),
        .busy       (busy),
        .done       (done),
        .de_req     (de_req),
        .de_ack     (de_ack),
        .de_addr    (de_addr),
        .de_nbyte   (de_nbyte),
        .de_rnw     (de_rnw),
        .de_w_data   (de_w_data),
        .de_r_data   (de_r_data),
        .display_base   (display_base),
        .display_mode   (display_mode),
        .display_height (display_height),
        .display_width  (display_width)
    );


    initial begin
        // reset output files
        $system("rm /home/p74644lr/Questa/COMP32211/src/Phase_2/pixel_errors.txt");
        $system("rm /home/p74644lr/Questa/COMP32211/src/Phase_2/protocol_errors.txt");
        $system("rm /home/p74644lr/Questa/COMP32211/src/Phase_2/images/*.ppm");

        // open error files
        pixel_error_file = $fopen("/home/p74644lr/Questa/COMP32211/src/Phase_2/pixel_errors.txt", "w");
        if (pixel_error_file == 0) begin
            $error("Could not open pixel_error_file");
        end
        protocol_error_file = $fopen("/home/p74644lr/Questa/COMP32211/src/Phase_2/protocol_errors.txt", "w");
        if (protocol_error_file == 0) begin
            $error("Could not open protocol_error_file");
        end

        // Open file containing test inputs
        input_file = $fopen("/home/p74644lr/Questa/COMP32211/src/Phase_2/input_file.txt", "r");
        if (input_file == 0) begin
            $error("Could not open input_file");
        end

        @ (file_close_event);
        $fclose(input_file);
        $fclose(pixel_error_file);
        $fclose(protocol_error_file);
        $stop; // Tests complete
    end


    // Clock
    initial begin
        clk <= 1;
    end
    always begin
        #(`CLOCK_PERIOD / 2) clk <= !clk;
    end


    // Main test process
    initial begin
        display_base    <= 18'b0;
        display_mode    <= 2'b0;
        display_height  <= `SCREEN_HEIGHT;
        display_width   <= `SCREEN_WIDTH;
        de_r_data       <= 32'b0;
        de_ack          <= 1'b0;

        req <= 1'b0; // Ensure inactive from start
        repeat (4) @ (posedge clk); // Wait a bit before starting

        test_counter = 0;
        // Read in each test from file
        while (!$feof(input_file)) begin
            pixel_accurate = 1'b1;

            // Get test inputs from line
            line = "";
            $fgets(line, input_file);
            $sscanf(line, "%h %h %d %d %h %h %h %h %h %h %d",
                    x_input, y_input, zoom_input, max_iterations,
                    c1, c2, c3, c4, c5, c6,
                    ack_rate_input);

            // Clear the buffers
            for (int i = 0; i < `NUM_OF_PIXELS * `BYTES_PER_PIXEL; i = i + 1) begin
                framestore_test[i] = 8'hX;
            end
            for (int i = 0; i < `NUM_OF_PIXELS * `BYTES_PER_PIXEL; i = i + 1) begin
                framestore_golden[i] = 8'hX;
            end

            ack_delay_counter <= ack_rate_input; // Initialise delay for acknowledges
            test_drawing_command(x_input, y_input, zoom_input, max_iterations, c1, c2, c3, c4, c5, c6);

            // Open file containing the expected outputs for this test
            output_file = $fopen($sformatf("/home/p74644lr/Questa/COMP32211/src/Phase_2/output_files/output_file_%0d.txt", test_counter), "r");
            if (output_file == 0) begin
                $error("Could not open output_file");
            end

            // Copy expected outputs to golden framestore
            while (!$feof(output_file)) begin
                line = "";
                $fgets(line, output_file);
                $sscanf(line, "%d %d %h", x_pixel_output, y_pixel_output, colour_pixel_output);

                framestore_golden[(x_pixel_output + y_pixel_output * `SCREEN_WIDTH) * `BYTES_PER_PIXEL] = colour_pixel_output[7:0];
                framestore_golden[(x_pixel_output + y_pixel_output * `SCREEN_WIDTH) * `BYTES_PER_PIXEL + 1] = colour_pixel_output[15:8];
            end

            $fclose(output_file);

            // Separate test outputs in pixel error file
            $fwrite(pixel_error_file, "Test %0d:\n", test_counter);

            // Compare test framestore to golden framestore
            for (int i = 0; i < `NUM_OF_PIXELS; i = i + 1) begin
                if ({framestore_golden[i * `BYTES_PER_PIXEL + 1], framestore_golden[i * `BYTES_PER_PIXEL]} !== {framestore_test[i * `BYTES_PER_PIXEL + 1], framestore_test[i * `BYTES_PER_PIXEL]}) begin
                    pixel_accurate = 1'b0;
                    $fwrite(pixel_error_file, "Pixel mismatch at %0d, %0d. Expected: %0d, got: %0d\n",
                            (i / `BYTES_PER_PIXEL) % `SCREEN_WIDTH,
                            (i / `BYTES_PER_PIXEL) / `SCREEN_WIDTH,
                            {framestore_golden[i * `BYTES_PER_PIXEL + 1], framestore_golden[i * `BYTES_PER_PIXEL]},
                            {framestore_test[i * `BYTES_PER_PIXEL + 1], framestore_test[i * `BYTES_PER_PIXEL]}
                    );
                end
            end

            $fwrite(pixel_error_file, "\n\n");

            // if (!pixel_accurate) begin
                write_buffer_to_ppm($sformatf("/home/p74644lr/Questa/COMP32211/src/Phase_2/images/%0d_framestore_test.ppm", test_counter), framestore_test);
                write_buffer_to_ppm($sformatf("/home/p74644lr/Questa/COMP32211/src/Phase_2/images/%0d_framestore_golden.ppm", test_counter), framestore_golden);
            // end

            $display("Test %0d complete", test_counter); // For progress monitoring

            test_counter = test_counter + 1;

            repeat (4) @ (posedge clk); // Wait a bit before next test
        end
        
        // Try requesting while busy
        test_drawing_command(x_input, y_input, zoom_input, max_iterations, c1, c2, c3, c4, c5, c6, 1);
        $display("Test %0d complete", test_counter); 

        // Test reset while busy
        req <= 1'b0;
        while (!ack) begin
            @ (posedge clk);
        end
        req <= 1'b0;
        // let the unit start processing
        repeat (10) @ (posedge clk); // we could test reset from different points in processing, but that would be complex to do precisely, and very unlikely to be different.
        reset <= 1'b1;
        @ (posedge clk);
        reset <= 1'b0;
        repeat (10) @ (posedge clk); // allow some stabilisation time
        assert (!busy)
            else $fwrite(protocol_error_file, "Warning: busy still high after reset\n");
        
        -> file_close_event;
    end


    // Timeout checker
    initial begin
        waiting_counter <= 0;
        waiting <= 1'b0;
    end

    always @(posedge clk) begin
        if (waiting == 1'b1) begin
            waiting_counter <= waiting_counter + 1; // If we are currently waiting for the unit, increment the timer counter
            // If we exceed the timeout value, log the reason and and stop the simulation
            if (waiting_counter >= `TIMEOUT - 1) begin
                if (de_req_been_set) begin
                    $fwrite(protocol_error_file, "Warning: timeout reached while waiting for busy to go low after requesting\n");
                end
                else if (ack_been_set) begin
                    $fwrite(protocol_error_file, "Warning: timeout reached while waiting for de_req to be set\n");
                end
                else begin
                    $fwrite(protocol_error_file, "Warning: timeout reached while waiting for acknowledgement when unit not busy\n");
                end

                $stop;
            end
        end else begin
            waiting_counter <= 0; // reset counter if not waiting
        end
    end


    // Task to write a 16-bit RGB565 buffer to a PPM file for visual checking
    task write_buffer_to_ppm(
        input string filename,
        input reg [7:0] buffer [`NUM_OF_PIXELS * `BYTES_PER_PIXEL]
    );
        integer ppm_file;
        int r, g, b;
        begin
            ppm_file = $fopen(filename, "w");
            if (ppm_file == 0) begin
                $error("Could not open image file");
            end

            // Write PPM header
            $fwrite(ppm_file, "P3\n");
            $fwrite(ppm_file, "%0d %0d\n", `SCREEN_WIDTH, `SCREEN_HEIGHT);
            $fwrite(ppm_file, "255\n");

            for (int i = 0; i < `NUM_OF_PIXELS; i = i + 1) begin
                if (buffer[i * `BYTES_PER_PIXEL] === 8'hX || buffer[i * `BYTES_PER_PIXEL + 1] === 8'hX) begin
                    $fwrite(ppm_file, "128 128 128 ");
                    if ((`BYTES_PER_PIXEL * i + `BYTES_PER_PIXEL) % `SCREEN_WIDTH == 0) begin
                        $fwrite(ppm_file, "\n");
                    end
                    continue;
                end

                pixel = {buffer[i * `BYTES_PER_PIXEL + 1], buffer[i * `BYTES_PER_PIXEL]};
                // Convert RGB565 to RGB888
                r = (pixel[15:11] << 3); 
                g = (pixel[10:5] << 2);   
                b = (pixel[4:0] << 3);     

                $fwrite(ppm_file, "%0d %0d %0d ", r, g, b);

                if ((`BYTES_PER_PIXEL * i + `BYTES_PER_PIXEL) % `SCREEN_WIDTH == 0) begin
                    $fwrite(ppm_file, "\n");
                end
            end

            $fclose(ppm_file);
        end
    endtask


    // Task to request a line is drawn
    task test_drawing_command(
        input reg [31:0] x0,
        input reg [31:0] y0,
        input reg [31:0] zoom,
        input reg [31:0] max_iterations,
        input reg [15:0] colour1,
        input reg [15:0] colour2,
        input reg [15:0] colour3,
        input reg [15:0] colour4,
        input reg [15:0] colour5,
        input reg [15:0] colour6,
        input int      try_when_busy = 0
    );
        begin
            // Set up variables used to test
            req_been_set <= 1'b0;
            ack_been_set <= 1'b0;
            de_req_been_set <= 1'b0;
            old_de_addr <= 18'bx;
            old_de_nbyte <= 18'bx;
            old_de_data <= 18'bx;
            @(posedge clk) // Align all changes to clock
            reset <= 1'b1;
            @ (posedge clk) // Ensure reset is held for at least one clock cycle
            reset <= 1'b0;
            @ (posedge clk) // Ensure everything is reset fully

            // Set up drawing command inputs
            r0 <= x0;
            r1 <= y0;
            r2 <= zoom;
            r3 <= 0;
            r4 <= {colour2, colour1};
            r5 <= {colour4, colour3};
            r6 <= {colour6, colour5};
            r7 <= max_iterations;

            if (busy) begin
                // Wait for busy to go low
                // Using a longer timeout, as the unit could be busy legitimately, but could have an error for not unsetting busy
                busy_wait_counter <= 0;
                while (busy) begin  
                    busy_wait_counter <= busy_wait_counter + 1;
                    assert (busy_wait_counter < `TIMEOUT * 50)
                        else begin
                            $fwrite(protocol_error_file, "Warning: timeout reached while waiting for busy to go low before requesting\n");
                            $stop;
                        end

                    @(posedge clk);
                end
            end

            // Request drawing
            req <= 1'b1;
            req_been_set <= 1'b1;

            // Check for timeout while waiting for acknowledge
            waiting <= 1'b1;
            
            while (!ack) begin
                @ (posedge clk);
            end

            req <= 1'b0;
            waiting <= 1'b0; // No longer waiting for acknowledge
            ack_been_set <= 1'b1;

            // The unit should now be busy with the request
            assert (busy)
                else begin
                    $fwrite(protocol_error_file, "Warning: busy not raised with ack\n");
                end

            // Set a timeout limit on all further drawing by the unit (it being busy)
            waiting <= 1'b1;
            
            // Check request while busy is triggered after the current request
            if (try_when_busy) begin
                // Wait a few cycles to ensure we are well into processing
                repeat (4) @ (posedge clk);
                req <= 1'b1; // Try requesting again while busy
                
                for (int i = 0; i < `TIMEOUT; i = i + 1) begin
                    if (!busy) begin
                        break;
                    end
                    assert (!ack)
                        else begin
                            $fwrite(protocol_error_file, "Warning: ack received when requesting while busy\n");
                        end
                    @ (posedge clk);
                end

                // Reset for new request
                ack_been_set <= 1'b0; 
                de_req_been_set <= 1'b0;

                // Wait for acknowledge of the new request
                waiting <= 1'b1;
                while (!ack) begin
                    @ (posedge clk);
                end
                waiting <= 1'b0; // No longer waiting for acknowledge
            end
            else begin
                // Dont end task until request complete
                while (busy) begin
                    @ (posedge clk);
                end

                // No longer checking unit timeout for finishing request
                waiting <= 1'b0;
            end
        end
    endtask


    always @(posedge clk) begin
        if (de_req && !de_ack) begin
            // The unit should be busy if requesting a draw
            assert (busy)
                else begin
                    $fwrite(protocol_error_file, "Warning: de_req raised while not busy\n");
                end

            // Allow the acknowledge we send to be delayed (as it might in a real system), to check the unit is waiting for it
            if (ack_delay_counter > 0) begin
                if (ack_delay_counter == ack_rate_input) begin
                    // Save the pixels being drawn to compare until acknowledge
                    old_de_addr <= de_addr;
                    old_de_nbyte <= de_nbyte;
                    old_de_data <= de_w_data;
                end
                else begin
                    // Data should not be changed while requesting and waiting
                    assert (old_de_addr == de_addr && old_de_nbyte == de_nbyte && old_de_data == de_w_data)
                        else begin 
                            $fwrite(protocol_error_file, "Warning: data changing before acknowledgement enabled and disabled, for address %h\n", de_addr);
                        end
                end
                ack_delay_counter <= ack_delay_counter - 1;
            end
            else begin
                // If there is no delay on the ack, these will not have been set
                if (ack_rate_input != 0) begin
                    // Data should not be changed while requesting and waiting
                    assert (old_de_addr == de_addr && old_de_nbyte == de_nbyte && old_de_data == de_w_data)
                        else begin 
                            $fwrite(protocol_error_file, "Warning: data changing before acknowledgement enabled and disabled, for address %h\n", de_addr);
                        end
                    ack_delay_counter <= ack_rate_input;
                end

                de_req_been_set <= 1'b1;

                // Set acknowledge
                de_ack <= 1'b1;

                // Write to frame buffer, word addressed (byte lanes indicated by active low de_nbyte bits)
                if (de_nbyte[0] == 0) begin
                    framestore_test[(de_addr << 2) + 0] <= de_w_data[7:0];
                end
                if (de_nbyte[1] == 0) begin
                    framestore_test[(de_addr << 2) + 1] <= de_w_data[15:8];
                end
                if (de_nbyte[2] == 0) begin
                    framestore_test[(de_addr << 2) + 2] <= de_w_data[23:16];
                end
                if (de_nbyte[3] == 0) begin
                    framestore_test[(de_addr << 2) + 3] <= de_w_data[31:24];
                end
            end
        end
        else if (de_ack) begin
            de_ack <= 1'b0;
        end
    end

    // Continuous assertions for protocol correctness
    assertAckOnlyOneCycleLong: assert property (@(posedge clk) (ack |-> ##1 !ack))
        else $fwrite(protocol_error_file, "Warning: ack should only be one clock cycle long\n");

    assertWaitForReq: assert property (@(posedge clk) (!req_been_set |-> (not $rose(ack) and not $rose(busy) and not $rose(de_req))))
        else $fwrite(protocol_error_file, "Warning: unit didnt wait for req\n");

endmodule
