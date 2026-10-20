"""Block 5: evaluation engine (proposal section 5.6).

    E[F] = sum_t lambda(t) * p_f(m(t)) * dt  +  sum_k lambda(t_k) * W_k * p_f,sw  +  E[F_ctrl]
    P    = 1 - exp(-E[F]),    fleet of N devices: N * E[F]
    E    = sum_m P_m * T_m  +  n_sw * E_sw  +  (P_ctrl + P_scrub) * T

Policies (proposal 5.7):
    P0 static baseline   BASELINE build, no controller
    P1 static full TMR   STATIC_TMR build, no controller
    P2 adaptive, NM arrival alarm      SWITCHABLE build + controller
    P3 adaptive, satellite early warning
    P4 oracle: the controller is fed the true enhancement R(t)

A year is a quiet background (simulated with false alerts and telemetry
outages) plus, for each event class, its rate times the excess an event adds
over the same window without it. Every input can be drawn from its range;
results carry a provenance note listing the PLACEHOLDER inputs they rest on.
"""

import math
import random
from dataclasses import dataclass, field

import numpy as np

from . import alerts as A
from . import environment as E
from . import inputs as I
from . import regs as R
from .policy import PolicyConfig, simulate

POLICIES = ["P0", "P1", "P2", "P3", "P4"]
POLICY_NAMES = {"P0": "static baseline", "P1": "static TMR", "P2": "adaptive, NM alarm",
                "P3": "adaptive, early warning", "P4": "oracle"}
ADAPTIVE = ("P2", "P3", "P4")
ALERT_OF = {"P2": "nm_alarm", "P3": "umasep"}

MIN_PER_DAY = 1440
DAYS_PER_YEAR = 365.25


@dataclass
class Settings:
    policy: PolicyConfig = field(default_factory=lambda: PolicyConfig(
        fresh_to=3, dwell_up=0, dwell_dn=60, invalid_limit=3, recover_n=3))   # D7, 1 tick = 1 min
    window_min: int = 2 * MIN_PER_DAY        # one event window
    onset_min: int = 6 * 60                  # event onset inside the window
    quiet_days: int = 60                     # length of the simulated quiet background
    outage_mode: str = "gap"


# ---------------------------------------------------------------------------
# Hardware model
# ---------------------------------------------------------------------------
def hardware(rng=None, hw=I.HARDWARE):
    v = {k: p.value(rng) for k, p in hw.items()}
    pf0 = v["pf_simplex"]
    v["pf"] = {
        # build -> failure probability per configuration upset, by mode
        "BASELINE": {0: pf0},
        "STATIC_TMR": {2: pf0 * (1 - v["tmr_reduction_static"])},
        "SWITCHABLE": {
            0: pf0 * v["simplex_overhead_switchable"],
            1: pf0 * v["simplex_overhead_switchable"],         # DMR detects, but still fails the run
            2: pf0 * (1 - v["tmr_reduction_switchable"]),
            3: pf0 * (1 - v["tmr_reduction_switchable"]),
        },
    }
    return v


def power_w(build, mode, hw, controller):
    n_active = {0: 1, 1: 2, 2: 3, 3: 3}[mode]
    p = hw["p_static_w"] + hw["p_scrub_w"] + n_active * hw["p_replica_w"]
    if mode >= 2:
        p += hw["p_voter_w"]
    if controller:
        p += hw["p_ctrl_w"]
    return p


def build_of(policy):
    return {"P0": "BASELINE", "P1": "STATIC_TMR"}.get(policy, "SWITCHABLE")


def failures_and_energy(lam_per_h, modes, switches, policy, hw, dt_min=1.0):
    """E[F] and energy (J) of one device over a trace (arrays per tick)."""
    build = build_of(policy)
    ctrl = policy in ADAPTIVE
    pf_tab = hw["pf"][build]
    pf = np.vectorize(lambda m: pf_tab[int(m)])(modes) if len(pf_tab) > 1 else \
        np.full(len(modes), next(iter(pf_tab.values())))
    upsets = lam_per_h * dt_min / 60.0                       # expected upsets per tick
    ef = float(np.sum(upsets * pf))
    w_h = hw["switch_window_s"] / 3600
    ef += sum(lam_per_h[t] * w_h * hw["pf_switch"] for t, _, _ in switches if t < len(lam_per_h))
    if ctrl:
        ef += float(np.sum(upsets)) * hw["pf_controller"]
    pw = {m: power_w(build, m, hw, ctrl) for m in range(4)}
    energy = float(sum(pw[int(m)] * c for m, c in zip(*np.unique(modes, return_counts=True)))) \
        * dt_min * 60
    energy += len(switches) * hw["e_switch_j"]
    return ef, energy


