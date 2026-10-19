# Astronova protection controller: specification (Block 3)

Version 1.0 of the RTL (`VERSION` register `0x0001_0100` for the TMR build).
All results in this document are validation level **V1** (model and
simulation). Nothing here has been run on the PYNQ-Z2 yet.

## 1. What it does

The controller is the "small, always-protected hardware block" of proposal
§5.4. It:

* receives threat telemetry from the PS (from the λ(t) traces or the alert
  timelines of Blocks 1–2) and checks every message for integrity, source quality
  and order;
* maps the telemetry metric to a threat level (NORMAL / ELEVATED / EXTREME),
  using separate rise and fall thresholds (hysteresis);
* chooses a protection mode for each level and commands the payload (Block 4)
  over a 4-phase handshake. A minimum dwell time applies before it changes mode
  again;
* falls back to a safe mode when telemetry is stale, invalid, or absent (power
  up, reset);
* watches the payload handshake, retries failed switches, and raises `fault` if
  the payload stays unresponsive;
* keeps all of its own state in TMR with voted feedback. It reports replica
  disagreements so that its own vulnerability can be measured.

```
            PS (Python)                         PL
  ┌───────────────────────┐   AXI4-Lite   ┌──────────────────────── astro_ctrl_axil ─────────────────────┐
  │ alert / λ(t) replay   │──────────────▶│ AXI adaptor ──wr/rd──▶ ┌── astro_ctrl_tmr (TMR boundary) ──┐ │
  │ AstroCtrl driver      │               │  (unprotected)          │ core0 ─▶ reg0 ─┐                  │ │
  └───────────────────────┘               │                         │ core1 ─▶ reg1 ─┼─▶ 3 voters ──┐   │ │   sw_req, sw_target
                                          │                         │ core2 ─▶ reg2 ─┘   (fed back) │   │─┼──────────────────▶ payload
                                          │                         │        output voter ◀─────────┘   │ │◀───────────────── (Block 4)
                                          │                         └────────────────────────────────────┘ │   sw_ack, pl_mode
                                          │ astro_ctrl_diag: counters, switch latency (unprotected)        │
                                          └─────────────────────────────────────────────────────────────────┘
```

## 2. Files

| File | Content |
|---|---|
| `rtl/astro_ctrl_defs.vh` | register map, encodings, state width |
| `rtl/astro_ctrl_core.v` | combinational next-state logic and read-back (one domain) |
| `rtl/astro_ctrl_tmr.v` | TMR boundary: 3 domains with voted feedback, or 1 (TMR=0) |
| `rtl/tmr_voter.v` | bitwise 2-of-3 majority voter |
| `rtl/astro_ctrl_diag.v` | event counters, switch latency, cycle counter (outside TMR) |
| `rtl/astro_ctrl_axil.v` | top level: AXI4-Lite slave and payload ports |
| `python/astronova/regs.py` | register map, CRC-8, telemetry framing |
| `python/astronova/model.py` | cycle-accurate reference model; `simulate_timeline` for Block 5 |
| `python/astronova/driver.py` | PYNQ driver (works on any `read/write` MMIO object) |

## 3. Ports (`astro_ctrl_axil`)

| Port | Dir | Meaning |
|---|---|---|
| `s_axi_*` | – | AXI4-Lite slave, 8-bit address, 32-bit data; full-word writes only (others get SLVERR) |
| `sw_req` | out | switch request (4-phase) |
| `sw_target[1:0]` | out | requested mode, stable while `sw_req` is high |
| `sw_ack` | in | payload: switch done (new mode running, state resynchronised) |
| `pl_mode[1:0]` | in | payload: mode it is actually running in, at all times |
| `mode_cmd[1:0]` | out | mode the controller currently commands |
| `threat_level[1:0]` | out | 0 NORMAL, 1 ELEVATED, 2 EXTREME |
| `fallback` | out | fail-safe active |
| `fault` | out | payload unresponsive after `retry_max` attempts (to IRQ) |
| `sw_window` | out | a switch is in progress (REQ or REL state); trigger for switch-window injection |
| `tmr_err` | out | the three state replicas disagree this cycle |

Modes are 2-bit codes ordered by protection strength: 0 BASELINE, 1 PARTIAL
(DMR / partial TMR), 2 TMR, 3 TMR_PLUS. A higher code counts as an
escalation. The payload decides what each code means; the controller only
needs the order.

## 4. Payload handshake

```
clk        _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
sw_req     ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\______________
sw_target  ====X  target (stable)      X=============
sw_ack     ______________________/‾‾‾‾‾‾‾‾‾‾‾\______
pl_mode    ==== old ============X target ============
                ^ switch window: payload reconfigures + resyncs ^ window closes
```

