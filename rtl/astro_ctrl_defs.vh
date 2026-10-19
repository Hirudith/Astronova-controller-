// astro_ctrl_defs.vh -- shared constants for the Astronova protection controller.
// Keep in sync with python/astronova/regs.py (the Python side is checked against
// the RTL by the co-simulation in tb/tb_cosim.v).

`ifndef ASTRO_CTRL_DEFS_VH
`define ASTRO_CTRL_DEFS_VH

// ---------------------------------------------------------------------------
// Identification
// ---------------------------------------------------------------------------
`define ASTRO_ID        32'h4153_5452   // "ASTR"
`define ASTRO_VER_MAJOR 8'd1
`define ASTRO_VER_MINOR 8'd0

// ---------------------------------------------------------------------------
// Register map: word addresses (byte offset = 4 * word address).
// Words 0x00-0x1F live in the TMR core; 0x20-0x3F are the unprotected
// diagnostic counters (astro_ctrl_diag).
// ---------------------------------------------------------------------------
`define A_ID        6'h00   // 0x00 RO  identification
`define A_VERSION   6'h01   // 0x04 RO  {8'h0, tmr_build, major, minor}
`define A_CTRL      6'h02   // 0x08 RW  [0] fb_hold [1] static_en [3:2] static_mode
`define A_CMD       6'h03   // 0x0C WO  [0] clear_fault [1] soft_reset [2] clear_diag
`define A_STATUS    6'h04   // 0x10 RO  see docs/SPEC.md
`define A_TSTAT     6'h05   // 0x14 RO  [15:0] metric [23:16] last_seq [24] have_seq [28:25] last_reject
`define A_AGE       6'h06   // 0x18 RO  ticks since last accepted telemetry
`define A_DWELL     6'h07   // 0x1C RO  ticks since last completed switch
`define A_TDATA     6'h08   // 0x20 RW  telemetry staging word
`define A_TCRC      6'h09   // 0x24 WO  [7:0] CRC-8 of TDATA; write commits the message
`define A_PRESCALE  6'h0A   // 0x28 RW  [23:0] clock cycles per tick minus one (write restarts the period)
`define A_FRESH_TO  6'h0B   // 0x2C RW  staleness limit in ticks (0 = disabled)
`define A_DWELL_UP  6'h0C   // 0x30 RW  min ticks since last switch before escalating
`define A_DWELL_DN  6'h0D   // 0x34 RW  min ticks since last switch before de-escalating
`define A_SW_TO     6'h0E   // 0x38 RW  handshake watchdog in cycles (0 = disabled)
`define A_TH_ELEV   6'h0F   // 0x3C RW  [15:0] rise [31:16] fall  (NORMAL <-> ELEVATED)
`define A_TH_EXTR   6'h10   // 0x40 RW  [15:0] rise [31:16] fall  (ELEVATED <-> EXTREME)
`define A_MODE_MAP  6'h11   // 0x44 RW  [1:0] NORMAL [3:2] ELEVATED [5:4] EXTREME [7:6] FALLBACK
`define A_LIMITS    6'h12   // 0x48 RW  [7:0] invalid_limit [15:8] recover_n [19:16] retry_max
`define A_RTCNT     6'h13   // 0x4C RO  [7:0] invalid_cnt [15:8] recover_cnt [19:16] fail_cnt
`define A_WD        6'h14   // 0x50 RO  handshake watchdog count (cycles)

// ---------------------------------------------------------------------------
// FSM encoding
// ---------------------------------------------------------------------------
`define S_INIT  3'd0   // resynchronise with payload: wait sw_ack low, adopt pl_mode
`define S_IDLE  3'd1   // steady: evaluate desired mode, start switches
`define S_REQ   3'd2   // sw_req high, waiting for sw_ack
`define S_REL   3'd3   // sw_req low, waiting for sw_ack to drop
`define S_FAULT 3'd4   // payload unresponsive after retry_max failures

// Threat levels
`define LV_NORMAL   2'd0
`define LV_ELEVATED 2'd1
`define LV_EXTREME  2'd2

// Protection modes (numerically ordered by protection strength)
`define M_BASELINE  2'd0
`define M_PARTIAL   2'd1   // optional intermediate mode (DMR / partial TMR), decision D5
`define M_TMR       2'd2
`define M_TMR_PLUS  2'd3   // optional, e.g. TMR + faster scrub

// Telemetry reject reasons (bit mask)
`define RJ_CRC  0
`define RJ_RSVD 1
`define RJ_SRC  2
`define RJ_SEQ  3

// Event vector bit positions (core -> diag counters)
`define EV_ACCEPT    0
`define EV_REJECT    1
`define EV_FB_ENTER  2
`define EV_FB_EXIT   3
`define EV_SW_START  4
`define EV_SW_DONE   5
`define EV_SW_FAIL   6
`define EV_MISMATCH  7
`define EV_ILLEGAL   8
`define NEV          9

// Diagnostic counters (astro_ctrl_diag, outside the TMR boundary).
// Word 0x20 + e counts event e above; the rest follow.
`define A_DIAG_BASE  6'h20  // 0x80..0xA0 event counters (ACCEPT..ILLEGAL)
`define A_LAST_LAT   6'h29  // 0xA4 cycles sw_req was high in the last completed switch
`define A_MAX_LAT    6'h2A  // 0xA8 maximum of the above since clear
`define A_TMR_ERR    6'h2B  // 0xAC cycles with a replica disagreement
`define A_CYCLE_LO   6'h2C  // 0xB0 free-running cycle counter (64 bit)
`define A_CYCLE_HI   6'h2D  // 0xB4
`define A_STICKY     6'h2E  // 0xB8 [0] tmr_err seen [1] fault seen [2] illegal seen

// Width of the packed core state vector (see astro_ctrl_core.v)
//   config  : 4+24+32+32+32+32+16+16+16+16+8+8+8+4          = 248
//   dynamic : 3+24+32+32+32+16+8+1+2+8+8+1+2+2+4+4+32       = 211
`define ASTRO_ST_W 459

// Width of the packed core output vector:
//   {events[NEV-1:0], busy, fault, fallback, level[1:0], mode_cmd[1:0], sw_target[1:0], sw_req}
`define ASTRO_OUT_W (`NEV + 10)

`endif