# ---------------------------------------------------------------------------
# Mode timelines per policy
# ---------------------------------------------------------------------------
def static_trace(policy, n):
    return np.full(n, 0 if policy == "P0" else 2, dtype=np.int8), []


def adaptive_trace(msgs, n, cfg):
    tr = simulate(msgs, n, cfg, start_mode=cfg.modes[3])
    return tr.mode, tr.switches


def quiet_background(rng, st, alert_systems=I.ALERTS):
    """Per-day failures (per unit lambda) and energy-relevant mode traces of
    each policy over a quiet period with false alerts and outages."""
    n = st.quiet_days * MIN_PER_DAY
    out = {}
    for p in POLICIES:
        if p in ("P0", "P1"):
            out[p] = static_trace(p, n)
        elif p == "P4":                     # oracle: knows nothing is happening
            out[p] = adaptive_trace([(t, A.METRIC_QUIET, True) for t in range(n)], n, st.policy)
        else:
            sysm = alert_systems[ALERT_OF[p]]
            fa = A.false_alerts(sysm, n, I.GLE_RATE.value(rng), rng)
            oi = A.outages(n, rng)
            msgs = A.messages_from_alerts(fa, n, outage_iv=oi, outage_mode=st.outage_mode)
            out[p] = adaptive_trace(msgs, n, st.policy)
    return out


def event_traces(event, site, rng, st, alert_systems=I.ALERTS):
    """lambda(t) and the mode trace of every policy over one event window, and
    the same window without the event."""
    t, lam, nm = E.lambda_trace(site, event, st.window_min, st.onset_min, rng=rng)
    lam_bg = np.full_like(lam, lam[0])
    end = A.event_end(t, nm)
    n = len(t)
    quiet_msgs = [(float(x), A.METRIC_QUIET, True) for x in range(n)]
    traces, ref = {}, {}
    for p in POLICIES:
        if p in ("P0", "P1"):
            traces[p] = ref[p] = static_trace(p, n)
            continue
        ref[p] = adaptive_trace(quiet_msgs, n, st.policy)
        if p == "P4":
            r = lam / lam[0] if lam[0] > 0 else np.ones_like(lam)
            traces[p] = adaptive_trace(A.messages_oracle(t, r), n, st.policy)
        else:
            sysm = alert_systems[ALERT_OF[p]]
            iv = A.event_alerts(sysm, st.onset_min, end, rng) if event.kind == "gle" else []
            oi = A.outages(n, rng, event_window=(st.onset_min, end), dropout={
                "p_outage_per_day": I.Param(0.0), "outage_min": I.DROPOUT["outage_min"],
                "p_outage_during_event": I.DROPOUT["p_outage_during_event"]})
            msgs = A.messages_from_alerts(iv, n, outage_iv=oi, outage_mode=st.outage_mode)
            traces[p] = adaptive_trace(msgs, n, st.policy)
    return lam, lam_bg, traces, ref


def annual(site, rng=None, st=Settings(), quiet=None, hw=None, alert_systems=I.ALERTS):
    """Annual expected failures and energy of one device at a site, per policy.
    failures = quiet + gle + fd, where gle and fd are what GLEs and Forbush
    decreases add (or remove) relative to the same windows without them."""
    rng = rng or random.Random(0)
    hw = hw or hardware(rng)
    quiet = quiet or quiet_background(rng, st, alert_systems)
    lam_bg = E.lambda_background_per_h(site, rng)
    res = {}
    for p in POLICIES:
        modes, sw = quiet[p]
        lam = np.full(len(modes), lam_bg)
        f_q, e_q = failures_and_energy(lam, modes, sw, p, hw)
        scale = DAYS_PER_YEAR / st.quiet_days
        res[p] = {"failures": f_q * scale, "energy_j": e_q * scale, "quiet_failures": f_q * scale,
                  "gle_failures": 0.0, "fd_failures": 0.0, "switches": len(sw) * scale,
                  "tmr_fraction": float(np.mean(modes >= 2))}
    for ev in I.EVENTS:
        rate = ev.per_year.value(rng)
        lam, lam_ref, traces, ref = event_traces(ev, site, rng, st, alert_systems)
        key = "gle_failures" if ev.kind == "gle" else "fd_failures"
        for p in POLICIES:
            f_e, e_e = failures_and_energy(lam, *traces[p], p, hw)
            f_r, e_r = failures_and_energy(lam_ref, *ref[p], p, hw)
            res[p]["failures"] += rate * (f_e - f_r)
            res[p][key] += rate * (f_e - f_r)
            res[p]["energy_j"] += rate * (e_e - e_r)
            res[p]["switches"] += rate * (len(traces[p][1]) - len(ref[p][1]))
    return res