1. The controller raises `sw_req` only after a cycle with `sw_ack` low.
2. The payload switches, resynchronises its state, sets `pl_mode = sw_target`
   and raises `sw_ack`.
3. On `sw_ack` the controller checks `pl_mode == sw_target` (failure if not)
   and drops `sw_req`.
4. The payload drops `sw_ack`.

The protocol survives a reset on either side. After a reset the controller
waits in INIT until `sw_ack` is low, then adopts `pl_mode` as the current
mode. A payload that was mid-switch completes or abandons the switch and must
still drop `sw_ack` once `sw_req` is low.

`LAST_LAT` reports the number of cycles `sw_req` was high, including the cycle
in which the controller saw `sw_ack`. This is the measured switch latency for
RQ4.

## 5. Telemetry

The PS writes `TDATA`, then writes the CRC to `TCRC`; the `TCRC` write commits
the message.

| TDATA bits | Field |
|---|---|
| `[15:0]` | metric (default meaning: upset-rate enhancement ratio, Q8.8, 1.0 = `0x0100`) |
| `[23:16]` | sequence number |
| `[24]` | source OK (0 = the alert feed reports degraded or missing data) |
| `[31:25]` | reserved, must be 0 |

`TCRC[7:0]` = CRC-8/SMBUS (polynomial 0x07, init 0, MSB first) over the four
`TDATA` bytes, big-endian. Check value: `crc8("123456789") = 0xF4`.

A message is **rejected** if any of the following holds (several can be
reported in `TSTAT.last_reject` at once): CRC mismatch (bit 0), a reserved bit
set (bit 1), source not OK (bit 2), or a sequence number that is not 1…127
ahead of the last *accepted* one (bit 3). A gap in the sequence is allowed,
because dropped messages are normal. A rejected message changes nothing except
the reject counters, and it does **not** refresh the freshness age.

The metric's meaning belongs to the PS. For the alert-driven policies P2/P3,
encode the alert state as a metric (for example quiet = 1.0, warning = 2.0,
confirmed GLE = 5.0) and set the thresholds to match.

## 6. Decision logic

**Threat level.** The level is updated on every accepted message:

| From | Goes up when | Goes down when |
|---|---|---|
| NORMAL | `m ≥ ext_rise` → EXTREME; `m ≥ elev_rise` → ELEVATED | – |
| ELEVATED | `m ≥ ext_rise` → EXTREME | `m < elev_fall` → NORMAL |
| EXTREME | – | `m < ext_fall` → ELEVATED, or NORMAL if also `m < elev_fall` |

**Desired mode.** The desired mode is chosen in this priority order:

1. `CTRL.static_en` → `CTRL.static_mode`. This is the policy override for P0
   (static baseline) and P1 (static TMR) on the same bitstream; it ignores
   telemetry and fallback.
2. Fallback active → `MODE_MAP.fallback`, or the current mode if
   `CTRL.fb_hold` (decision D6).
3. Otherwise → `MODE_MAP[level]`.

**Dwell.** A switch is allowed when `DWELL` (ticks since the last completed
switch) ≥ `DWELL_UP` for an escalation or ≥ `DWELL_DN` for a de-escalation.
Fallback-driven and static-policy switches bypass the dwell. This bounds the
switch rate under a toggling input to at most two switches per `DWELL_DN`
(verified in T6).

**Fallback.** Fallback is entered when `AGE ≥ FRESH_TO` (stale) or when the
number of consecutive rejects reaches `INVALID_LIMIT`. It is left only after
`RECOVER_N` consecutive accepted messages, and only once neither condition
holds. The controller also starts in fallback after any reset.

**Time base.** One tick = `PRESCALE + 1` clock cycles. Writing `PRESCALE`
restarts the current period. `AGE` and `DWELL` count ticks and saturate.
`SW_TO` counts clock cycles. A value of 0 disables `FRESH_TO`, `SW_TO`,
`INVALID_LIMIT` and `RETRY_MAX`.

## 7. Mode-switch FSM

| State | Code | Outputs | Leaves when |
|---|---|---|---|
| INIT | 0 | `sw_req=0` | `sw_ack=0` → IDLE, adopting `cur_mode = pl_mode`; watchdog → failure |
| IDLE | 1 | `sw_req=0` | `pl_mode ≠ cur_mode` → REQ with target `cur_mode` (re-assert, counts MISMATCH); else desired ≠ current and allowed → REQ |
| REQ | 2 | `sw_req=1` | `sw_ack=1` and `pl_mode = target` → REL (switch done, dwell cleared); `sw_ack=1` with the wrong mode, or watchdog → failure |
| REL | 3 | `sw_req=0` | `sw_ack=0` → IDLE; watchdog → failure |
| FAULT | 4 | `sw_req=0`, `fault=1` | `CMD.clear_fault` → INIT |
| 5–7 | – | – | illegal: → INIT next cycle, counts ILLEGAL |

