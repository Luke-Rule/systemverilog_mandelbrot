/* ----------------------------------------------------------
**   
**
**   Algorithmic level model of Drawing engine
**
**   Drawing engine module: Mandelbrot: fixed point Q3.29
**
**   Luke Rule
**
---------------------------------------------------------- */
#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <vector>
#include <fstream>
#include <stdlib.h>
#include <stddef.h>
#include <iostream>
#include <sstream>
#include <iomanip> 
#include <string>

#define XSIZE 640
#define YSIZE 480
// Difference between point positions at zoom level 10
#define BASE_INCREMENT_AMOUNT 0x00000fa0
// Q3.29 format
#define FRAC_BITS 29

// Macros to extract RGB components from RGB565 colour
#define RED(colour)   ((colour >> 11) & 0x1F)
#define GREEN(colour) ((colour >> 5) & 0x3F)
#define BLUE(colour)  (colour & 0x1F)

// Type definitions for reading clarity
using fixed_64 = int64_t;
using fixed_32 = int32_t;
using unsigned_fixed_32 = uint32_t;
using unsigned_fixed_64 = uint64_t;
using colour = uint16_t;

struct coord_step {
  fixed_32 x;
  fixed_32 y;
  fixed_32 step;
};

// Function to spread colour indices more evenly across the colour map
int get_spread_colour_index(int iterations, int max_iterations) {
  if (max_iterations < 16) {
    return iterations;
  }
  int spread_value = iterations * ((max_iterations >> 4) - (max_iterations >> 5) - (max_iterations >> 6) - (max_iterations >> 10));
  if (spread_value < max_iterations) {
    return spread_value;
  }
  else {
    return max_iterations - 1;
  }
}

// taking in 6 interpolation points, generate all unique colours between them
void generate_unique_colours(std::vector<colour>& unique_colours, std::vector<colour>& interp_points) {
  for (int i = 0; i < 5; i++) {
    // get start and end colours for this segment
    colour colour_start = interp_points.at(i);
    colour colour_end = interp_points.at(i + 1);

    // extract RGB components
    uint16_t r = RED(colour_start);
    uint16_t g = GREEN(colour_start);
    uint16_t b = BLUE(colour_start);
    
    // determine interpolation direction for each component
    int b_inc = (BLUE(colour_end) - BLUE(colour_start)) > 0 ? 1 : -1;
    int g_inc = (GREEN(colour_end) - GREEN(colour_start)) > 0 ? 1 : -1;
    int r_inc = (RED(colour_end) - RED(colour_start)) > 0 ? 1 : -1;

    // add the start colour (this means no divide by zero issues later)
    unique_colours.push_back(colour_start);
    // interpolate until we reach the end colour, adding that too
    while (colour_start != colour_end) {
      // increment each component if not at the end value
      // for a smooth gradient they must all be incremented at once, if possible
      if (r != RED(colour_end)) {
        r += r_inc;
      }
      if (g != GREEN(colour_end)) {
        g += g_inc;
      }
      if (b != BLUE(colour_end)) {
        b += b_inc;
      }

      // recombine into RGB565 format
      colour_start = (r << 11) | (g << 5) | b;
      unique_colours.push_back(colour_start);
    }
  }
}

void generate_colour_map(int max_iterations, std::vector<colour>& unique_colours, std::vector<colour>& colour_map) {
  int colour_index = 0;
  // calculate the best way to evenly sample the unique colours to fill the colour map
  // if we need to miss out some unique colours
  if (unique_colours.size() > max_iterations) {
    int step_size = int(unique_colours.size() / max_iterations);
    for (int i = 0; i < max_iterations; i++) {
      // add colour for every iteration
      colour_map.push_back(unique_colours.at(colour_index));
      // increment colour index by maximum amount to not exceed max iterations
      colour_index += step_size;
    }
  }
  // if we need to repeat some unique colours
  else {
    // get the max step size to fill the colour map evenly without exceeding unique colours size
    int step_size = std::ceil(double(max_iterations) / double(unique_colours.size()));
    for (int i = 0; i < max_iterations; i++) {
      // add colour for every iteration
      colour_map.push_back(unique_colours.at(colour_index));
      // if at step size, increment colour index
      if ((i + 1) % step_size == 0) {
        colour_index++;
      }
    }
  }
}

// fixed point multiplication function for Q3.29 format
fixed_64 fixed_mult(fixed_64 a, fixed_64 b)
{
  return ((a * b) >> FRAC_BITS);
}

