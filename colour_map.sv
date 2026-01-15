/******************************************************************************/
/*                                                                            */
/*  Module:   colour_map                                                      */
/*  Modified: December 2025                                                   */
/*  Author:   L Rule                                                          */
/*                                                                            */
/*  Description:                                                              */
/*  Given 6 colours, interpolates all intermediate colours between them, and  */
/*  outputs a colour map of these evenly spaced, sized to max iterations      */
/******************************************************************************/
 
`timescale 1ns / 10ps 

`define MAX_ITERATIONS 1023
`define MAX_ITERATION_BITS 9
`define MAX_UNIQUE_COLOUR_BITS 7
// number of colour ranges defined
`define COLOUR_RANGES 5
// macros to extract RGB values from packed colour input
`define RED_VALUE(colour_input)   (colour_input[15:11])
`define GREEN_VALUE(colour_input) (colour_input[10:5])
`define BLUE_VALUE(colour_input)  (colour_input[4:0])
`define COLOUR_INC(colour_start, colour_end) (colour_end > colour_start ? 1 : ((colour_end < colour_start) ? -1 : 0))
// macro to get max iterations, ensuring at least 1
`define GET_MAX_ITERATIONS(max_iterations) ((max_iterations > `MAX_ITERATIONS) ? 1 : ((max_iterations < 1) ? 1 : max_iterations))
// states for generating colour map
`define STATE_HALT 0
`define STATE_CALCULATE_RANGES 1
`define STATE_INTERPOLATE_COLOURS 2
`define STATE_CALCULATE_STEP_DIRECTION 3
`define STATE_CALCULATE_STEP_SIZE_POSITIVE 4
`define STATE_CALCULATE_STEP_SIZE_NEGATIVE 5
`define STATE_OUTPUT_COLOURS 6

module colour_map_generator(
                input  logic        clk,
                input  logic        reset,
                input  logic        req,                          // Request to start generating colours
                output logic        ack,                          // Acknowledge request
                output logic        busy,                         // Busy generating colours
                output logic        done,                         // Done generating colours

                                                                /* Colours to use, 2 per register (5 6 5) */
                input  logic [31:0] colours_12,              
                input  logic [31:0] colours_34,              
                input  logic [31:0] colours_56,

                input  logic [31:0] iterations,  // Limit on iterations

                                                                /* Framestore interface */
                output logic outputting_colour_values,
                output logic [`MAX_ITERATION_BITS:0]  colour_index_out,
                output logic [15:0]  colour_value_out);

  reg [`MAX_ITERATION_BITS:0] max_iterations;

  // storage for unique colours between ranges
  reg [15:0] unique_colours [0:319];
  reg [15:0] all_colour_ranges [0:`COLOUR_RANGES];
  
  // control variables
  reg[2:0] drawing_state; 
  reg [`MAX_UNIQUE_COLOUR_BITS:0] unique_colour_index;
  reg [2:0] colour_range_counter;
  reg signed [`MAX_ITERATION_BITS:0] colour_step_size;
  reg[`MAX_ITERATION_BITS:0] colour_total_count;
  reg[`MAX_ITERATION_BITS:0] colour_fill_index;
  reg[`MAX_UNIQUE_COLOUR_BITS:0] current_colour_to_fill_index;
  // registers for colour state holding
  reg [4:0] red_1;
  reg [4:0] red_2;
  reg [5:0] green_1;
  reg [5:0] green_2;
  reg [4:0] blue_1;
  reg [4:0] blue_2;
  // increments for each colour channel
  int r_inc;
  int g_inc;
  int b_inc;

  always_ff @ (posedge clk) begin
    if (reset) begin
      // synchronous reset - clear control signals
      ack <= 0;
      busy <= 0;
      done <= 0;
      drawing_state <= `STATE_HALT;
      outputting_colour_values <= 0;
    end
    
    else begin
      // clear done signal after one cycle
      if (done) begin
        done <= 0;
      end

      // if not busy and request received, start processing
      if (!busy && req) begin
        ack <= 1;
        busy <= 1;
        done <= 0; 
        drawing_state <= `STATE_CALCULATE_RANGES;
        // initialise data variables
        all_colour_ranges[0] <= colours_12[15:0];
        all_colour_ranges[1] <= colours_12[31:16];
        all_colour_ranges[2] <= colours_34[15:0];
        all_colour_ranges[3] <= colours_34[31:16];
        all_colour_ranges[4] <= colours_56[15:0];
        all_colour_ranges[5] <= colours_56[31:16];
        max_iterations <= `GET_MAX_ITERATIONS(iterations);
        unique_colour_index <= 0;
        colour_range_counter <= 0;
        colour_total_count <= 0;
        colour_step_size <= 0;
        colour_fill_index <= 0;
        current_colour_to_fill_index <= 0;
      end
      
      // only operating if busy
      else if (busy) begin
        // clear ack after one cycle
        if (ack) begin
          ack <= 0;
        end

        case (drawing_state)
          `STATE_CALCULATE_RANGES: begin
            // if all ranges have been calculated, move to step direction calculation
            if (colour_range_counter >= `COLOUR_RANGES) begin
              drawing_state <= `STATE_CALCULATE_STEP_DIRECTION;
            end
            else begin
              // depending on the current range, get the start and end colours
              red_1 <= (`RED_VALUE(all_colour_ranges[colour_range_counter]));
              green_1 <= (`GREEN_VALUE(all_colour_ranges[colour_range_counter]));
              blue_1 <= (`BLUE_VALUE(all_colour_ranges[colour_range_counter]));
              red_2 <= (`RED_VALUE(all_colour_ranges[colour_range_counter + 1]));
              green_2 <= (`GREEN_VALUE(all_colour_ranges[colour_range_counter + 1]));
              blue_2 <= (`BLUE_VALUE(all_colour_ranges[colour_range_counter + 1]));
              // calculate increments between the two colours
              r_inc <= `COLOUR_INC(`RED_VALUE(all_colour_ranges[colour_range_counter]), `RED_VALUE(all_colour_ranges[colour_range_counter + 1]));
              g_inc <= `COLOUR_INC(`GREEN_VALUE(all_colour_ranges[colour_range_counter]), `GREEN_VALUE(all_colour_ranges[colour_range_counter + 1]));
              b_inc <= `COLOUR_INC(`BLUE_VALUE(all_colour_ranges[colour_range_counter]), `BLUE_VALUE(all_colour_ranges[colour_range_counter + 1]));
              // move to interpolating between them
              drawing_state <= `STATE_INTERPOLATE_COLOURS;
            end
          end
          `STATE_INTERPOLATE_COLOURS: begin
            // store the start colour
            unique_colours[unique_colour_index] <= {red_1, green_1, blue_1};
            unique_colour_index <= unique_colour_index + 1;
            // if reached the end colour, move to next range
            if (red_1 == red_2 && green_1 == green_2 && blue_1 == blue_2) begin
              colour_range_counter <= colour_range_counter + 1;
              drawing_state <= `STATE_CALCULATE_RANGES;
            end
            // otherwise, increment towards the end colour
            else begin 
              // for a smooth transition all channels are incremented each time, if possible
              if (red_1 != red_2) begin
                red_1 <= red_1 + r_inc;
              end
              if (green_1 != green_2) begin
                green_1 <= green_1 + g_inc;
              end
              if (blue_1 != blue_2) begin
                blue_1 <= blue_1 + b_inc;
              end
            end
          end
          // as very unlikely that unique colours size will match max iterations, calculate step size for filling
          `STATE_CALCULATE_STEP_DIRECTION: begin
            // determine whether to repeat or skip through unique colours based on whether there are more unique colours than max iterations
            if (unique_colour_index > max_iterations) begin
              // hold this decision in the sign of the step size
              // initialise to avoid zero step size
              colour_step_size <= -1;
              colour_total_count <= max_iterations;
              drawing_state <= `STATE_CALCULATE_STEP_SIZE_NEGATIVE;
            end else begin
              colour_step_size <= 1;
              colour_total_count <= unique_colour_index;
              drawing_state <= `STATE_CALCULATE_STEP_SIZE_POSITIVE;
            end
          end
          // calculate the maximum step size to evenly fill the colour map without exceeding max iterations
          `STATE_CALCULATE_STEP_SIZE_POSITIVE: begin
            // if we have a large enough step to fill the map, move to outputting colours
            if (colour_total_count >= max_iterations) begin
              outputting_colour_values <= 1;
              drawing_state <= `STATE_OUTPUT_COLOURS;
            end else begin
              // otherwise increase total count and step size
              colour_total_count <= colour_total_count + unique_colour_index;
              colour_step_size <= colour_step_size + 1;
            end
          end
          // calculate the maximum step size to skip through unique colours without exceeding its size
          `STATE_CALCULATE_STEP_SIZE_NEGATIVE: begin
            // if adding another step would exceed unique colours, move to outputting colours
            if (colour_total_count + max_iterations >= unique_colour_index) begin
              outputting_colour_values <= 1;
              drawing_state <= `STATE_OUTPUT_COLOURS;
            end
            else begin
              // otherwise increase total count and (decrease) step size
              colour_total_count <= colour_total_count + max_iterations;
              colour_step_size <= colour_step_size - 1;
            end
          end
          // output the filled colour map one entry at a time to fill the controllers ram
          `STATE_OUTPUT_COLOURS: begin
            // if all entries have been output, finish
            if (colour_fill_index >= max_iterations) begin
              busy <= 0;
              done <= 1;
              drawing_state <= `STATE_HALT;
              outputting_colour_values <= 0;
            end
            else begin
              // output the next colour
              colour_index_out <= colour_fill_index;
              colour_value_out <= unique_colours[current_colour_to_fill_index];
              colour_fill_index <= colour_fill_index + 1;
              // determine the next colour based on step size
              if (colour_step_size < 0) begin
                // skip through unique colours
                current_colour_to_fill_index <= current_colour_to_fill_index - colour_step_size;
              end
              else begin
                // if we have filled enough of the current colour, move to the next one
                if (colour_fill_index + 1 == colour_step_size * (current_colour_to_fill_index + 1)) begin
                    current_colour_to_fill_index <= current_colour_to_fill_index + 1;
                end
              end
            end
          end
          
          default: begin
            drawing_state <= `STATE_HALT;
          end
        endcase
      end
    end
  end

endmodule
