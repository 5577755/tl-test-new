// Sparse replacement for the generated mem_ext blackbox.
//
// The original mem_ext.v declares a flat 128M x 256-bit (4GB) reg array which
// exceeds the VCS elaboration limit (2GB - 1). Trace replay only touches a
// small fraction of the address space, so an associative array reproduces the
// Verilator zero-initialized behavior exactly: unwritten entries read as 0 and
// partial byte writes start from an all-zero base.
module mem_ext(
  input RW0_clk,
  input [26:0] RW0_addr,
  input RW0_en,
  input RW0_wmode,
  input [31:0] RW0_wmask,
  input [255:0] RW0_wdata,
  output [255:0] RW0_rdata
);

  reg reg_RW0_ren;
  reg [26:0] reg_RW0_addr;
  reg [255:0] ram [bit [26:0]];

  reg [255:0] wdata_full;
  integer i;

  always @(posedge RW0_clk)
    reg_RW0_ren <= RW0_en && !RW0_wmode;
  always @(posedge RW0_clk)
    if (RW0_en && !RW0_wmode) reg_RW0_addr <= RW0_addr;
  always @(posedge RW0_clk)
    if (RW0_en && RW0_wmode) begin
      wdata_full = ram.exists(RW0_addr) ? ram[RW0_addr] : 256'b0;
      for (i = 0; i < 32; i = i + 1) begin
        if (RW0_wmask[i]) begin
          wdata_full[i*8 +: 8] = RW0_wdata[i*8 +: 8];
        end
      end
      ram[RW0_addr] <= wdata_full;
    end

  function [255:0] ram_read(input [26:0] a);
    ram_read = ram.exists(a) ? ram[a] : 256'b0;
  endfunction

  assign RW0_rdata = ram_read(reg_RW0_addr);

endmodule