# ---------------------------------------------------------------------------
# Monte Carlo over the input ranges
# ---------------------------------------------------------------------------
def monte_carlo(n_samples=50, seed=1, st=Settings(), sites=I.SITES, progress=None,
                alert_systems=I.ALERTS):
    """Returns {site name: {policy: {metric: np.array over samples}}}."""
    out = {s.name: {p: {} for p in POLICIES} for s in sites}
    for i in range(n_samples):
        rng = random.Random(seed * 100_003 + i)
        hw = hardware(rng)
        quiet = quiet_background(rng, st, alert_systems)
        for s in sites:
            r = annual(s, rng, st, quiet, hw, alert_systems)
            for p in POLICIES:
                for k, v in r[p].items():
                    out[s.name][p].setdefault(k, []).append(v)
        if progress:
            progress(i + 1, n_samples)
    for s in out.values():
        for p in s.values():
            for k in p:
                p[k] = np.array(p[k])
    return out


def summarize(mc, fleet_sizes=I.FLEET_SIZES, min_averted=0.1, min_saving=0.2):
    """Break-even table (decision D8 made explicit):
      averted  = fleet failures per year avoided relative to P0 (median),
                 net of the controller's own failures, the switchable build's
                 penalty and switch-window risk
      gle_averted / quiet_penalty: the two parts of 'averted' that matter
                 (GLE failures avoided; extra quiet-time failures)
      saving   = energy saved relative to P1 (median fraction)
      verdict  = 'pays'        averted >= min_averted and saving >= min_saving
                 'hurts'       averted < 0 (adaptation adds failures)
                 'negligible'  otherwise
    """
    rows = []
    for site, pol in mc.items():
        f0, e1 = pol["P0"]["failures"], pol["P1"]["energy_j"]
        for n in fleet_sizes:
            for p in ADAPTIVE:
                av = n * (f0 - pol[p]["failures"])
                sv = 1 - pol[p]["energy_j"] / e1
                med_av, med_sv = float(np.median(av)), float(np.median(sv))
                verdict = ("hurts" if med_av < 0 else
                           "pays" if med_av >= min_averted and med_sv >= min_saving else "negligible")
                rows.append({
                    "site": site, "fleet": n, "policy": p,
                    "averted_per_yr": med_av, "averted_p5": float(np.percentile(av, 5)),
                    "averted_p95": float(np.percentile(av, 95)),
                    "gle_failures_P0_per_yr": float(np.median(n * pol["P0"]["gle_failures"])),
                    "gle_averted_per_yr": float(np.median(n * (pol["P0"]["gle_failures"]
                                                               - pol[p]["gle_failures"]))),
                    "quiet_penalty_per_yr": float(np.median(n * (pol[p]["quiet_failures"]
                                                                 - pol["P0"]["quiet_failures"]))),
                    "energy_saving_vs_P1": med_sv,
                    "switches_per_yr": float(np.median(pol[p]["switches"])),
                    "tmr_fraction": float(np.median(pol[p]["tmr_fraction"])),
                    "verdict": verdict})
    return rows


def provenance():
    """Counts of inputs by status, and the PLACEHOLDER ones by name."""
    counts, placeholders = {}, []
    for group, name, p in I.all_params():
        counts[p.status] = counts.get(p.status, 0) + 1
        if p.status == "PLACEHOLDER":
            placeholders.append(f"{group}: {name}")
    return counts, placeholders


def failure_probability(expected_failures):
    return 1 - math.exp(-expected_failures)


def alert_quality_sweep(site, pods, fars, offset_min=0.0, hold_min=30.0, n_samples=20,
                        fleet=100_000, seed=7, st=Settings()):
    """RQ3: net fleet failures averted per year (vs P0) by an adaptive policy
    driven by a hypothetical alert system of given POD and FAR.
    Returns {(pod, far): (median averted, median GLE averted, median energy saving vs P1)}."""
    out = {}
    for pod in pods:
        for far in fars:
            sysm = I.AlertSystem(f"POD={pod} FAR={far}", I.Param(pod), I.Param(far),
                                 I.Param(offset_min), I.Param(hold_min))
            mc = monte_carlo(n_samples, seed, st, [site], alert_systems={"umasep": sysm,
                                                                          "nm_alarm": sysm})
            pol = mc[site.name]
            av = fleet * (pol["P0"]["failures"] - pol["P3"]["failures"])
            gle = fleet * (pol["P0"]["gle_failures"] - pol["P3"]["gle_failures"])
            sv = 1 - pol["P3"]["energy_j"] / pol["P1"]["energy_j"]
            out[(pod, far)] = (float(np.median(av)), float(np.median(gle)), float(np.median(sv)))
    return out
