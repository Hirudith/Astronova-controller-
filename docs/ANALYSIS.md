# Analysis: Blocks 1, 2 and 5

The code computes upset-rate traces (Block 1), alert timelines (Block 2), and
failure probability and energy per policy (Block 5), as in proposal §5.2, §5.3
and §5.6.

> **Status: V1, pipeline only.** 47 of the 58 inputs are PLACEHOLDERs. Every
> output is stamped with that count (see *Provenance* below). The numbers in this
> document show that the pipeline works and how it reads. They are **not
> results** and must not be quoted as findings.

## Files

| File | Block | Content |
|---|---|---|
| `python/astronova/inputs.py` | all | every input: value, range, unit, source, status |
| `python/astronova/environment.py` | 1 | λ_ref, site factor, GLE / Forbush profiles, NMDB loader, λ(t), RQ1 detectability |
| `python/astronova/alerts.py` | 2 | alert intervals from POD/FAR/timing, false alerts, outages, telemetry messages |
| `python/astronova/policy.py` | 5 | fast tick-level controller policy (verified against the cycle-accurate model) |
| `python/astronova/evaluate.py` | 5 | E[F], energy, policies P0–P4, annualisation, Monte Carlo, break-even, RQ3 sweep |
| `python/run_analysis.py` | – | runs everything; writes CSVs and a figure to `build/analysis/` |

Run it with `make analysis` (about 2 minutes), or
`cd python && python3 run_analysis.py --samples 100`.

## Block 1: λ(t)

    λ(t) = λ_ref × S_site × R_site(t)

* **λ_ref** = CRAM bits × FIT/Mb. With the proposal's 32 Mb at 75 FIT/Mb, this is
  **2.4 × 10⁻⁶ /h**, matching proposal §5.8 (a test checks this). It is one upset
  per ~47 years for one device at sea level.
* **S_site** = altitude factor × cutoff factor.
  * The altitude factor is exp((1033 − d)/131.3), with atmospheric depth d from
    the ICAO standard atmosphere. This is the form of the JESD89A Annex A model;
    the coefficient is TO-VERIFY. It gives Denver ×4.0, the 5 km site ×40, and
    FL350 ×410; the last is outside the formula's best-tested range.
  * Cutoff factors are PLACEHOLDERs until taken from the JESD89A location model
    or EXPACS/PARMA (D4).
* **R_site(t)** = 1 + k × ΔNM(t)/100.
  * ΔNM is a reference neutron monitor's percentage change. It comes from NMDB
    data (`load_nmdb` reads the NEST ASCII export) or from a synthetic GLE /
    Forbush profile, which is shape-only and labelled synthetic.
  * k is the site transfer factor (decision D3), with separate factors for GLEs
    and Forbush decreases.
  * NMDB was not reachable from the build container; download the GLE #77 data
    and pass it to `load_nmdb`.
* **Cross-check (V3).** 100,000 XC7Z020s in Denver give one CRAM upset per
  ~66 min. Keller and Wirthlin [1] report ~30 min for their (larger) device, the
  same order of magnitude.

## Block 2: alerts

* For each real event, an alert is raised with probability POD. It starts at
  onset + offset (negative offset = early warning) and lasts until the event
  ends plus a hold time.
* False alerts follow from the published ratio: FAR = F/(F + H) gives F per year
  = FAR/(1 − FAR) × POD × events per year.
* Outages (decision on how the PS reports them: `gap` sends nothing, `flagged`
  sends `source_ok = 0`) happen at random and with some probability during an
  event.
* The quoted figures in use are the proposal's: UMASEP-500 POD ≈ 54 %,
  FAR ≈ 30 %, ~8 min ahead of the first NM alert [28]. The NM alarm's figures
  are PLACEHOLDERs ("very few false alarms" [27]).
* An alert maps to the metric 2.0 (ELEVATED → TMR with the default map; D7).
  The oracle P4 is fed the true R(t).

