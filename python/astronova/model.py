"""Cycle-accurate reference model of the Astronova controller core.

`CtrlModel.step()` mirrors one clock cycle of rtl/astro_ctrl_core.v in the same
order. tb/tb_cosim.v replays traces produced with this model and compares the
RTL outputs and register read-back on every cycle, so the model can also be
trusted as the policy m(t) inside the Block 5 evaluation engine
(see `simulate_timeline`).
"""

from . import regs as R

M32 = 0xFFFFFFFF

_CFG = ("c_ctrl", "c_presc", "c_fresh", "c_dup", "c_ddn", "c_swto",
        "c_er", "c_ef", "c_xr", "c_xf", "c_map", "c_invl", "c_recn", "c_retry")


def _sat(v, mask):
    return v if v == mask else v + 1


def next_level(lv, m, er, ef, xr, xf):
    if lv == R.LV_NORMAL:
        return R.LV_EXTREME if m >= xr else R.LV_ELEVATED if m >= er else R.LV_NORMAL
    if lv == R.LV_ELEVATED:
        return R.LV_EXTREME if m >= xr else R.LV_NORMAL if m < ef else R.LV_ELEVATED
    if lv == R.LV_EXTREME:
        return R.LV_EXTREME if m >= xf else R.LV_NORMAL if m < ef else R.LV_ELEVATED
    return R.LV_EXTREME if m >= xr else R.LV_ELEVATED if m >= er else R.LV_NORMAL


