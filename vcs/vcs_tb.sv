// tl-test-new DPI Guest Mode testbench for the HBL2 matrix TestTop.
//
// Drives the same TileLink cycle as the Verilator host-mode main loop
// (main/V3/v3_main.cpp), but through the DPI-C interface exported by
// libtltest_dpi.so (see main/DPI/tilelink_dpi.cpp for the protocol):
//
//   TileLinkSystemInitialize()
//   [ per cycle, at negedge: Tick -> Push A,B,C,E,D -> Tock -> Pull A,B,C,E,D ]
//   TileLinkSystemFinalize() when TileLinkSystemIsAlive() returns 0
//
// Device ids follow the static PortGen order (main/build/portgen.cpp):
//   0 = L1D  TLC  port master_port_0_0     (channels A/B/C/D/E)
//   1 = L1I  TLUL port master_ul_port_0_0_0 (channels A/D)
//   2 = Matrix TLM port master_m_port_0_0_0 (channels A/D + user_matrix)

`timescale 1ns/1ps

`include "coupledL2_dpi.svh"

module tltest_vcs_tb;

  localparam int DEV_L1D   = 0;
  localparam int DEV_L1I   = 1;
  localparam int DEV_MATRIX = 2;

  // Matrix user fields of Channel A are not part of the generic DPI
  // signature; they are exported by the extra entry in libtltest_dpi.so.
  import "DPI-C" function void TileLinkMatrixPullChannelAUser(
    input   int   device_id,
    output  byte  matrix,
    output  byte  ameIndex
  );

  // Matrix data-return channel (matrixDataOut_*): a Decoupled 512-bit output
  // beside the TileLink channels, consumed by the C++ MAgent. Without the
  // ready feedback the DUT-side queue backs up and the matrix unit stalls.
  import "DPI-C" function void TileLinkMatrixPushChannelM(
    input   int     device_id,
    input   byte    valid,
    input   longint source,
    input   longint data0,
    input   longint data1,
    input   longint data2,
    input   longint data3,
    input   longint data4,
    input   longint data5,
    input   longint data6,
    input   longint data7
  );

  import "DPI-C" function void TileLinkMatrixPullChannelMReady(
    input   int   device_id,
    output  byte  ready
  );

  // =====================================================================
  // Clock / reset / misc DUT inputs
  // =====================================================================
  logic        clock;
  logic        reset;
  logic [63:0] timer;
  logic        logEnable;
  logic        clean;
  logic        dump;

  longint unsigned sim_time;

  // =====================================================================
  // Device 0: L1D TileLink-C port (master_port_0_0), all 5 channels
  // =====================================================================
  wire  p0_a_ready;
  logic p0_a_valid;
  logic [3:0]   p0_a_opcode;
  logic [2:0]   p0_a_param;
  logic [2:0]   p0_a_size;
  logic [4:0]   p0_a_source;
  logic [31:0]  p0_a_address;
  logic         p0_a_needHint;
  logic [1:0]   p0_a_alias;
  logic [31:0]  p0_a_mask;
  logic [255:0] p0_a_data;
  logic         p0_a_corrupt;

  logic         p0_b_ready;
  wire          p0_b_valid;
  wire  [2:0]   p0_b_opcode;
  wire  [1:0]   p0_b_param;
  wire  [2:0]   p0_b_size;
  wire  [4:0]   p0_b_source;
  wire  [31:0]  p0_b_address;
  wire  [31:0]  p0_b_mask;
  wire  [255:0] p0_b_data;
  wire          p0_b_corrupt;

  wire  p0_c_ready;
  logic p0_c_valid;
  logic [2:0]   p0_c_opcode;
  logic [2:0]   p0_c_param;
  logic [2:0]   p0_c_size;
  logic [4:0]   p0_c_source;
  logic [31:0]  p0_c_address;
  logic [255:0] p0_c_data;
  logic         p0_c_corrupt;

  logic         p0_d_ready;
  wire          p0_d_valid;
  wire  [3:0]   p0_d_opcode;
  wire  [1:0]   p0_d_param;
  wire  [2:0]   p0_d_size;
  wire  [4:0]   p0_d_source;
  wire  [7:0]   p0_d_sink;
  wire          p0_d_denied;
  wire  [255:0] p0_d_data;
  wire          p0_d_corrupt;

  wire  p0_e_ready;
  logic p0_e_valid;
  logic [7:0]   p0_e_sink;

  // =====================================================================
  // Device 1: L1I TileLink-UL port (master_ul_port_0_0_0), channels A/D
  // =====================================================================
  wire  p1_a_ready;
  logic p1_a_valid;
  logic [3:0]   p1_a_opcode;
  logic [2:0]   p1_a_param;
  logic [2:0]   p1_a_size;
  logic [4:0]   p1_a_source;
  logic [31:0]  p1_a_address;
  logic [31:0]  p1_a_mask;
  logic [255:0] p1_a_data;
  logic         p1_a_corrupt;

  logic         p1_d_ready;
  wire          p1_d_valid;
  wire  [3:0]   p1_d_opcode;
  wire  [1:0]   p1_d_param;
  wire  [2:0]   p1_d_size;
  wire  [4:0]   p1_d_source;
  wire  [7:0]   p1_d_sink;
  wire          p1_d_denied;
  wire  [255:0] p1_d_data;
  wire          p1_d_corrupt;

  // =====================================================================
  // Device 2: Matrix TileLink port (master_m_port_0_0_0), channels A/D
  // =====================================================================
  wire  p2_a_ready;
  logic p2_a_valid;
  logic [3:0]   p2_a_opcode;
  logic [2:0]   p2_a_param;
  logic [2:0]   p2_a_size;
  logic [4:0]   p2_a_source;
  logic [31:0]  p2_a_address;
  logic [6:0]   p2_a_ameIndex;
  logic [1:0]   p2_a_matrix;
  logic [31:0]  p2_a_mask;
  logic [255:0] p2_a_data;
  logic         p2_a_corrupt;

  logic         p2_d_ready;
  wire          p2_d_valid;
  wire  [3:0]   p2_d_opcode;
  wire  [1:0]   p2_d_param;
  wire  [2:0]   p2_d_size;
  wire  [4:0]   p2_d_source;
  wire  [7:0]   p2_d_sink;
  wire          p2_d_denied;
  wire  [255:0] p2_d_data;
  wire          p2_d_corrupt;

  // L2 -> Matrix data return path. In the current TestTop build this
  // channel never fires (matrix read data returns on channel D), matching
  // the Verilator host mode where the PortGen leaves it undriven/unobserved.
  logic         mdat_ready;
  wire          mdat_valid;
  wire  [6:0]   mdat_sourceId;
  wire  [511:0] mdat_data;
  wire  [2:0]   mdat_channel;

  // =====================================================================
  // DUT
  // =====================================================================
  TestTop dut (
    .clock                               (clock),
    .reset                               (reset),
    .timer                               (timer),
    .logEnable                           (logEnable),
    .clean                               (clean),
    .dump                                (dump),
    // L1D (device 0)
    .master_port_0_0_a_ready             (p0_a_ready),
    .master_port_0_0_a_valid             (p0_a_valid),
    .master_port_0_0_a_bits_opcode       (p0_a_opcode),
    .master_port_0_0_a_bits_param        (p0_a_param),
    .master_port_0_0_a_bits_size         (p0_a_size),
    .master_port_0_0_a_bits_source       (p0_a_source),
    .master_port_0_0_a_bits_address      (p0_a_address),
    .master_port_0_0_a_bits_user_needHint(p0_a_needHint),
    .master_port_0_0_a_bits_user_alias   (p0_a_alias),
    .master_port_0_0_a_bits_mask         (p0_a_mask),
    .master_port_0_0_a_bits_data         (p0_a_data),
    .master_port_0_0_a_bits_corrupt      (p0_a_corrupt),
    .master_port_0_0_b_ready             (p0_b_ready),
    .master_port_0_0_b_valid             (p0_b_valid),
    .master_port_0_0_b_bits_opcode       (p0_b_opcode),
    .master_port_0_0_b_bits_param        (p0_b_param),
    .master_port_0_0_b_bits_size         (p0_b_size),
    .master_port_0_0_b_bits_source       (p0_b_source),
    .master_port_0_0_b_bits_address      (p0_b_address),
    .master_port_0_0_b_bits_mask         (p0_b_mask),
    .master_port_0_0_b_bits_data         (p0_b_data),
    .master_port_0_0_b_bits_corrupt      (p0_b_corrupt),
    .master_port_0_0_c_ready             (p0_c_ready),
    .master_port_0_0_c_valid             (p0_c_valid),
    .master_port_0_0_c_bits_opcode       (p0_c_opcode),
    .master_port_0_0_c_bits_param        (p0_c_param),
    .master_port_0_0_c_bits_size         (p0_c_size),
    .master_port_0_0_c_bits_source       (p0_c_source),
    .master_port_0_0_c_bits_address      (p0_c_address),
    .master_port_0_0_c_bits_user_needHint(1'b0),
    .master_port_0_0_c_bits_user_alias   (1'b0),
    .master_port_0_0_c_bits_data         (p0_c_data),
    .master_port_0_0_c_bits_corrupt      (p0_c_corrupt),
    .master_port_0_0_d_ready             (p0_d_ready),
    .master_port_0_0_d_valid             (p0_d_valid),
    .master_port_0_0_d_bits_opcode       (p0_d_opcode),
    .master_port_0_0_d_bits_param        (p0_d_param),
    .master_port_0_0_d_bits_size         (p0_d_size),
    .master_port_0_0_d_bits_source       (p0_d_source),
    .master_port_0_0_d_bits_sink         (p0_d_sink),
    .master_port_0_0_d_bits_denied       (p0_d_denied),
    .master_port_0_0_d_bits_data         (p0_d_data),
    .master_port_0_0_d_bits_corrupt      (p0_d_corrupt),
    .master_port_0_0_e_ready             (p0_e_ready),
    .master_port_0_0_e_valid             (p0_e_valid),
    .master_port_0_0_e_bits_sink         (p0_e_sink),
    // L1I (device 1)
    .master_ul_port_0_0_0_a_ready        (p1_a_ready),
    .master_ul_port_0_0_0_a_valid        (p1_a_valid),
    .master_ul_port_0_0_0_a_bits_opcode  (p1_a_opcode),
    .master_ul_port_0_0_0_a_bits_param   (p1_a_param),
    .master_ul_port_0_0_0_a_bits_size    (p1_a_size),
    .master_ul_port_0_0_0_a_bits_source  (p1_a_source),
    .master_ul_port_0_0_0_a_bits_address (p1_a_address),
    .master_ul_port_0_0_0_a_bits_mask    (p1_a_mask),
    .master_ul_port_0_0_0_a_bits_data    (p1_a_data),
    .master_ul_port_0_0_0_a_bits_corrupt (p1_a_corrupt),
    .master_ul_port_0_0_0_d_ready        (p1_d_ready),
    .master_ul_port_0_0_0_d_valid        (p1_d_valid),
    .master_ul_port_0_0_0_d_bits_opcode  (p1_d_opcode),
    .master_ul_port_0_0_0_d_bits_param   (p1_d_param),
    .master_ul_port_0_0_0_d_bits_size    (p1_d_size),
    .master_ul_port_0_0_0_d_bits_source  (p1_d_source),
    .master_ul_port_0_0_0_d_bits_sink    (p1_d_sink),
    .master_ul_port_0_0_0_d_bits_denied  (p1_d_denied),
    .master_ul_port_0_0_0_d_bits_data    (p1_d_data),
    .master_ul_port_0_0_0_d_bits_corrupt (p1_d_corrupt),
    // Matrix (device 2)
    .master_m_port_0_0_0_a_ready         (p2_a_ready),
    .master_m_port_0_0_0_a_valid         (p2_a_valid),
    .master_m_port_0_0_0_a_bits_opcode   (p2_a_opcode),
    .master_m_port_0_0_0_a_bits_param    (p2_a_param),
    .master_m_port_0_0_0_a_bits_size     (p2_a_size),
    .master_m_port_0_0_0_a_bits_source   (p2_a_source),
    .master_m_port_0_0_0_a_bits_address  (p2_a_address),
    .master_m_port_0_0_0_a_bits_user_AmeIndex(p2_a_ameIndex),
    .master_m_port_0_0_0_a_bits_user_matrix  (p2_a_matrix),
    .master_m_port_0_0_0_a_bits_mask     (p2_a_mask),
    .master_m_port_0_0_0_a_bits_data     (p2_a_data),
    .master_m_port_0_0_0_a_bits_corrupt  (p2_a_corrupt),
    .master_m_port_0_0_0_d_ready         (p2_d_ready),
    .master_m_port_0_0_0_d_valid         (p2_d_valid),
    .master_m_port_0_0_0_d_bits_opcode   (p2_d_opcode),
    .master_m_port_0_0_0_d_bits_param    (p2_d_param),
    .master_m_port_0_0_0_d_bits_size     (p2_d_size),
    .master_m_port_0_0_0_d_bits_source   (p2_d_source),
    .master_m_port_0_0_0_d_bits_sink     (p2_d_sink),
    .master_m_port_0_0_0_d_bits_denied   (p2_d_denied),
    .master_m_port_0_0_0_d_bits_data     (p2_d_data),
    .master_m_port_0_0_0_d_bits_corrupt  (p2_d_corrupt),
    // Matrix data return (left quiescent, see note above)
    .matrixDataOut_0_0_ready             (mdat_ready),
    .matrixDataOut_0_0_valid             (mdat_valid),
    .matrixDataOut_0_0_bits_sourceId     (mdat_sourceId),
    .matrixDataOut_0_0_bits_data_data    (mdat_data),
    .matrixDataOut_0_0_bits_channel      (mdat_channel)
  );

  always #5 clock = ~clock;

  // =====================================================================
  // Reset & initialization (mirrors v3_main: 10 reset cycles, then the
  // tl-test subsystem is already initialized before the first TileLink
  // cycle; sim_time counts two steps per cycle like the Verilator time)
  // =====================================================================
  initial begin
    clock     = 1'b0;
    reset     = 1'b1;
    timer     = 64'b0;
    logEnable = 1'b0;
    clean     = 1'b0;
    dump      = 1'b0;
    mdat_ready = 1'b0;
    sim_time  = 0;

    // quiesce DUT inputs before the first DPI cycle
    p0_a_valid = 0; p0_a_opcode = 0; p0_a_param = 0; p0_a_size = 0;
    p0_a_source = 0; p0_a_address = 0; p0_a_needHint = 0; p0_a_alias = 0;
    p0_a_mask = 0; p0_a_data = 0; p0_a_corrupt = 0;
    p0_b_ready = 0;
    p0_c_valid = 0; p0_c_opcode = 0; p0_c_param = 0; p0_c_size = 0;
    p0_c_source = 0; p0_c_address = 0; p0_c_data = 0; p0_c_corrupt = 0;
    p0_d_ready = 0;
    p0_e_valid = 0; p0_e_sink = 0;
    p1_a_valid = 0; p1_a_opcode = 0; p1_a_param = 0; p1_a_size = 0;
    p1_a_source = 0; p1_a_address = 0; p1_a_mask = 0; p1_a_data = 0; p1_a_corrupt = 0;
    p1_d_ready = 0;
    p2_a_valid = 0; p2_a_opcode = 0; p2_a_param = 0; p2_a_size = 0;
    p2_a_source = 0; p2_a_address = 0; p2_a_ameIndex = 0; p2_a_matrix = 0;
    p2_a_mask = 0; p2_a_data = 0; p2_a_corrupt = 0;
    p2_d_ready = 0;

    TileLinkSystemInitialize();

    repeat (10) @(negedge clock);
    #1 reset = 1'b0;
    sim_time = 20;
  end

  // =====================================================================
  // Per-cycle DPI exchange, channel order A -> B -> C -> E -> D as
  // required by main/DPI/tilelink_dpi.cpp
  // =====================================================================

  // scratch holders matching the Sv* wrapper widths
  logic         pu_valid;
  logic [3:0]   pu_a_opcode;
  logic [2:0]   pu_param;
  logic [2:0]   pu_size;
  logic [63:0]  pu_source;
  logic [47:0]  pu_address;
  logic         pu_needHint;
  logic [35:0]  pu_vaddr;
  logic [1:0]   pu_alias;
  logic [31:0]  pu_mask;
  logic [255:0] pu_data;
  logic         pu_corrupt;
  logic [63:0]  pu_sink;
  byte          pu_matrix;
  byte          pu_ameIndex;
  byte          pu_m_ready;

  always @(negedge clock) begin
    if (!reset) begin
      #1ps;

      // ---- Tick ----
      TileLinkSystemTick(sim_time);

      // ---- Push valid+bits (DUT outputs -> tl-test) ----
      // Registered DUT outputs: their post-posedge values are exactly what
      // fired at the preceding posedge, so sampling here (still with the
      // previous cycle's inputs applied) matches v3_main's PushB/PushD.
      SvTileLinkPushChannelB(DEV_L1D, 1'b1, p0_b_valid, p0_b_opcode, p0_b_param,
                             p0_b_size, {{59{1'b0}}, p0_b_source},
                             {{16{1'b0}}, p0_b_address}, p0_b_mask, p0_b_data, p0_b_corrupt);
      SvTileLinkPushChannelD(DEV_L1D, 1'b1, p0_d_valid, p0_d_opcode, p0_d_param,
                             p0_d_size, {{59{1'b0}}, p0_d_source},
                             {{56{1'b0}}, p0_d_sink}, p0_d_denied, p0_d_data, p0_d_corrupt);

      SvTileLinkPushChannelD(DEV_L1I, 1'b1, p1_d_valid, p1_d_opcode, p1_d_param,
                             p1_d_size, {{59{1'b0}}, p1_d_source},
                             {{56{1'b0}}, p1_d_sink}, p1_d_denied, p1_d_data, p1_d_corrupt);

      SvTileLinkPushChannelD(DEV_MATRIX, 1'b1, p2_d_valid, p2_d_opcode, p2_d_param,
                             p2_d_size, {{59{1'b0}}, p2_d_source},
                             {{56{1'b0}}, p2_d_sink}, p2_d_denied, p2_d_data, p2_d_corrupt);
      TileLinkMatrixPushChannelM(DEV_MATRIX, mdat_valid,
                                 {{57{1'b0}}, mdat_sourceId},
                                 mdat_data[63:0],   mdat_data[127:64], mdat_data[191:128],
                                 mdat_data[255:192],mdat_data[319:256],mdat_data[383:320],
                                 mdat_data[447:384],mdat_data[511:448]);

      // ---- Tock ----
      // Fires beats of the preceding posedge, using the ready values pushed
      // at the END of the previous cycle (see below) — like v3_main, whose
      // Tock reads the A/C/E ready sampled after Tock of the prior iteration.
      TileLinkSystemTock();

      // ---- Pull (tl-test -> DUT inputs) ----
      SvTileLinkPullChannelA(DEV_L1D, 1'b1, p0_a_valid, p0_a_opcode, p0_a_param,
                             p0_a_size, pu_source, pu_address, pu_needHint, pu_vaddr,
                             pu_alias, p0_a_mask, p0_a_data, p0_a_corrupt);
      p0_a_source  <= pu_source[4:0];
      p0_a_address <= pu_address[31:0];
      p0_a_alias   <= pu_alias;

      SvTileLinkPullChannelB(DEV_L1D, 1'b1, p0_b_ready);

      SvTileLinkPullChannelC(DEV_L1D, 1'b1, p0_c_valid, p0_c_opcode, p0_c_param,
                             p0_c_size, pu_source, pu_address, pu_needHint, pu_vaddr,
                             pu_alias, p0_c_data, p0_c_corrupt);
      p0_c_source  <= pu_source[4:0];
      p0_c_address <= pu_address[31:0];

      SvTileLinkPullChannelE(DEV_L1D, 1'b1, p0_e_valid, pu_sink);
      p0_e_sink <= pu_sink[7:0];

      SvTileLinkPullChannelD(DEV_L1D, 1'b1, p0_d_ready);

      SvTileLinkPullChannelA(DEV_L1I, 1'b1, p1_a_valid, p1_a_opcode, p1_a_param,
                             p1_a_size, pu_source, pu_address, pu_needHint, pu_vaddr,
                             pu_alias, p1_a_mask, p1_a_data, p1_a_corrupt);
      p1_a_source  <= pu_source[4:0];
      p1_a_address <= pu_address[31:0];

      SvTileLinkPullChannelD(DEV_L1I, 1'b1, p1_d_ready);

      SvTileLinkPullChannelA(DEV_MATRIX, 1'b1, p2_a_valid, p2_a_opcode, p2_a_param,
                             p2_a_size, pu_source, pu_address, pu_needHint, pu_vaddr,
                             pu_alias, p2_a_mask, p2_a_data, p2_a_corrupt);
      p2_a_source  <= pu_source[4:0];
      p2_a_address <= pu_address[31:0];
      TileLinkMatrixPullChannelAUser(DEV_MATRIX, pu_matrix, pu_ameIndex);
      p2_a_matrix   <= pu_matrix[1:0];
      p2_a_ameIndex <= pu_ameIndex[6:0];

      SvTileLinkPullChannelD(DEV_MATRIX, 1'b1, p2_d_ready);
      TileLinkMatrixPullChannelMReady(DEV_MATRIX, pu_m_ready);
      mdat_ready <= pu_m_ready;

      // ---- Push readys (DUT outputs -> tl-test), late phase ----
      // The nonblocking assignments above land at the end of this timestep;
      // after one more delta the DUT's combinational ready outputs settle
      // with the NEW request applied. Sampling here gives exactly the ready
      // that will gate the request at the upcoming posedge — mirroring
      // v3_main's PushA/PushC/PushE placement (after Tock, before posedge).
      // The next Tock reads these values; sampling them any earlier desyncs
      // the C++ fire accounting whenever the DUT pulses a ready low.
      #1ps;
      SvTileLinkPushChannelA(DEV_L1D, 1'b1, p0_a_ready);
      SvTileLinkPushChannelC(DEV_L1D, 1'b1, p0_c_ready);
      SvTileLinkPushChannelE(DEV_L1D, 1'b1, p0_e_ready);

      SvTileLinkPushChannelA(DEV_L1I, 1'b1, p1_a_ready);

      SvTileLinkPushChannelA(DEV_MATRIX, 1'b1, p2_a_ready);

      // v3_main's build logs "Not passing ticking time to verilated TestTop":
      // the Verilator baseline never drives timer, so keep it at 0 here too.
      sim_time <= sim_time + 2;
    end
  end

  // =====================================================================
  // Debug waveform window: +vcd_start=<sim_time> +vcd_stop=<sim_time>
  // (compile with -debug_access+all). Dumps the full hierarchy only inside
  // the window so post-mortem analysis of a hang stays a manageable VCD.
  // =====================================================================
  longint unsigned vcd_start, vcd_stop;
  bit vcd_on;
  initial begin
    if (!$value$plusargs("vcd_start=%d", vcd_start)) vcd_start = '1;
    if (!$value$plusargs("vcd_stop=%d",  vcd_stop))  vcd_stop  = '1;
  end
  always @(negedge clock) begin
    if (!vcd_on && sim_time >= vcd_start && sim_time < vcd_stop) begin
      $vcdpluson(0, tltest_vcs_tb);
      vcd_on = 1'b1;
    end else if (vcd_on && sim_time >= vcd_stop) begin
      $vcdplusoff();
      vcd_on = 1'b0;
    end
  end

  // =====================================================================
  // Completion check, same criteria as the v3 main loop exit
  // =====================================================================
  always @(posedge clock) begin
    if (!reset) begin
      if ((sim_time % 10000) == 0)
        $display("[%0d] [tl-test-new] Simulation time elapsed: %0dps", sim_time, sim_time);

      if (TileLinkSystemIsAlive() == 0) begin
        if (TileLinkSystemIsFinished() != 0) begin
          $display("[%0d] [tl-test-new-FINAL] tl-test subsystem FINISHED.", sim_time);
          TileLinkSystemFinalize();
          $finish;
        end else begin
          TileLinkSystemFinalize();
          $fatal(1, "[%0d] [tl-test-new-FINAL] tl-test subsystem FAILED / no longer alive", sim_time);
        end
      end
    end
  end

endmodule
