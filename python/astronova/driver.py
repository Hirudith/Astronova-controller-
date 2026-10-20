"""PS-side driver for the Astronova controller on the PYNQ-Z2.

On the board:
    from pynq import Overlay
    from astronova.driver import AstroCtrl
    ol = Overlay("astronova.bit")
    ctrl = AstroCtrl.from_overlay(ol.astro_ctrl_axil_0)
    ctrl.configure(fresh_to_s=180, dwell_dn_s=600)
    ctrl.send(metric=q88(1.0))          # one telemetry message
    print(ctrl.status())

Anything with read(offset) / write(offset, value) works as `mmio`, which lets
the same code drive the cycle model in tests.
"""

import time

from . import payload as PL
from . import regs as R


class AstroCtrl:
    def __init__(self, mmio, clk_hz=100_000_000):
        self.mmio = mmio
        self.clk_hz = clk_hz
        self._seq = 0
        ident = self.read(R.ID)
        if ident != R.ASTRO_ID:
            raise RuntimeError(f"no Astronova controller at this address (ID=0x{ident:08x})")

    @classmethod
    def from_overlay(cls, ip, clk_hz=100_000_000):
        return cls(ip.mmio, clk_hz)

    def read(self, off):
        return self.mmio.read(off) & 0xFFFFFFFF

    def write(self, off, value):
        self.mmio.write(off, value & 0xFFFFFFFF)

    # -- configuration ----------------------------------------------------------
    @property
    def tick_s(self):
        return (self.read(R.PRESCALE) + 1) / self.clk_hz

    def configure(self, tick_s=None, fresh_to_s=None, dwell_up_s=None, dwell_dn_s=None,
                  sw_timeout_s=None, elevated=None, extreme=None, modes=None,
                  invalid_limit=None, recover_n=None, retry_max=None,
                  fallback_hold=None):
        """Set any subset of parameters. Times in seconds; elevated / extreme
        are (rise, fall) metric pairs; modes is (normal, elevated, extreme,
        fallback). Unspecified items keep their current value; times are
        converted with the new tick if tick_s is given, else the current one."""
        if tick_s is not None:
            presc = int(round(tick_s * self.clk_hz)) - 1
            if not 0 <= presc < 1 << 24:
                raise ValueError("tick_s out of range")
            self.write(R.PRESCALE, presc)      # restarts the tick period
        tick = self.tick_s

        def ticks(s):
            return min(0xFFFFFFFF, int(round(s / tick)))

        if fresh_to_s is not None:
            self.write(R.FRESH_TO, ticks(fresh_to_s))
        if dwell_up_s is not None:
            self.write(R.DWELL_UP, ticks(dwell_up_s))
        if dwell_dn_s is not None:
            self.write(R.DWELL_DN, ticks(dwell_dn_s))
        if sw_timeout_s is not None:
            self.write(R.SW_TO, min(0xFFFFFFFF, int(round(sw_timeout_s * self.clk_hz))))
        for th, off in ((elevated, R.TH_ELEV), (extreme, R.TH_EXTR)):
            if th is not None:
                rise, fall = th
                if fall > rise:
                    raise ValueError("fall threshold must not exceed rise threshold")
                self.write(off, R.thresholds(rise, fall))
        if modes is not None:
            self.write(R.MODE_MAP, R.mode_map(*modes))
        if None not in (invalid_limit, recover_n, retry_max):
            self.write(R.LIMITS, R.limits(invalid_limit, recover_n, retry_max))
        elif any(v is not None for v in (invalid_limit, recover_n, retry_max)):
            cur = self.read(R.LIMITS)
            il = cur & 0xFF if invalid_limit is None else invalid_limit
            rn = (cur >> 8) & 0xFF if recover_n is None else recover_n
            rm = (cur >> 16) & 0xF if retry_max is None else retry_max
            self.write(R.LIMITS, R.limits(il, rn, rm))
        if fallback_hold is not None:
            ctrl = self.read(R.CTRL) & ~R.CTRL_FB_HOLD
            self.write(R.CTRL, ctrl | (R.CTRL_FB_HOLD if fallback_hold else 0))

    def set_policy(self, static_mode=None):
        """static_mode=None: adaptive (P2/P3/P4). Otherwise hold that mode
        regardless of telemetry (P0 = BASELINE, P1 = TMR)."""
        ctrl = self.read(R.CTRL) & R.CTRL_FB_HOLD
        if static_mode is not None:
            ctrl |= R.CTRL_STATIC_EN | ((static_mode & 3) << R.CTRL_STATIC_SHIFT)
        self.write(R.CTRL, ctrl)

    # -- telemetry ------------------------------------------------------------------
    def send(self, metric, source_ok=True):
        """Send one telemetry message; returns the word that was committed."""
        self._seq = (self._seq + 1) & 0xFF
        word = R.telemetry_word(metric, self._seq, source_ok)
        self.write(R.TDATA, word)
        self.write(R.TCRC, R.crc8_word(word))
        return word

    # -- commands -------------------------------------------------------------------
    def clear_fault(self):
        self.write(R.CMD, R.CMD_CLEAR_FAULT)

    def soft_reset(self):
        self.write(R.CMD, R.CMD_SOFT_RESET)
        self._seq = 0

    def clear_diag(self):
        self.write(R.CMD, R.CMD_CLEAR_DIAG)

    # -- read-back --------------------------------------------------------------------
    def status(self):
        st = R.decode_status(self.read(R.STATUS))
        ts = self.read(R.TSTAT)
        st.update(metric=ts & 0xFFFF, last_seq=(ts >> 16) & 0xFF,
                  last_reject=(ts >> 25) & 0xF,
                  age_ticks=self.read(R.AGE), dwell_ticks=self.read(R.DWELL))
        return st

    def counters(self):
        c = {name: self.read(R.DIAG_EVENT_BASE + 4 * i) for i, name in enumerate(R.EVENTS)}
        c["last_switch_cycles"] = self.read(R.LAST_LAT)
        c["max_switch_cycles"] = self.read(R.MAX_LAT)
        c["tmr_err_cycles"] = self.read(R.TMR_ERR)
        c["sticky"] = self.read(R.STICKY)
        return c

    def cycles(self):
        hi = self.read(R.CYCLE_HI)
        lo = self.read(R.CYCLE_LO)
        if self.read(R.CYCLE_HI) != hi:      # low word wrapped between reads
            lo = self.read(R.CYCLE_LO)
            hi = self.read(R.CYCLE_HI)
        return (hi << 32) | lo