void drawMandelbrot(fixed_32 x_fixed, fixed_32 y_fixed, fixed_32 inc_fixed, int max_iterations, colour framebuffer[YSIZE][XSIZE], std::vector<colour>& colour_map) {
  fixed_32 x_start = x_fixed;
  for (int y = 0; y < YSIZE; y++){   
    for (int x = 0; x < XSIZE; x++) {
      int iterations = 0;
      fixed_64 zr = 0; 
      fixed_64 zi = 0;
      unsigned_fixed_64 modulus_sq = 0;

      // iterate mandelbrot equation until modulus > 2 or max iterations reached
      while ((modulus_sq <= (4ULL << FRAC_BITS)) && (iterations < max_iterations)) {
        modulus_sq = fixed_mult(zr,zr) + fixed_mult(zi,zi);
        // temp to not overwrite zr before calculating zi
        fixed_64 temp = fixed_mult(zr,zr) - fixed_mult(zi,zi) + x_fixed;
        zi = (fixed_mult(zr,zi) << 1) + y_fixed;
        zr = temp;
        iterations++;
      }
      
      // get colour from colour map based on iterations
      if (iterations < max_iterations){
        framebuffer[y][x] = colour_map.at(get_spread_colour_index(iterations, max_iterations));
      }
      else{
        framebuffer[y][x] = 0;
      }

      x_fixed += inc_fixed;
    }
    y_fixed -= inc_fixed;
    x_fixed = x_start;
  }
}

// debug function to write image file in PPM format
void write_ppm_file(const std::string& filename, colour framebuffer[YSIZE][XSIZE])
{
  std::ofstream ofs;
  ofs.open(filename, std::ios::out | std::ios::binary);
  ofs << "P6\n" << XSIZE << " " << YSIZE << "\n255\n";
  for (int y = 0; y < YSIZE; y++) {
    for (int x = 0; x < XSIZE; x++) {
      uint8_t r = RED(framebuffer[y][x]) << 3;
      uint8_t g = GREEN(framebuffer[y][x]) << 2;
      uint8_t b = BLUE(framebuffer[y][x]) << 3;
      ofs << r << g << b;
    }
  }
  ofs.close();
}

// function to write framebuffer values to text file for test comparison
void write_framebuffer_file(const std::string& filename, colour framebuffer[YSIZE][XSIZE])
{
    std::ofstream ofs(filename);
    if (!ofs.is_open()) {
        return;
    }

    for (int y = 0; y < YSIZE; y++) {
        for (int x = 0; x < XSIZE; x++) {
            ofs << x << " " << y << " 0x" 
                << std::hex << std::setw(4) << std::setfill('0') << framebuffer[y][x] 
                << std::dec << "\n";
        }
    }
}

// calculate the top-left coordinates and step size based on center coords and zoom level
coord_step center_coords(fixed_32 center_x, fixed_32 center_y, int zoom) {
  coord_step c;
  if (zoom > 10) {
    zoom = 0; // as unsigned in verilog
  }
  else if (zoom < 0) {
    zoom = 0;
  }
  fixed_32 step_size = BASE_INCREMENT_AMOUNT * (1 << (10 - zoom));
  c.x = center_x - (XSIZE >> 1) * step_size;
  c.y = center_y + (YSIZE >> 1) * step_size;
  c.step = step_size;
  return c;
}

int main()
{
  // remove old output files
  system("rm -f images/*");
  system("rm -f output_files/*");
  
  // get test cases
  std::ifstream input("/home/p74644lr/Questa/COMP32211/src/Phase_2/input_file.txt");
  std::string line;
  int file_count = 0;

  while (std::getline(input, line)) {
    // get test case parameters
    fixed_64 center_x, center_y;
    int zoom, max_iterations;
    int ignore;
    colour c1, c2, c3, c4, c5, c6;
    std::istringstream iss(line);
    iss >> std::hex >> center_x >> center_y >> std::dec >> zoom >> max_iterations;
    iss >> std::hex >> c1 >> c2 >> c3 >> c4 >> c5 >> c6 >> std::dec;
    iss >> ignore;
    if (max_iterations <= 0) {
      max_iterations = 1;
    }
    if (max_iterations > 1023) {
      max_iterations = 1; // as unsigned in verilog
    }
    std::vector<colour> unique_colours = {};
    std::vector<colour> colour_map = {};
    std::vector<colour> interp_points = {c1, c2, c3, c4, c5, c6};

    // generate colour map
    generate_unique_colours(unique_colours, interp_points);
    generate_colour_map(max_iterations, unique_colours, colour_map);

    // initialize framebuffer to grey to better see uninitialized pixels
    colour framebuffer[YSIZE][XSIZE];
    for (int y = 0; y < YSIZE; y++) {
      for (int x = 0; x < XSIZE; x++) {
          framebuffer[y][x] = 0x7BEF;   // grey in RGB565
      }
    }
    // calculate top-left coords and step size
    coord_step c = center_coords(center_x, center_y, zoom);
    // draw mandelbrot set
    drawMandelbrot(c.x, c.y, c.step, max_iterations, framebuffer, colour_map);
    
    // write output files
    std::string image = std::string("images/") + std::to_string(file_count) + std::string("_framestore_golden.ppm");
    write_ppm_file(image,framebuffer);
    std::string values = std::string("/home/p74644lr/Questa/COMP32211/src/Phase_2/output_files/output_file_") + std::to_string(file_count) + std::string(".txt");
    write_framebuffer_file(values,framebuffer);

    file_count++;
  }
}