class CtrlModel:
    """One controller core. `step()` takes this cycle's inputs, returns this
    cycle's outputs (before the clock edge) and advances the state."""

    def __init__(self, defaults=None, build_tmr=1):
        self.defaults = dict(R.DEFAULTS if defaults is None else defaults)
        self.build_tmr = build_tmr
        self.s = {}
        self._reset_cfg(self.s)
        self._reset_dyn(self.s)

    # -- resets -------------------------------------------------------------
    def _reset_dyn(self, s):
        s.update(fsm=R.S_INIT, presc=0, age=M32, dwell=M32, wd=0, metric=0, lseq=0,
                 hseq=0, level=R.LV_NORMAL, invc=0, recc=0, fb=1, cur=R.M_BASELINE,
                 tgt=R.M_BASELINE, fails=0, rej=0, tdata=0)

    def _reset_cfg(self, s):
        d = self.defaults
        s.update(c_ctrl=d["ctrl"], c_presc=d["prescale"], c_fresh=d["fresh_to"],
                 c_dup=d["dwell_up"], c_ddn=d["dwell_dn"], c_swto=d["sw_to"],
                 c_er=d["th_elev"] & 0xFFFF, c_ef=d["th_elev"] >> 16,
                 c_xr=d["th_extr"] & 0xFFFF, c_xf=d["th_extr"] >> 16,
                 c_map=d["mode_map"], c_invl=d["limits"] & 0xFF,
                 c_recn=(d["limits"] >> 8) & 0xFF, c_retry=(d["limits"] >> 16) & 0xF)

    # -- one clock cycle ------------------------------------------------------
    def step(self, rst=0, wr_en=0, wr_addr=0, wr_data=0, rd_addr=0, sw_ack=0, pl_mode=0):
        """wr_addr / rd_addr are byte offsets. Returns a dict of outputs."""
        q = self.s
        d = dict(q)
        ev = 0
        wa = (wr_addr >> 2) & 0x3F

        # 1. tick prescaler
        tick = q["presc"] == 0
        d["presc"] = q["c_presc"] if tick else q["presc"] - 1

        # 2. register writes
        cmd_clr = wr_en and wa == R.CMD >> 2 and wr_data & R.CMD_CLEAR_FAULT
        cmd_srst = wr_en and wa == R.CMD >> 2 and wr_data & R.CMD_SOFT_RESET
        commit = wr_en and wa == R.TCRC >> 2
        if wr_en:
            a = wa << 2
            if a == R.CTRL:
                d["c_ctrl"] = wr_data & 0xF
            elif a == R.TDATA:
                d["tdata"] = wr_data
            elif a == R.PRESCALE:                     # new period starts now
                d["c_presc"] = wr_data & 0xFFFFFF
                d["presc"] = wr_data & 0xFFFFFF
            elif a == R.FRESH_TO:
                d["c_fresh"] = wr_data
            elif a == R.DWELL_UP:
                d["c_dup"] = wr_data
            elif a == R.DWELL_DN:
                d["c_ddn"] = wr_data
            elif a == R.SW_TO:
                d["c_swto"] = wr_data
            elif a == R.TH_ELEV:
                d["c_er"], d["c_ef"] = wr_data & 0xFFFF, wr_data >> 16
            elif a == R.TH_EXTR:
                d["c_xr"], d["c_xf"] = wr_data & 0xFFFF, wr_data >> 16
            elif a == R.MODE_MAP:
                d["c_map"] = wr_data & 0xFF
            elif a == R.LIMITS:
                d["c_invl"] = wr_data & 0xFF
                d["c_recn"] = (wr_data >> 8) & 0xFF
                d["c_retry"] = (wr_data >> 16) & 0xF

        # 3. telemetry commit
        td = q["tdata"]
        seq = (td >> 16) & 0xFF
        diff = (seq - q["lseq"]) & 0xFF
        rej = 0
        if (wr_data & 0xFF) != R.crc8_word(td):
            rej |= R.RJ_CRC
        if (td >> 25) & 0x7F:
            rej |= R.RJ_RSVD
        if not (td >> 24) & 1:
            rej |= R.RJ_SRC
        if q["hseq"] and (diff == 0 or diff & 0x80):
            rej |= R.RJ_SEQ
        accept = commit and rej == 0
        reject = commit and rej != 0
        if accept:
            d["metric"] = td & 0xFFFF
            d["lseq"] = seq
            d["hseq"] = 1
            d["age"] = 0
            d["invc"] = 0
            d["recc"] = _sat(q["recc"], 0xFF)
            d["level"] = next_level(q["level"], td & 0xFFFF, q["c_er"], q["c_ef"], q["c_xr"], q["c_xf"])
            ev |= 1 << R.EV["ACCEPT"]
        else:
            if reject:
                d["invc"] = _sat(q["invc"], 0xFF)
                d["recc"] = 0
                d["rej"] = rej
                ev |= 1 << R.EV["REJECT"]
            if tick:
                d["age"] = _sat(q["age"], M32)

        # 4. dwell timer
        if tick:
            d["dwell"] = _sat(q["dwell"], M32)

        # 5. fallback
        stale = q["c_fresh"] != 0 and q["age"] >= q["c_fresh"]
        inval = q["c_invl"] != 0 and q["invc"] >= q["c_invl"]
        fb_cond = stale or inval
        if not q["fb"]:
            if fb_cond:
                d["fb"] = 1
                d["recc"] = 0
                ev |= 1 << R.EV["FB_ENTER"]
        elif not fb_cond and q["recc"] >= q["c_recn"]:
            d["fb"] = 0
            ev |= 1 << R.EV["FB_EXIT"]

        # 6. desired mode
        cmap = q["c_map"]
        map_mode = (cmap >> (2 * q["level"])) & 3     # level 3 selects the fallback field
        static_en = (q["c_ctrl"] >> 1) & 1
        if static_en:
            desired = (q["c_ctrl"] >> 2) & 3
        elif q["fb"]:
            desired = q["cur"] if q["c_ctrl"] & 1 else (cmap >> 6) & 3
        else:
            desired = map_mode
        force_sw = static_en or q["fb"]
        if desired > q["cur"]:
            allowed = force_sw or q["dwell"] >= q["c_dup"]
        else:
            allowed = force_sw or q["dwell"] >= q["c_ddn"]

        # 7. FSM
        timeout = q["c_swto"] != 0 and q["wd"] >= q["c_swto"]
        fails_n = q["fails"] if q["fails"] == 0xF else q["fails"] + 1

        def fail():
            nonlocal ev
            d["fails"] = fails_n
            d["fsm"] = R.S_FAULT if (q["c_retry"] != 0 and fails_n >= q["c_retry"]) else R.S_INIT
            d["wd"] = 0
            ev |= 1 << R.EV["SW_FAIL"]

        fsm = q["fsm"]
        if fsm == R.S_INIT:
            if not sw_ack:
                d["cur"] = pl_mode
                d["fsm"] = R.S_IDLE
                d["wd"] = 0
            elif timeout:
                fail()
            else:
                d["wd"] = _sat(q["wd"], M32)
        elif fsm == R.S_IDLE:
            d["wd"] = 0
            if not sw_ack:
                if pl_mode != q["cur"]:
                    d["tgt"] = q["cur"]
                    d["fsm"] = R.S_REQ
                    ev |= (1 << R.EV["MISMATCH"]) | (1 << R.EV["SW_START"])
                elif desired != q["cur"] and allowed:
                    d["tgt"] = desired
                    d["fsm"] = R.S_REQ
                    ev |= 1 << R.EV["SW_START"]
        elif fsm == R.S_REQ:
            if sw_ack:
                if pl_mode == q["tgt"]:
                    d["wd"] = 0
                    d["cur"] = q["tgt"]
                    d["dwell"] = 0
                    d["fails"] = 0
                    d["fsm"] = R.S_REL
                    ev |= 1 << R.EV["SW_DONE"]
                else:
                    fail()
            elif timeout:
                fail()
            else:
                d["wd"] = _sat(q["wd"], M32)
        elif fsm == R.S_REL:
            if not sw_ack:
                d["fsm"] = R.S_IDLE
                d["wd"] = 0
            elif timeout:
                fail()
            else:
                d["wd"] = _sat(q["wd"], M32)
        elif fsm == R.S_FAULT:
            d["wd"] = 0
            if cmd_clr:
                d["fsm"] = R.S_INIT
                d["fails"] = 0
        else:
            d["fsm"] = R.S_INIT
            d["wd"] = 0
            ev |= 1 << R.EV["ILLEGAL"]

        # 8. resets
        if cmd_srst or rst:
            self._reset_dyn(d)
            ev = 0
        if rst:
            self._reset_cfg(d)

        # outputs (functions of the current state; events also of the inputs)
        out = {
            "sw_req": int(fsm == R.S_REQ),
            "sw_target": q["tgt"],
            "mode_cmd": q["cur"],
            "level": q["level"],
            "fallback": q["fb"],
            "fault": int(fsm == R.S_FAULT),
            "busy": int(fsm in (R.S_REQ, R.S_REL)),
            "events": ev,
            "rd_data": self._read(rd_addr, q, sw_ack, pl_mode, desired, stale, inval),
        }
        self.s = d
        return out

    def _read(self, addr, q, sw_ack, pl_mode, desired, stale, inval):
        a = addr & 0xFC
        fsm = q["fsm"]
        if a == R.ID:
            return R.ASTRO_ID
        if a == R.VERSION:
            return (self.build_tmr << 16) | (R.VER_MAJOR << 8) | R.VER_MINOR
        if a == R.CTRL:
            return q["c_ctrl"]
        if a == R.STATUS:
            return (fsm | q["level"] << 3 | q["cur"] << 5 | q["tgt"] << 7 | q["fb"] << 9
                    | int(stale) << 10 | int(inval) << 11 | int(fsm == R.S_FAULT) << 12
                    | int(fsm in (R.S_REQ, R.S_REL)) << 13 | int(fsm == R.S_REQ) << 14
                    | sw_ack << 15 | pl_mode << 16 | desired << 18)
        if a == R.TSTAT:
            return q["metric"] | q["lseq"] << 16 | q["hseq"] << 24 | q["rej"] << 25
        table = {
            R.AGE: q["age"], R.DWELL: q["dwell"], R.TDATA: q["tdata"],
            R.PRESCALE: q["c_presc"], R.FRESH_TO: q["c_fresh"], R.DWELL_UP: q["c_dup"],
            R.DWELL_DN: q["c_ddn"], R.SW_TO: q["c_swto"],
            R.TH_ELEV: q["c_ef"] << 16 | q["c_er"], R.TH_EXTR: q["c_xf"] << 16 | q["c_xr"],
            R.MODE_MAP: q["c_map"],
            R.LIMITS: q["c_retry"] << 16 | q["c_recn"] << 8 | q["c_invl"],
            R.RTCNT: q["fails"] << 16 | q["recc"] << 8 | q["invc"],
            R.WD: q["wd"],
        }
        return table.get(a, 0)


