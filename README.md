# Astronova: protected mode-selection controller (Block 3)

This is the RTL for the space-weather-aware adaptive fault-tolerance project
(Project Astronova, PYNQ-Z2 / XC7Z020). It is the always-protected block that
turns threat telemetry into a protection mode for the payload:

* telemetry integrity checks: CRC-8, reserved bits, source-quality flag,
  sequence order;
* threat levels NORMAL / ELEVATED / EXTREME with rise/fall hysteresis;
* minimum dwell time before escalating and before relaxing;
* a freshness timer and a consecutive-invalid limit that both trigger a safe
  fallback. The controller also starts in fallback after any reset;
* a 4-phase `sw_req`/`sw_ack` switch handshake with a watchdog, retry, payload
  mode-mismatch detection and a FAULT state;
* all state in TMR with voted feedback, plus replica-disagreement monitoring
  (`TMR=0` builds the unprotected version for comparison);
* static P0/P1 policies and the open decisions D5–D7 as run-time registers, so
  one bitstream serves every experiment;
* diagnostic counters, including the measured switch latency for RQ4.

The full specification (ports, handshake, register map, FSM, protection
boundary, verification and resources) is in [docs/SPEC.md](docs/SPEC.md).
Board integration notes are in [fpga/README.md](fpga/README.md).

## Layout

```
rtl/      astro_ctrl_axil.v (top), astro_ctrl_tmr.v, astro_ctrl_core.v,
          tmr_voter.v, astro_ctrl_diag.v, astro_ctrl_defs.vh
tb/       tb_directed.v (G1 cases + protocol monitors), tb_cosim.v (model equivalence, upset injection)
python/   astronova/{regs,model,driver}.py, gen_cosim.py, tests/
fpga/     Pblock template, Vivado / PYNQ integration notes
docs/     SPEC.md
```

## Running the checks

Needs `iverilog`, `verilator` (5.x), `yosys` and `python3`.

```
make all      # lint, Python tests, directed tests, co-simulation, upset injection (~2 min)
make synth    # Yosys 7-series resource estimate for TMR=1 and TMR=0
```

Status (validation level V1, simulation only):

* Verilator `-Wall` lint is clean.
* Directed tests: 202/202 checks pass. These cover the G1 cases (stale,
  invalid, rapid toggle, reset during switch) plus fault, mismatch, policy,
  upset and AXI tests.
* Co-simulation: TMR=1 and TMR=0 match the Python reference model on every
  cycle of 3 × 300k randomised cycles.
* Upset injection: 9,914 random single-replica flips are all masked and all
  detected. Double flips are caught as mismatches (negative control).
* Resource estimate (Yosys, TMR=1): 4,871 LUT / 1,940 FF, i.e. 9.2 % / 1.8 % of
  the XC7Z020. Vivado figures are still to be measured.

## Using the reference model in Block 5

`python/astronova/model.py` is equivalent to the RTL on every clock cycle, so
the evaluation engine can take m(t) from it rather than from a separate
policy model:

```python
from astronova import regs as R
from astronova.model import simulate_timeline
events = [(t, R.q88(ratio), True) for t, ratio in timeline]      # one entry per message
trace = simulate_timeline(events, {R.FRESH_TO: 180, R.DWELL_DN: 600}, horizon=len(timeline))
# trace: [(tick, mode, level, fallback), ...] at every change
```
