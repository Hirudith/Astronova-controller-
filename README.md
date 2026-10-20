# Astronova: adaptive fault tolerance for terrestrial SRAM-FPGAs

Hardware and analysis code for the space-weather-aware adaptive fault-tolerance
project (Project Astronova, PYNQ-Z2 / XC7Z020).

* **Block 3: protected controller** (`rtl/astro_ctrl_*`, [docs/SPEC.md](docs/SPEC.md))
* **Block 4: switchable payload** (`rtl/payload/`, [docs/PAYLOAD.md](docs/PAYLOAD.md)):
  baseline, static-TMR and switchable (SIMPLEX / DMR / TMR) variants, with
  Level-1 switching and state resynchronisation.
* **Blocks 1, 2, 5: analysis** (`python/astronova/`, [docs/ANALYSIS.md](docs/ANALYSIS.md)):
  λ(t) per site and event, alert timelines, and the evaluation engine with
  policies P0–P4, break-even table and alert-quality sweep. This is a V1
  pipeline: most inputs are still placeholders, and every output says so.

## Block 3: controller

The controller is the always-protected block that turns threat telemetry into
a protection mode for the payload:

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
rtl/          astro_ctrl_axil.v (controller top), astro_ctrl_tmr.v, astro_ctrl_core.v,
              astro_ctrl_diag.v, astro_ctrl_defs.vh, tmr_voter.v, axil_slave.v
rtl/payload/  pl_axil.v (payload top), pl_switchable.v, pl_workload.v
tb/           tb_directed.v (controller G1 cases), tb_cosim.v (model equivalence, upset injection),
              tb_system.v (controller + payload, all variants)
python/       astronova/{regs,model,driver,payload}.py   controller/payload models, PS drivers
              astronova/{inputs,environment,alerts,policy,evaluate}.py   analysis (Blocks 1, 2, 5)
              run_analysis.py, gen_cosim.py, tests/
fpga/         Pblock template, Vivado / PYNQ integration notes
docs/         SPEC.md (controller), PAYLOAD.md (payload), ANALYSIS.md (Blocks 1, 2, 5)
```

## Running the checks

Needs `iverilog`, `verilator` (5.x), `yosys` and `python3`.

```
make all      # lint, Python tests, directed, co-simulation, injection, system tests (~3 min)
make synth    # Yosys 7-series resource estimates: controller TMR=1/0, payload variants
make analysis # Blocks 1/2/5 pipeline -> build/analysis/ (V1, placeholder inputs)
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
* Controller + payload (`make system`): with every payload variant the final
  workload state equals the golden model. The switchable variant runs 129
  switches through all four modes with 1,065 injected upsets. The negative
  controls corrupt the result as expected. Level-1 switch latency is 2 cycles.

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
