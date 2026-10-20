"""Unit tests for the Python side: framing, the reference model's policy
behaviour, and the PS driver running against the model instead of hardware.

Run from python/:  python3 -m unittest discover -s tests -v
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from astronova import payload as PL                                # noqa: E402
from astronova import regs as R                                    # noqa: E402
from astronova.driver import AstroCtrl                              # noqa: E402
from astronova.model import CtrlModel, IdealPayload, simulate_timeline  # noqa: E402


class ModelMMIO:
    """MMIO stand-in: every access is one clock cycle of the model, with an
    ideal payload attached. `idle(n)` lets time pass."""

    def __init__(self, **defaults):
        d = dict(R.DEFAULTS)
        d.update(defaults)
        self.ctrl = CtrlModel(defaults=d)
        self.pl = IdealPayload(latency=3)
        self._cycle(rst=1)

    def _cycle(self, **kw):
        o = self.ctrl.step(sw_ack=self.pl.ack, pl_mode=self.pl.mode, **kw)
        self.pl.step(o["sw_req"], o["sw_target"])
        return o

    def write(self, off, value):
        self._cycle(wr_en=1, wr_addr=off, wr_data=value)

    def read(self, off):
        return self._cycle(rd_addr=off)["rd_data"]

    def idle(self, n):
        for _ in range(n):
            self._cycle()


class TestFraming(unittest.TestCase):
    def test_crc_check_value(self):
        self.assertEqual(R.crc8(b"123456789"), 0xF4)       # CRC-8/SMBUS check value

    def test_telemetry_layout(self):
        w = R.telemetry_word(0x1234, 0x56, True)
        self.assertEqual(w, 0x01561234)
        self.assertEqual(R.telemetry_word(0x1234, 0x56, False), 0x00561234)

    def test_q88(self):
        self.assertEqual(R.q88(1.0), 0x100)
        self.assertEqual(R.q88(2.25), 0x240)


class TestPayloadGolden(unittest.TestCase):
    def test_zero_seed_maps_to_one(self):
        self.assertEqual(PL.seed_state(0)["lfsr"], 1)

    def test_iteration_count_and_determinism(self):
        a, b = PL.run(0x1234ABCD, 1000), PL.run(0x1234ABCD, 1000)
        self.assertEqual(a, b)
        self.assertEqual(a["cnt"], 1000)
        self.assertNotEqual(PL.run(0x1234ABCD, 999)["sig"], a["sig"])

    def test_known_value(self):
        # pinned to the value tb_system.v checks the RTL against
        self.assertEqual(PL.run(0x1234ABCD, 8000)["sig"], 0xFC0B8318)


class TestDriverOnModel(unittest.TestCase):
    def setUp(self):
        self.mmio = ModelMMIO(prescale=0)          # 1 cycle per tick
        self.drv = AstroCtrl(self.mmio)
        self.drv.configure(tick_s=1e-8 * 2, fresh_to_s=1e-8 * 2 * 200, dwell_dn_s=1e-8 * 2 * 50,
                           sw_timeout_s=1e-6, invalid_limit=3, recover_n=3, retry_max=3)

    def test_power_up_is_fail_safe(self):
        self.mmio.idle(20)
        st = self.drv.status()
        self.assertTrue(st["fallback"])
        self.assertEqual(st["mode_cmd"], "TMR")
        self.assertEqual(st["pl_mode"], "TMR")

    def test_normal_then_event(self):
        for _ in range(3):
            self.drv.send(R.q88(1.0))
        self.mmio.idle(200)
        self.assertEqual(self.drv.status()["mode_cmd"], "BASELINE")
        self.drv.send(R.q88(2.25))                 # GLE #77-sized enhancement
        self.mmio.idle(20)
        st = self.drv.status()
        self.assertEqual(st["level"], "ELEVATED")
        self.assertEqual(st["mode_cmd"], "TMR")
        c = self.drv.counters()                    # diag counters are not modelled
        self.assertIn("SW_DONE", c)

    def test_static_policy(self):
        self.drv.set_policy(static_mode=R.M_BASELINE)
        self.mmio.idle(20)
        self.assertEqual(self.drv.status()["mode_cmd"], "BASELINE")
        self.drv.set_policy(None)
        self.mmio.idle(20)
        self.assertEqual(self.drv.status()["mode_cmd"], "TMR")   # back to fallback

    def test_partial_configure_keeps_tick(self):
        presc = self.mmio.read(R.PRESCALE)
        self.drv.configure(elevated=(R.q88(2.0), R.q88(1.5)))
        self.assertEqual(self.mmio.read(R.PRESCALE), presc)
        self.assertEqual(self.mmio.read(R.TH_ELEV), R.thresholds(R.q88(2.0), R.q88(1.5)))

    def test_threshold_validation(self):
        with self.assertRaises(ValueError):
            self.drv.configure(elevated=(0x100, 0x200))


class TestTimeline(unittest.TestCase):
    CFG = {R.FRESH_TO: 30, R.DWELL_UP: 0, R.DWELL_DN: 60, R.SW_TO: 1000,
           R.LIMITS: R.limits(3, 2, 3)}

    def test_gle_profile(self):
        # one message per 5 ticks: quiet, a 2.25x enhancement for 100 ticks, quiet
        ev = [(t, R.q88(2.25 if 200 <= t < 300 else 1.0), True) for t in range(0, 600, 5)]
        trace = simulate_timeline(ev, self.CFG, 600)
        modes = [(t, m) for t, m, _, _ in trace]
        # start-up fallback (TMR) -> BASELINE -> TMR during the event -> BASELINE
        seq = [m for _, m in modes]
        collapsed = [m for i, m in enumerate(seq) if i == 0 or m != seq[i - 1]]
        self.assertEqual(collapsed[-3:], [R.M_BASELINE, R.M_TMR, R.M_BASELINE])
        t_up = next(t for t, m in modes if m == R.M_TMR and t >= 200)
        self.assertLess(t_up - 200, 3)
        t_down = next(t for t, m in modes if m == R.M_BASELINE and t > t_up)
        self.assertGreaterEqual(t_down - t_up, 60)    # DWELL_DN respected

    def test_dropout_forces_fallback(self):
        ev = [(t, R.q88(1.0), True) for t in range(0, 600, 5) if not 250 <= t < 350]
        trace = simulate_timeline(ev, self.CFG, 600)
        fb_on = [t for t, _, _, fb in trace if fb == 1 and t > 100]
        self.assertTrue(fb_on and 270 <= fb_on[0] <= 285)      # 30 ticks after the last message
        self.assertTrue(any(m == R.M_TMR for t, m, _, _ in trace if t > 250))


if __name__ == "__main__":
    unittest.main()
