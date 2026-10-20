# Switchable payload (Block 4)

Implements proposal §5.5: one stateful payload in three forms, (i) an
unprotected baseline, (ii) a static full-TMR reference and (iii) a switchable
design. It uses Level-1 switching (clock enable plus bypass) with state
resynchronisation. All results here are validation level **V1** (simulation).

## Files

| File | Content |
|---|---|
| `rtl/payload/pl_workload.v` | reference workload: combinational next state of one replica |
| `rtl/payload/pl_switchable.v` | the three variants, replicas, voters, mode register, switch adapter |
| `rtl/payload/pl_axil.v` | top level: AXI4-Lite run control, observation and counters |
| `python/astronova/payload.py` | golden model of the workload and the register map |
| `python/astronova/driver.py` (`Payload`) | PS side: start a run, wait, classify ok / SDC / hang |
| `tb/tb_system.v` | controller and payload together, all three variants |

## Variants (`VARIANT` parameter)

| Value | Name | Replicas | Reports | Use |
|---|---|---|---|---|
| 0 | BASELINE | 1 | mode 0 | P0, lower bound on cost |
| 1 | STATIC_TMR | 3, voted feedback, no mode logic | mode 2 | P1, reliability reference for RQ5 |
| 2 | SWITCHABLE | 3, mode-dependent | 0–3 | adaptive policies P2–P4 |

Modes of the switchable variant (decision D5 kept open by supporting all four codes):

| Mode | Replicas clocked | State feedback | Output | Upset in an active replica |
|---|---|---|---|---|
| 0 SIMPLEX | r0 | own | r0 | corrupts the result |
| 1 DMR | r0, r1 | own | r0 | detected (`dmr_err`), not corrected |
| 2 TMR | r0, r1, r2 | voted | voted | masked and corrected next cycle |
| 3 TMR | as 2 | voted | voted | as 2; use the code for a stronger scrub policy |

## Switching (Level 1, decision D2)

* The switch is applied in the cycle the payload first sees `sw_req`.
* A replica that becomes active is loaded with **replica 0's next state** in
  that same edge, so it joins exactly in step. The workload never stalls and
  never diverges. This is the state resynchronisation of [39], with zero extra
  cycles.
* A replica that becomes inactive keeps its last state, with its clock enable
  low. Inactive replicas are always reloaded before they are used again, so an
  upset in an inactive replica is harmless.
* `sw_ack` rises one cycle after the request. The controller measures
  `LAST_LAT = 2` cycles. This is the Level-1 switch latency for RQ4; the
  switch-window failure probability needs the V2 SEM campaigns.
* The static variants acknowledge every request but keep reporting their fixed
  mode. Use them with the controller's static policy in the matching mode;
  any other request shows up at the controller as a mode mismatch.

## Protection boundary (SWITCHABLE)

Triplicated: the replicas, their voters, and the mode register (voted
feedback). Each domain picks its feedback source and clock enable from its own
voted copy of the mode.

Single:
* the switch adapter (the `sw_ack` flip-flop and the load decode);
* the replica-0 next state used for loading;
* the read-out multiplexer.

These single additions, together with the per-replica feedback and load
multiplexers, are what makes the switchable TMR mode more sensitive than
static TMR. That difference is the subject of hypothesis H2 / RQ5. Measure it
with SEM IP campaigns on both builds.

## Workload (decision D1 still open)

`pl_workload.v` is a placeholder: an iterative kernel with its own LFSR input
generator. Each iteration does a 32-bit multiply-accumulate and updates a
rotating signature, giving 128 bits of state and 3 DSP48 slices. A run is fully
determined by `SEED` and `STOP_AT`, so the PS can classify every run against the
golden model as **ok**, **SDC** or **hang** (`Payload.check`). To use another
workload (ITC'99 B13, a matrix multiply, a CNN layer), keep the same shape: a
combinational next-state function with all state in one vector.

## Verification (`make system`, V1)

| Variant | Run A: clean, with switching | Run B: injected upsets | Run C: negative control |
|---|---|---|---|
| SWITCHABLE | 129 switches through all 4 modes in 8,000 iterations; final state = golden; every controller switch applied exactly once; latency 2 cycles | 1,065 upsets (any replica in TMR, inactive replicas otherwise) plus one DMR detection: final state = golden | replica 0 in SIMPLEX: result corrupted, as expected |
| STATIC_TMR | final state = golden | 1,082 upsets in random replicas: golden | same bit in two replicas: corrupted |
| BASELINE | final state = golden | – | replica 0: corrupted |

Protocol monitors (target stable during a request, 4-phase order, payload acks
in the requested mode) run throughout.

## Resource estimate (Yosys, `make synth`)

| Variant | LUT | FF | DSP48 |
|---|---|---|---|
| BASELINE | 990 | 500 | 3 |
| STATIC_TMR | 2,781 | 756 | 9 |
| SWITCHABLE | 3,385 | 762 | 9 |

These totals include the AXI top and its counters (about 300 LUT / 370 FF in
every variant). Switchable TMR costs about 600 LUTs more than static TMR: the
per-replica feedback and load multiplexers and the mode logic. Vivado figures
will differ.
