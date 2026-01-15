/******************************************************************************/
/*                                                                            */
/*  Module:   mandelbrot_point                                                */
/*  Modified: December 2025                                                   */
/*  Author:   L Rule                                                          */
/*                                                                            */
/*  Description:                                                              */
/*    This module computes the number of iterations for a single point in     */
/*    the Mandelbrot set, using fixed point arithmetic in Q3.29 format.       */
/*                                                                            */
/******************************************************************************/
 
`timescale 1ns / 10ps 

`define MAX_ITERATION_BITS 9
`define FIXED_POINT_FRACTIONAL_BITS 29
// Fixed point multiplication macro for Q3.29 format, sign-extended to 64 bits as multiplication doubles bit-width
`define FIXED_POINT_MULTIPLY(a, b) (({{32{a[31]}}, a[31:0]} * {{32{b[31]}}, b[31:0]}) >>> `FIXED_POINT_FRACTIONAL_BITS)


module mandelbrot_point(
                 input  logic        clk,
                 input  logic        reset,
                                                      /* Interface to command */
                 input  logic        req,
                 output logic        ack,
                                                      /*  General arguments   */
                                                      /* Coordinates, fixed point 3 | 29 */
                 input  logic signed [31:0] x,        // Start point - X coordinate
                 input  logic signed [31:0] y,        // Start point - Y coordinate

                 input  logic [31:0] max_iterations,   // Limit on iterations

                                                      /*    Status outputs    */
                 output logic        busy,            
                 output logic        done,
                 output logic [`MAX_ITERATION_BITS:0]  iteration_count_out );

  // max is 1023, so 10 bits needed
  reg [9:0] iteration_count;
  // need 64 bits to enable holding intermediate multiplication values, which are doubled bit-width
  reg signed [63:0] z_imaginary;
  reg signed [63:0] z_real;
  reg [63:0] z_modulus_squared;


  always_ff @ (posedge clk) begin
    if (reset) begin
      // synchronous reset - clear control signals
      ack <= 0;
      busy <= 0;
      done <= 0;
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
        // initialise iteration variables
        iteration_count <= 0;
        z_imaginary <= 0;
        z_real <= 0;
        z_modulus_squared <= 0;
      end
      else if (busy) begin
        // only operating if busy
        // clear ack after one cycle
        if (ack) begin
          ack <= 0;
        end

        // check for escape condition: modulus > 2 or iteration limit reached
        if (z_modulus_squared > (32'd4 <<< `FIXED_POINT_FRACTIONAL_BITS) || (iteration_count >= max_iterations)) begin
          // finished so let controller know along with iteration count
          busy <= 0;
          done <= 1;
          iteration_count_out <= iteration_count;
        end
        else begin
          // perform iteration
          // |z| = z_real^2 + z_imaginary^2
          z_modulus_squared <= `FIXED_POINT_MULTIPLY(z_real, z_real) + `FIXED_POINT_MULTIPLY(z_imaginary, z_imaginary);
          // z_imaginary = 2 * z_real * z_imaginary + y
          z_imaginary <= (`FIXED_POINT_MULTIPLY(z_imaginary, z_real) << 1) + y;
          // z_real = z_real^2 - z_imaginary^2 + x
          z_real <= `FIXED_POINT_MULTIPLY(z_real, z_real) - `FIXED_POINT_MULTIPLY(z_imaginary, z_imaginary) + x;
          iteration_count <= iteration_count + 1;
        end
      end
    end
  end

endmodule