## Block 5: evaluation

Proposal §5.6, implemented as written:

    E[F] = Σ λ(t)·p_f(m(t))·Δt  +  Σ_k λ(t_k)·W_k·p_f,sw  +  E[F_ctrl]
    E    = Σ_m P_m·T_m + n_sw·E_sw + (P_ctrl + P_scrub)·T

* **Builds per policy.**
  * P0 uses the BASELINE build and P1 the STATIC_TMR build; neither has a
    controller.
  * P2–P4 use the SWITCHABLE build plus the controller. Its failure terms
    include the controller's own vulnerability and the switchable build's
    SIMPLEX-mode overhead (the RQ5 penalty).
* **m(t)** comes from `policy.simulate`. It reproduces the switch sequence of
  the cycle-accurate controller model, which itself matches the RTL every cycle,
  on 25 random timelines in the test suite (200 checked during development),
  including a sub-tick glitch the hardware produces.
* **W_k** is the measured Level-1 switch window: 2 cycles = 20 ns (V1, RQ4). At
  any realistic λ, the switch-window term is negligible for Level-1 switching.
* **Annualisation.** A year = 365.25 × a simulated quiet day (with false alerts
  and outages) + Σ over event classes of rate × (event window − the same window
  without the event). The result splits into quiet, GLE and Forbush parts.
* **Monte Carlo.** Each sample draws every input from its range (triangular,
  log-triangular for ranges wider than 10×).
* **Break-even (D8 made explicit).** "Averted" is net fleet failures per year
  versus P0. Its two parts are reported separately: GLE failures averted, and
  the quiet-time penalty. The verdict rule (`pays` / `negligible` / `hurts`) and
  its thresholds are parameters of `summarize`.

## What the V1 pipeline already shows (with placeholder inputs)

These are mechanisms, not results:

1. **The quiet-time penalty decides the sign.** At ground sites, GLEs add about
   10⁻⁶–10⁻⁵ failures per device per year. The switchable build's SIMPLEX
   overhead (placeholder +10 %) and the controller's own vulnerability add
   10⁻⁴ or more. Adaptation can only pay if the RQ5 penalty and the controller's
   sensitivity, measured in V2, are far smaller than the GLE excess. The model
   turns this into a concrete hardware requirement.
2. **Forbush decreases offset GLEs.** Over a year, a few Forbush decreases (fewer
   upsets for days) can outweigh the GLE excess at ground sites.
3. **Fleet size and site carry the effect.** GLE failures averted range from
   ~10⁻⁶ per year (one device, sea level) to ~10² per year (100,000 devices at
   FL350): the "where and when" structure of the break-even map
   (`build/analysis/gle_averted.png`).
4. **RQ1.** With hypothetical exposures (1 Gbit to 1 Tbit, 24 h window), a
   GLE #77-class excess at sea level has z ≈ 0.01–0.3. A null result at ground
   level is the expected outcome. Enter the real exposures of [6] and [7] in
   `run_analysis.field_null_examples`.

## Provenance

`build/analysis/inputs.csv` lists every input with nominal, range, unit, status
and source. The statuses:

| Status | Meaning | Count |
|---|---|---|
| PROPOSAL | stated in the proposal with a citation; check the cited source | 6 |
| STANDARD | textbook constant or formula | 1 |
| TO-VERIFY | recalled published value; confirm at the source | 2 |
| DERIVED | computed from other entries | 2 |
| PLACEHOLDER | illustrative; must be replaced | 47 |

What replaces the placeholders, in order of influence:
1. V2 hardware: p_f per mode, the switchable penalty, controller p_f.
2. Site cutoff and transfer factors: JESD89A / EXPACS / AniMAIRE (D3, D4).
3. Event rates and shapes: NMDB, the GLE database.
4. Power: Vivado or measurement (D9).
5. The NM alarm's performance: [27].