A **failure** increments the consecutive-failure count. When the count reaches
`RETRY_MAX` the FSM goes to FAULT; otherwise it goes to INIT, which
resynchronises with the payload and retries. A completed switch clears the
count.

## 8. Register map

Byte offsets. RW registers are part of the protected state.

| Off | Name | Access | Reset | Bits |
|---|---|---|---|---|
| 0x00 | ID | RO | `0x41535452` | "ASTR" |
| 0x04 | VERSION | RO | `0x0001_0100` | `[23:16]` TMR build, `[15:8]` major, `[7:0]` minor |
| 0x08 | CTRL | RW | 0 | `[0]` fb_hold (D6), `[1]` static_en, `[3:2]` static_mode |
| 0x0C | CMD | WO | – | `[0]` clear_fault, `[1]` soft_reset (dynamic state only; config kept), `[2]` clear_diag |
| 0x10 | STATUS | RO | – | `[2:0]` fsm, `[4:3]` level, `[6:5]` mode_cmd, `[8:7]` target, `[9]` fallback, `[10]` stale, `[11]` invalid, `[12]` fault, `[13]` busy, `[14]` sw_req, `[15]` sw_ack, `[17:16]` pl_mode, `[19:18]` desired |
| 0x14 | TSTAT | RO | – | `[15:0]` metric, `[23:16]` last seq, `[24]` have seq, `[28:25]` last reject reasons |
| 0x18 | AGE | RO | `0xFFFFFFFF` | ticks since last accepted message |
| 0x1C | DWELL | RO | `0xFFFFFFFF` | ticks since last completed switch |
| 0x20 | TDATA | RW | 0 | telemetry staging word |
| 0x24 | TCRC | WO | – | `[7:0]` CRC-8; write commits |
| 0x28 | PRESCALE | RW | 99 999 | `[23:0]` cycles per tick − 1 (1 ms at 100 MHz) |
| 0x2C | FRESH_TO | RW | 180 000 | ticks (3 min) |
| 0x30 | DWELL_UP | RW | 0 | ticks |
| 0x34 | DWELL_DN | RW | 600 000 | ticks (10 min) |
| 0x38 | SW_TO | RW | 10 000 000 | cycles (100 ms) |
| 0x3C | TH_ELEV | RW | `0x0140_0180` | `[15:0]` rise (1.5×), `[31:16]` fall (1.25×) |
| 0x40 | TH_EXTR | RW | `0x0300_0400` | `[15:0]` rise (4.0×), `[31:16]` fall (3.0×) |
| 0x44 | MODE_MAP | RW | `0xA8` | `[1:0]` NORMAL, `[3:2]` ELEVATED, `[5:4]` EXTREME, `[7:6]` FALLBACK |
| 0x48 | LIMITS | RW | `0x3_03_03` | `[7:0]` invalid_limit, `[15:8]` recover_n, `[19:16]` retry_max |
| 0x4C | RTCNT | RO | – | `[7:0]` consecutive rejects, `[15:8]` consecutive accepts, `[19:16]` consecutive failures |
| 0x50 | WD | RO | – | handshake watchdog count (cycles) |
| 0x80–0xA0 | event counters | RO | 0 | ACCEPT, REJECT, FB_ENTER, FB_EXIT, SW_START, SW_DONE, SW_FAIL, MISMATCH, ILLEGAL |
| 0xA4 | LAST_LAT | RO | 0 | cycles `sw_req` was high in the last completed switch |
| 0xA8 | MAX_LAT | RO | 0 | maximum of LAST_LAT |
| 0xAC | TMR_ERR | RO | 0 | cycles with a replica disagreement |
| 0xB0/0xB4 | CYCLE_LO/HI | RO | 0 | 64-bit cycle counter |
| 0xB8 | STICKY | RO | 0 | `[0]` tmr_err seen, `[1]` fault seen, `[2]` illegal state seen |

The reset defaults are the `DEF_*` parameters of `astro_ctrl_axil`.

## 9. Protection boundary

| Part | Protection | Effect of an upset |
|---|---|---|
| Core state: configuration, timers, FSM, telemetry staging (459 bits) | TMR with voted feedback; triplicated voters | A flip-flop upset in one replica is outvoted and overwritten on the next edge. A CRAM upset in one replica's logic is masked until scrubbing |
| Next-state logic | triplicated | as above |
| Output voter (19 bits) | single | single point of failure on the outputs (non-triplicated I/O [4]) |
| Read-back mux | domain 0 only | wrong read data; never affects the mode |
| AXI adaptor | none | one corrupted bus transaction; the CRC and sequence checks reject corrupted telemetry |
| Diagnostic counters | none | a corrupted statistic only |

