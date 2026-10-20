"""Tests for the analysis blocks: environment (1), alerts (2), policy simulator
and evaluation engine (5).

Run from python/:  python3 -m unittest discover -s tests -v
"""

import math
import os
import random
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from astronova import alerts as A                       # noqa: E402
from astronova import environment as E                  # noqa: E402
from astronova import evaluate as V                     # noqa: E402
from astronova import inputs as I                       # noqa: E402
from astronova import policy as P                       # noqa: E402
from astronova import regs as R                         # noqa: E402
from astronova.model import CtrlModel, IdealPayload     # noqa: E402


class TestEnvironment(unittest.TestCase):
    def test_reference_rate_matches_proposal(self):
        # proposal 5.8: XC7Z020 at sea level, lambda ~ 2.4e-6 per hour
        self.assertAlmostEqual(E.lambda_ref_per_h(), 2.4e-6, places=9)

    def test_altitude_factor(self):
        self.assertAlmostEqual(E.altitude_factor(0), 1.0, places=2)
        f = [E.altitude_factor(h) for h in range(0, 12_001, 1000)]
        self.assertTrue(all(b > a for a, b in zip(f, f[1:])))
        self.assertTrue(3 < E.altitude_factor(1609) < 5)        # Denver

    def test_gle_profile_peak(self):
        t = np.arange(0, 2000)
        p = E.gle_profile(t, 100, 125.0, 15, 120)
        self.assertAlmostEqual(p.max(), 125.0, delta=0.5)
        self.assertEqual(p[:101].max(), 0.0)                    # nothing before onset

    def test_forbush_is_a_decrease(self):
        t = np.arange(0, 5000)
        p = E.forbush_profile(t, 100, -8.0, 60, 1440)
        self.assertAlmostEqual(p.min(), -8.0, places=6)
        self.assertLessEqual(p.max(), 0.0)

    def test_load_nmdb(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("# NMDB export\nstart_date_time;RCORR_E\n")
            for m in range(240):
                v = 100.0 if m < 180 else 150.0
                f.write(f"2025-11-11 {m // 60:02d}:{m % 60:02d}:00;{v}\n")
            f.write("2025-11-11 04:00:00;null\n")
            path = f.name
        t, pct = E.load_nmdb(path, baseline_min=120)
        os.unlink(path)
        self.assertEqual(len(t), 240)
        self.assertAlmostEqual(pct[0], 0.0)
        self.assertAlmostEqual(pct[-1], 50.0)

    def test_field_detectability(self):
        d = E.field_detectability(1e-3, 100, 2.0, 24.0)
        self.assertAlmostEqual(d["background"], 2.4)
        self.assertAlmostEqual(d["excess"], 0.2)
        self.assertAlmostEqual(d["z"], 0.2 / math.sqrt(2.4))


class TestAlerts(unittest.TestCase):
    def test_false_alarm_rate_from_far(self):
        sysm = I.ALERTS["umasep"]
        # FAR = F / (F + H), H = POD * events  ->  F = FAR / (1 - FAR) * POD * events
        self.assertAlmostEqual(A.false_alarm_rate_per_year(sysm, 1.0), 0.30 / 0.70 * 0.54)

    def test_messages_gap_and_flagged(self):
        gap = A.messages_from_alerts([(10, 20)], 60, outage_iv=[(30, 40)], outage_mode="gap")
        flag = A.messages_from_alerts([(10, 20)], 60, outage_iv=[(30, 40)], outage_mode="flagged")
        self.assertEqual(len(gap), 50)
        self.assertEqual(len(flag), 60)
        self.assertEqual(sum(1 for _, m, _ in gap if m == A.METRIC_ALERT), 10)
        self.assertEqual(sum(1 for _, _, ok in flag if not ok), 10)


def _random_case(seed, horizon=300):
    rng = random.Random(seed)
    cfg = P.PolicyConfig(fresh_to=rng.choice([5, 12, 30]), dwell_up=rng.choice([0, 0, 4]),
                         dwell_dn=rng.choice([5, 15, 40]), invalid_limit=rng.choice([0, 2, 3]),
                         recover_n=rng.choice([1, 2, 3]))
    msgs, t, metric = [], 0, R.q88(1.0)
    while t < horizon:
        if rng.random() < 0.15:
            metric = rng.choice([R.q88(x) for x in (1.0, 1.3, 1.6, 2.0, 3.5, 4.5)])
        if rng.random() < 0.05:
            t += rng.randint(5, 40)
            continue
        msgs.append((t, metric, rng.random() > 0.05))
        t += rng.choice([1, 2, 3])
    return cfg, msgs, horizon


def _cycle_switches(cfg, msgs, horizon, cpt=16):
    """Switches (tick, new mode) of the cycle-accurate model, PS writing each
    tick's messages at the start of the tick."""
    ctrl, pl = CtrlModel(), IdealPayload(latency=1)
    ctrl.step(rst=1)

    def cyc(**kw):
        o = ctrl.step(sw_ack=pl.ack, pl_mode=pl.mode, **kw)
        pl.step(o["sw_req"], o["sw_target"])
        return o

    for a, v in list(cfg.registers().items()) + [(R.PRESCALE, cpt - 1)]:
        cyc(wr_en=1, wr_addr=a, wr_data=v)
    for _ in range(60 * cpt):                       # settle: dwell well expired
        cyc()
    while ctrl.s["presc"] != cpt - 1:              # tick period starts now
        cyc()
    by_tick, seq = {}, 0
    for t, m, ok in msgs:
        seq = (seq + 1) & 0xFF
        w = R.telemetry_word(m, seq, ok)
        by_tick.setdefault(t, []).extend([(R.TDATA, w), (R.TCRC, R.crc8_word(w))])
    out = []
    for t in range(horizon):
        writes = by_tick.get(t, [])
        for _ in range(cpt):
            o = cyc(wr_en=1, wr_addr=writes[0][0], wr_data=writes.pop(0)[1]) if writes else cyc()
            if o["events"] & (1 << R.EV["SW_DONE"]):
                out.append((t, ctrl.s["cur"]))
    return out


class TestPolicySimulator(unittest.TestCase):
    def test_matches_cycle_accurate_model(self):
        for seed in range(25):
            cfg, msgs, horizon = _random_case(seed)
            ref = _cycle_switches(cfg, msgs, horizon)
            fast = [(t, to) for t, _, to in P.simulate(msgs, horizon, cfg, R.M_BASELINE).switches]
            self.assertEqual(ref, fast, f"seed {seed}")

    def test_static_policy_never_switches(self):
        cfg = P.PolicyConfig(static_mode=R.M_TMR)
        tr = P.simulate([(t, R.q88(5.0), True) for t in range(100)], 100, cfg)
        self.assertEqual(tr.switches, [])
        self.assertTrue((tr.mode == R.M_TMR).all())


class TestEvaluation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.st = V.Settings(quiet_days=10)
        rng = random.Random(5)
        cls.hw = V.hardware(rng)
        cls.quiet = V.quiet_background(rng, cls.st)
        cls.res = V.annual(I.SITES[-1], rng, cls.st, cls.quiet, cls.hw)

    def test_tmr_fails_less_and_costs_more(self):
        r = self.res
        self.assertLess(r["P1"]["failures"], r["P0"]["failures"])
        self.assertGreater(r["P1"]["energy_j"], r["P0"]["energy_j"])

    def test_storms_add_failures_for_static_baseline(self):
        self.assertGreater(self.res["P0"]["gle_failures"], 0)
        self.assertLess(self.res["P0"]["fd_failures"], 0)       # Forbush decreases remove some

    def test_oracle_cuts_gle_failures(self):
        self.assertLess(self.res["P4"]["gle_failures"], self.res["P0"]["gle_failures"])

    def test_free_adaptation_never_hurts(self):
        hw = dict(self.hw)
        hw.update(pf_controller=0.0, pf_switch=0.0)
        pf = dict(hw["pf"])
        pf["SWITCHABLE"] = {0: hw["pf"]["BASELINE"][0], 1: hw["pf"]["BASELINE"][0],
                            2: pf["SWITCHABLE"][2], 3: pf["SWITCHABLE"][3]}
        hw["pf"] = pf
        r = V.annual(I.SITES[-1], random.Random(5), self.st, self.quiet, hw)
        for p in V.ADAPTIVE:
            self.assertLessEqual(r[p]["failures"], r["P0"]["failures"] * (1 + 1e-12), p)

    def test_provenance(self):
        counts, placeholders = V.provenance()
        self.assertGreater(len(placeholders), 0)
        for _, name, p in I.all_params():
            self.assertTrue(p.source, f"{name} has no source")
            self.assertIn(p.status, ("PROPOSAL", "STANDARD", "TO-VERIFY", "DERIVED", "PLACEHOLDER"))


if __name__ == "__main__":
    unittest.main()