class Payload:
    """PS-side control of the switchable payload (rtl/payload/pl_axil.v)."""

    def __init__(self, mmio):
        self.mmio = mmio
        ident = self.read(PL.ID)
        if ident != PL.PAYLOAD_ID:
            raise RuntimeError(f"no Astronova payload at this address (ID=0x{ident:08x})")
        self.variant = (self.read(PL.VERSION) >> 16) & 0xFF

    @classmethod
    def from_overlay(cls, ip):
        return cls(ip.mmio)

    def read(self, off):
        return self.mmio.read(off) & 0xFFFFFFFF

    def write(self, off, value):
        self.mmio.write(off, value & 0xFFFFFFFF)

    def start(self, seed, iterations):
        """Restart the workload from `seed`; it stops after `iterations`."""
        self.write(PL.CTRL, 0)
        self.write(PL.SEED, seed)
        self.write(PL.STOP_AT, iterations)
        self.write(PL.CMD, PL.CMD_CLEAR | PL.CMD_CLEAR_DIAG)
        self.write(PL.CTRL, 1)

    def done(self):
        return bool(self.read(PL.STATUS) >> 5 & 1)

    def wait(self, timeout_s=10.0, poll_s=1e-3):
        t0 = time.monotonic()
        while not self.done():
            if time.monotonic() - t0 > timeout_s:
                return False                         # hang
            time.sleep(poll_s)
        return True

    def result(self):
        return {"lfsr": self.read(PL.LFSR), "acc": self.read(PL.ACC),
                "sig": self.read(PL.SIG), "cnt": self.read(PL.CNT)}

    def check(self, seed, iterations):
        """'ok', 'sdc' (silent data corruption) or 'hang', against the golden model."""
        if not self.done():
            return "hang"
        return "ok" if self.result() == PL.run(seed, iterations) else "sdc"

    def status(self):
        v = self.read(PL.STATUS)
        return {"pl_mode": R.MODE_NAMES[v & 3], "active": (v >> 2) & 7, "done": bool(v >> 5 & 1),
                "variant": PL.VARIANTS.get(self.variant, "?"),
                "dmr_err_cycles": self.read(PL.DMR_ERR), "tmr_err_cycles": self.read(PL.TMR_ERR),
                "switches": self.read(PL.SWITCHES),
                "mode_cycles": [self.read(a) for a in PL.MODE_CYC]}