class IdealPayload:
    """Payload that completes every switch after `latency` cycles and releases
    sw_ack one cycle after sw_req drops."""

    def __init__(self, mode=R.M_BASELINE, latency=4):
        self.mode, self.ack, self.latency = mode, 0, latency
        self._count = None

    def step(self, sw_req, sw_target):
        if sw_req and not self.ack:
            if self._count is None:
                self._count = self.latency
            self._count -= 1
            if self._count <= 0:
                self.mode, self.ack, self._count = sw_target, 1, None
        elif not sw_req:
            self.ack, self._count = 0, None


def simulate_timeline(events, config, horizon, latency=2, cycles_per_tick=4):
    """Run the controller policy over a telemetry timeline.

    events  : iterable of (tick, metric, source_ok), sorted by tick. Each entry
              is one telemetry message; a source dropout is simply a gap.
    config  : dict of byte-offset -> value written after reset (e.g. from regs).
    horizon : number of ticks to simulate. cycles_per_tick must leave room for
              the two bus writes of each message (default 4).
    Returns a list of (tick, mode, level, fallback) at every change of state,
    i.e. the m(t) used by the Block 5 evaluation engine.
    """
    ctrl = CtrlModel()
    pl = IdealPayload(latency=latency)
    ctrl.step(rst=1)
    writes = [(a, v) for a, v in config.items()]
    writes.append((R.PRESCALE, cycles_per_tick - 1))
    for a, v in writes:
        ctrl.step(wr_en=1, wr_addr=a, wr_data=v, sw_ack=pl.ack, pl_mode=pl.mode)

    events = list(events)
    i, seq, trace, last = 0, 0, [], None
    for t in range(horizon):
        pending = []
        while i < len(events) and events[i][0] <= t:
            _, metric, ok = events[i]
            seq = (seq + 1) & 0xFF
            w = R.telemetry_word(metric, seq, ok)
            pending += [(R.TDATA, w), (R.TCRC, R.crc8_word(w))]
            i += 1
        for c in range(cycles_per_tick):
            if pending:
                a, v = pending.pop(0)
                o = ctrl.step(wr_en=1, wr_addr=a, wr_data=v, sw_ack=pl.ack, pl_mode=pl.mode)
            else:
                o = ctrl.step(sw_ack=pl.ack, pl_mode=pl.mode)
            pl.step(o["sw_req"], o["sw_target"])
        while pending:      # more messages than cycles in this tick
            a, v = pending.pop(0)
            o = ctrl.step(wr_en=1, wr_addr=a, wr_data=v, sw_ack=pl.ack, pl_mode=pl.mode)
            pl.step(o["sw_req"], o["sw_target"])
        s = ctrl.s
        state = (pl.mode, s["level"], s["fb"])
        if state != last:
            trace.append((t,) + state)
            last = state
    return trace