`tmr_err` and the `TMR_ERR` counter make replica disagreements visible during
SEM IP campaigns. With `TMR=0` the same design builds unprotected, so the
controller's vulnerability can be measured both ways.

## 10. Open decisions, kept configurable

| Decision | How the controller leaves it open |
|---|---|
| D2 switching level | the handshake is the same for Level 1 (clock gating) and Level 2 (PR); `SW_TO` covers either latency |
| D5 protection modes | 2-bit ordered mode codes; use 2, 3 or 4 of them via `MODE_MAP` |
| D6 fallback policy | `CTRL.fb_hold` (0 = fail to full protection, 1 = hold last mode) |
| D7 threat mapping | thresholds, hysteresis and dwell times; for two effective levels, give ELEVATED and EXTREME the same mode in `MODE_MAP` |
| P0/P1 vs P2–P4 | `CTRL.static_en` gives the static policies on the same bitstream |

## 11. Verification (V1)

Run `make all` (about 2 minutes). Every item below passes.

| Check | How | Result |
|---|---|---|
| Lint | Verilator `-Wall`, TMR=1 and TMR=0 | clean |
| G1: stale | T4: fallback within ±20 cycles of `FRESH_TO`; TMR at once; recovery needs `RECOVER_N` messages | pass |
| G1: invalid | T5: each reject reason flagged; isolated rejects harmless; `INVALID_LIMIT` consecutive rejects → fallback; a stream of bad messages still goes stale | pass |
| G1: rapid toggle | T6: 120 NORMAL/ELEVATED toggles → 9 switches (bound 10); no de-escalation inside `DWELL_DN` (monitor M3); toggling inside the hysteresis band → 0 switches | pass |
| G1: reset during switch | T7: hard reset at every offset 0–18 cycles into a switch (covers REQ, ack and REL); soft reset at 8 offsets: always ends in a consistent IDLE state with no fault and no protocol violation | pass |
| Also | T1 safe power-up, T2 recovery, T3 hysteresis and dwell, T8 watchdog/retry/fault/clear (no-ack and stuck-ack), T9 wrong-mode ack and spontaneous payload mode change, T10 static policies, T11 hold-last-mode, T12 voted upsets and illegal-state recovery, T13 AXI errors | 202/202 checks |
| Protocol monitors | M1 target stable, M2 4-phase, M3 dwell, M4 no X, throughout the directed run | no violation |
| Equivalence with the model | 3 seeds × 300k cycles of randomised closed-loop traces (corrupted telemetry, config changes, soft and hard resets, slow, wrong-mode, stuck and spontaneously changing payload); every output and a random register compared each cycle | TMR=1 and TMR=0 match on every cycle |
| Upset masking | 9,914 random single-replica bit flips in 20k cycles | outputs identical to the fault-free model; every flip detected by `tmr_err` |
| Negative control | the same bit flipped in two replicas | caught as mismatches, as expected |

What this does not show: CRAM upsets in the next-state logic or the routing.
Those need SEM IP campaigns on hardware (V2). The proposal plans them for the
controller's Pblock (see `fpga/astro_ctrl_pblock.xdc`).

## 12. Resource estimate

Yosys 0.33 `synth_xilinx -family xc7`, hierarchy kept (`make synth`). Vivado
numbers will differ; use its post-implementation report as the real figure.

| Build | LUT | FF | of XC7Z020 |
|---|---|---|---|
| TMR=1 | 4,871 | 1,940 | 9.2 % LUT, 1.8 % FF |
| TMR=0 | 1,518 | 1,022 | 2.9 % LUT, 1.0 % FF |

Breakdown for TMR=1: each core copy is about 850 LUTs (about 1,070 with
read-back). The three 459-bit voters take 1,377 LUTs, disagreement detection
266, diagnostics 405 LUTs / 483 FF, and the AXI adaptor 45 LUTs. The
voters and the 32-bit timers dominate. If the controller's essential-bit count
matters more than generality, narrow the timers and configuration fields, or
make rarely changed configuration fixed parameters.

## 13. Limitations and next steps

* Not yet built in Vivado or run on the board: timing closure at 100 MHz,
  survival of `DONT_TOUCH` and the real utilisation are still open.
* `sw_ack` / `pl_mode` are assumed synchronous to the controller clock.
* The output voter, AXI adaptor and diagnostic counters are unprotected by
  design (section 9). Measure the output voter's share in the SEM campaign.
* The payload mode adapter (Block 4) must implement section 4. The behavioural
  payload in `tb/tb_directed.v` is a reference for its timing.
