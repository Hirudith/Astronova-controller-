"""Fast tick-level simulation of the controller's policy, for long timelines.

The cycle-accurate model (model.py) matches the RTL on every clock cycle but
needs several cycles per tick. This simulator applies the same decision rules
once per tick, with an ideal payload that switches within the tick. On random
timelines it reproduces the cycle-accurate switch sequence (tests/test_analysis.py
checks this against model.py on randomised timelines).
"""

from dataclasses import dataclass, field

import numpy as np

from . import regs as R
from .model import next_level

INF = 1 << 62


@dataclass
class PolicyConfig:
    """Controller settings, times in ticks (the analysis uses 1 tick = 1 min)."""
    fresh_to: int = 3              # stale after this many ticks without an accepted message
    dwell_up: int = 0
    dwell_dn: int = 10
    invalid_limit: int = 3
    recover_n: int = 3
    elev: tuple = (R.q88(1.5), R.q88(1.25))       # (rise, fall)
    extr: tuple = (R.q88(4.0), R.q88(3.0))
    modes: tuple = (R.M_BASELINE, R.M_TMR, R.M_TMR, R.M_TMR)   # NORMAL, ELEVATED, EXTREME, FALLBACK
    fb_hold: bool = False
    static_mode: int = None        # P0 / P1 when set

    def registers(self):
        """The same settings as controller register writes (byte offset -> value)."""
        ctrl = int(self.fb_hold)
        if self.static_mode is not None:
            ctrl |= R.CTRL_STATIC_EN | (self.static_mode << R.CTRL_STATIC_SHIFT)
        return {R.FRESH_TO: self.fresh_to, R.DWELL_UP: self.dwell_up, R.DWELL_DN: self.dwell_dn,
                R.TH_ELEV: R.thresholds(*self.elev), R.TH_EXTR: R.thresholds(*self.extr),
                R.MODE_MAP: R.mode_map(*self.modes),
                R.LIMITS: R.limits(self.invalid_limit, self.recover_n, 3), R.CTRL: ctrl}


@dataclass
class PolicyTrace:
    mode: np.ndarray                     # mode per tick
    fallback: np.ndarray
    level: np.ndarray
    switches: list = field(default_factory=list)    # (tick, from, to)


def simulate(messages, horizon, cfg=PolicyConfig(), start_mode=R.M_TMR, settled=True):
    """messages: iterable of (tick, metric, source_ok), any order.

    Each tick follows the order the hardware runs in when the PS writes a
    tick's messages at its start: (A) decide on the state left by the previous
    tick, (B) take the tick's messages, (C) decide again, (D) advance the
    timers at the tick boundary. The controller starts in fallback, already
    switched to the fallback mode before tick 0. settled=True: that start-up
    switch happened long ago (dwell expired); False: just before tick 0."""
    by_tick = {}
    for t, m, ok in messages:
        by_tick.setdefault(int(t), []).append((m, ok))

    er, ef = cfg.elev
    xr, xf = cfg.extr
    st = {"level": R.LV_NORMAL, "fb": True, "recc": 0, "invc": 0, "age": INF, "dwell": INF,
          "cur": start_mode}
    mode = np.empty(horizon, dtype=np.int8)
    fbs = np.empty(horizon, dtype=bool)
    lvl = np.empty(horizon, dtype=np.int8)
    switches = []

    def switch(t):
        cur = st["cur"]
        if cfg.static_mode is not None:
            desired, force = cfg.static_mode, True
        elif st["fb"]:
            desired, force = (cur if cfg.fb_hold else cfg.modes[3]), True
        else:
            desired, force = cfg.modes[min(st["level"], 3)], False
        if desired != cur:
            limit = cfg.dwell_up if desired > cur else cfg.dwell_dn
            if force or st["dwell"] >= limit:
                if t >= 0:
                    switches.append((t, cur, desired))
                st["cur"], st["dwell"] = desired, 0

    def decide(t):
        # as in hardware, the cycle that updates the fallback flag still decides
        # on the old flag; a changed flag is acted on once that switch is done
        stale = cfg.fresh_to != 0 and st["age"] >= cfg.fresh_to
        inval = cfg.invalid_limit != 0 and st["invc"] >= cfg.invalid_limit
        fb_old = st["fb"]
        switch(t)
        if not st["fb"] and (stale or inval):
            st["fb"], st["recc"] = True, 0
        elif st["fb"] and not (stale or inval) and st["recc"] >= cfg.recover_n:
            st["fb"] = False
        if st["fb"] != fb_old:
            switch(t)

    decide(-1)                                          # start-up switch, before tick 0
    if settled:
        st["dwell"] = INF
    for t in range(horizon):
        decide(t)                                       # (A)
        msgs = by_tick.get(t)
        if msgs:                                        # (B)
            for m, ok in msgs:
                if ok:
                    st["level"] = next_level(st["level"], m, er, ef, xr, xf)
                    st["age"], st["invc"], st["recc"] = 0, 0, st["recc"] + 1
                else:
                    st["invc"], st["recc"] = st["invc"] + 1, 0
            decide(t)                                   # (C)
        if st["age"] < INF:                             # (D)
            st["age"] += 1
        if st["dwell"] < INF:
            st["dwell"] += 1
        mode[t], fbs[t], lvl[t] = st["cur"], st["fb"], st["level"]
    return PolicyTrace(mode, fbs, lvl, switches)
