/******************************************************************************/
/*                                                                            */
/*  Module:   mandelbrot_generator                                            */
/*  Modified: December 2025                                                   */
/*  Author:   L Rule                                                          */
/*                                                                            */
/*  Description:                                                              */
/*    Generates a Mandelbrot set image by calculating the                     */
/*    iteration counts for each pixel and mapping them to colours using a     */
/*    colour map generator, using fixed point arithmetic in Q3.29 format      */
/*                                                                            */
/******************************************************************************/
 
`timescale 1ns / 10ps 

`define MAX_ZOOM 10
`define BLACK         16'b00000000
// 10 bits
`define MAX_ITERATIONS 1023
`define MAX_ITERATION_BITS 9
// The xy diff between points at max zoom level
`define BASE_INCREMENT_AMOUNT 32'h00000fa0
// Macro to spread colours across iteration counts more evenly
`define MULT_ITERATIONS(iterations, max_iterations) (iterations * ((max_iterations >> 4) - (max_iterations >> 5) - (max_iterations >> 6) - (max_iterations >> 10)))
`define SPREAD_COLOURS(iterations, max_iterations) ((max_iterations < 16) ? iterations : ((`MULT_ITERATIONS(iterations, max_iterations) < max_iterations) ? `MULT_ITERATIONS(iterations, max_iterations) : (max_iterations - 1)))
// Macros to ensure valid zoom and max iteration values
`define GET_ZOOM(zoom) (`MAX_ZOOM - ((zoom > `MAX_ZOOM) ? 0 : zoom))
`define GET_MAX_ITERATIONS(max_iterations) ((max_iterations > `MAX_ITERATIONS) ? 1 : ((max_iterations < 1) ? 1 : max_iterations))
/* State enum for image generation*/
`define DRAW_STATE_IDLE 0
`define DRAW_STATE_SETUP 1
`define DRAW_STATE_REQUEST_COLOURS 2
`define DRAW_STATE_STORE_COLOURS 3
`define DRAW_STATE_CALCULATE_PIXELS 4
`define DRAW_STATE_GET_PIXEL_COLOUR 5
`define DRAW_STATE_SET_UP_DRAWING 6
`define DRAW_STATE_DRAW_PIXELS 7
`define DRAW_STATE_UPDATE_PIXELS 8
// Bytes to draw for pixel 1 and pixel 2
`define PIXEL_1_DRAW_BYTES 4'b1100
`define PIXEL_2_DRAW_BYTES 4'b0011

module mandelbrot_generator(
                 input  logic        clk,
                 input  logic        reset,
                                                      /* Interface to command */
                 input  logic        req,
                 output logic        ack,
                                                      /*  General arguments   */
                                                      /* Coordinates, fixed point 3 | 29 */
                 input  logic signed [31:0] r0,              // Start point - X coordinate
                 input  logic signed [31:0] r1,              // Start point - Y coordinate
                 input  logic [31:0] r2,              // Zoom - 0 to 10
                 input  logic [31:0] r3,              // Not used

                                                      /* Colours to use, 2 per register (5 6 5) */
                 input  logic [31:0] r4,              
                 input  logic [31:0] r5,              
                 input  logic [31:0] r6,

                 input  logic [31:0] r7,              // Limit on iterations - 1 to 1023

                                                      /*    Status outputs    */
                 output logic        busy,            
                 output logic        done,
                                                      /* Framestore interface */
                 output logic        de_req,          
                 input  logic        de_ack,
                 output logic [17:0] de_addr,
                 output logic  [3:0] de_nbyte,
                 output logic        de_rnw,
                 output logic [31:0] de_w_data,
                 input  logic [31:0] de_r_data,

                 input  logic [17:0] display_base,    /* Display status info. */
                 input  logic  [1:0] display_mode,    /*  *May* be used for   */
                 input  logic  [9:0] display_height,  /*  added flexibility.  */
                 input  logic  [9:0] display_width );

  // General settings variables
  reg[`MAX_ITERATION_BITS:0] max_iterations;
  reg[3:0] zoom;
  logic signed [31:0] step_size; // max zoom 10, so max step size is 0x000fa0 << 10 = 0x3e8000 - 22 bits

  // General state variables
  reg[3:0] drawing_state;
  logic colour_req_set;

  // Pixel variables
  reg[9:0] x_pixel_index;
  reg[8:0] y_pixel_index;
  logic boundary;

  // Mandelbrot point calculation instance (1 for now, 1 more can trivially be added later and drawn together)
  reg colour_1;
  logic signed [31:0] x_start_pos;
  logic signed [31:0] x_pos_1;
  logic signed [31:0] y_pos_1;
  logic[`MAX_ITERATION_BITS:0] iteration_count_1;
  logic mandelbrot_req_1;
  logic mandelbrot_ack_1;
  logic mandelbrot_busy_1;
  logic mandelbrot_done_1;
  logic mandelbrot_req_set_1;

  mandelbrot_point mandelbrot_point_1 (
                .clk(clk),
                .reset(reset),
                .req(mandelbrot_req_1),
                .ack(mandelbrot_ack_1),
                .x(x_pos_1),
                .y(y_pos_1),
                // trap to valid range
                .max_iterations(`GET_MAX_ITERATIONS(r7)),
                .busy(mandelbrot_busy_1),
                .done(mandelbrot_done_1),
                .iteration_count_out(iteration_count_1)
  );

  // colour map generator instance
  logic colour_req;
  logic colour_ack;
  logic colour_busy;
  logic colour_done;
  logic outputting_colour_values;
  logic [`MAX_ITERATION_BITS:0] colour_index_out; // max 1024 entries
  logic [15:0] colour_value_out;

  colour_map_generator colour_map_inst (
                .clk(clk),
                .reset(reset),
                .req(colour_req),
                .ack(colour_ack),
                .busy(colour_busy),
                .done(colour_done),
                .colours_12(r4),
                .colours_34(r5),
                .colours_56(r6),
                // trap to valid range
                .iterations(`GET_MAX_ITERATIONS(r7)),
                .outputting_colour_values(outputting_colour_values),
                .colour_index_out(colour_index_out),
                .colour_value_out(colour_value_out)
  );

  // colour map storage
  reg we_a;
  reg [`MAX_ITERATION_BITS:0] addr_a; // max 1024 entries
  reg [15:0] din_a;
  reg [15:0] dout_a;
  // 16 bits per colour, max 1024 entries
  reg [15:0] colour_map [0:`MAX_ITERATIONS-1];

  // colour map can be large so use synchronous RAM access
  always_ff @ (posedge clk) begin
    if (we_a) begin
      colour_map[addr_a] <= din_a;
    end

    dout_a <= colour_map[addr_a];
  end

  always_ff @ (posedge clk) begin
    if (reset) begin
      // synchronous reset - clear control signals
      drawing_state <= `DRAW_STATE_IDLE;
      busy <= 0;
      done <= 0;
      ack <= 0;
      mandelbrot_req_1 <= 0;
      colour_req <= 0;
      de_req <= 0;
      de_addr <= display_base;
      de_nbyte <= 4'b0000;
      de_rnw <= 1;
      de_w_data <= 32'b0;
      x_pixel_index <= 0;
      y_pixel_index <= 0;
      colour_1 <= 0;
      max_iterations <= 0;
      zoom <= 0;
      step_size <= 0;
      x_start_pos <= 0;
      x_pos_1 <= 0;
      y_pos_1 <= 0;
      we_a <= 0;
      boundary <= 1;
      colour_req_set <= 0;
      mandelbrot_req_set_1 <= 0;
    end
    else begin
      case (drawing_state)
        `DRAW_STATE_IDLE: begin
          // clear done signal after one cycle
          if (done) begin
            done <= 0;
          end

          // cannot be busy in this state, if request received, start processing
          if (req) begin
            busy <= 1;
            ack <= 1;

            // initialise general variables
            zoom <= `GET_ZOOM(r2);
            step_size <= `BASE_INCREMENT_AMOUNT * (1 << `GET_ZOOM(r2));
            max_iterations <= `GET_MAX_ITERATIONS(r7);
            de_addr <= display_base;
            x_pixel_index <= 0;
            y_pixel_index <= 0;
            boundary <= 1;
            colour_req_set <= 0;
            mandelbrot_req_set_1 <= 0;
            drawing_state <= `DRAW_STATE_SETUP;
          end
        end

        `DRAW_STATE_SETUP: begin
          // clear ack after one cycle
          ack <= 0;
          // initialise starting pixel positions
          x_pos_1     <= r0 - (display_width >> 1) * step_size;
          x_start_pos <= r0 - (display_width >> 1) * step_size;
          y_pos_1     <= r1 + (display_height >> 1) * step_size;
          drawing_state <= `DRAW_STATE_REQUEST_COLOURS;
        end

        `DRAW_STATE_REQUEST_COLOURS: begin
          // request colour map generation
          if (!colour_busy) begin
            colour_req <= 1;
            // set flag to indicate request has been made, so we use the results from this request
            colour_req_set <= 1;
          end
          // clear request after ack
          if (colour_req && colour_ack) begin
            colour_req <= 0;
          end
          // once done, move to storing colours
          if (colour_req_set && outputting_colour_values) begin
            colour_req_set <= 0;
            we_a <= 1;
            drawing_state <= `DRAW_STATE_STORE_COLOURS;
          end
        end

        `DRAW_STATE_STORE_COLOURS: begin
            // begin main drawing loop once all colours stored 
            if (colour_done) begin
              we_a <= 0;
              drawing_state <= `DRAW_STATE_CALCULATE_PIXELS;
            end
            else begin
              // store incoming colour values every cycle
              addr_a <= colour_index_out;
              din_a <= colour_value_out;
            end
        end

        `DRAW_STATE_CALCULATE_PIXELS: begin
          // request mandelbrot point calculation
          if (!mandelbrot_busy_1) begin
            mandelbrot_req_1 <= 1;
            // set flag to indicate request has been made, so we use the results from this request
            mandelbrot_req_set_1 <= 1;
          end
          // clear request after ack
          if (mandelbrot_req_1 && mandelbrot_ack_1) begin
            mandelbrot_req_1 <= 0;
          end
          // once done, get pixel colour
          if (mandelbrot_req_set_1 && mandelbrot_done_1) begin
            if (iteration_count_1 < max_iterations) begin
              // get colour from colour map
              addr_a <= `SPREAD_COLOURS(iteration_count_1, max_iterations);
              we_a <= 0;
              colour_1 <= 1;
            end 
            else begin
              // if point is in set, indicate not to use colour map (iteration count may be overwritten by the module)
              colour_1 <= 0;
            end

            mandelbrot_req_set_1 <= 0;
            drawing_state <= `DRAW_STATE_GET_PIXEL_COLOUR;
          end
        end

        // intermediate single cycle state to wait for colour map read, as data does not appear otherwise
        `DRAW_STATE_GET_PIXEL_COLOUR: begin
            drawing_state <= `DRAW_STATE_SET_UP_DRAWING;
        end

        `DRAW_STATE_SET_UP_DRAWING: begin
            // ensure we setup the correct pixel 
            if (boundary) begin
              // setup relevant data
              de_w_data[15:0] <= colour_1 ? dout_a : `BLACK;
              // select bytes to draw
              de_nbyte[3:0] <= `PIXEL_1_DRAW_BYTES;
            end
            else begin
              // setup relevant data
              de_w_data[31:16] <= colour_1 ? dout_a : `BLACK;
              // select bytes to draw
              de_nbyte[3:0] <= `PIXEL_2_DRAW_BYTES;
            end

            // write pixel data
            de_rnw <= 0;
            drawing_state <= `DRAW_STATE_DRAW_PIXELS;
        end

        `DRAW_STATE_DRAW_PIXELS: begin
          de_req <= 1;
          // once ack received, move to updating pixel positions
          if (de_req && de_ack) begin
            de_req <= 0;
            de_rnw <= 1;
            drawing_state <= `DRAW_STATE_UPDATE_PIXELS;
          end
        end

        `DRAW_STATE_UPDATE_PIXELS: begin
          // update which pixel in word we are drawing
          if (!boundary) begin
            // only increment address after both pixels in word drawn
            de_addr <= de_addr + 1;
            boundary <= 1;
          end
          else begin
            boundary <= 0;
          end

          // move to next x if not at end of row
          if (x_pixel_index < display_width - 1) begin
            x_pixel_index <= x_pixel_index + 1;
            x_pos_1 <= x_pos_1 + step_size;
            drawing_state <= `DRAW_STATE_CALCULATE_PIXELS;
          end
          else begin
            // move to next row
            x_pixel_index <= 0;
            x_pos_1 <= x_start_pos;
            if (y_pixel_index < display_height - 1) begin
              y_pixel_index <= y_pixel_index + 1;
              y_pos_1 <= y_pos_1 - step_size;
              // continue drawing
              drawing_state <= `DRAW_STATE_CALCULATE_PIXELS;
            end
            else begin
              // finished drawing entire image
              done <= 1;
              busy <= 0;
              // wait here for next request
              drawing_state <= `DRAW_STATE_IDLE;
            end
          end
        end

        default: begin
          drawing_state <= `DRAW_STATE_IDLE;
        end
      endcase
    end
  end

endmodule