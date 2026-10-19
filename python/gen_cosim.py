#!/usr/bin/env python3
"""Generate a randomised closed-loop trace for tb/tb_cosim.v.

The reference model runs against a stochastic payload (slow, wrong-mode,
stuck-ack and spontaneous mode changes included) and a stochastic PS writer
(corrupted telemetry, config changes, soft and hard resets). Each line of the
output holds one cycle: the 64-bit input word and the 64-bit expected output.

  inputs  [63] rst [62] wr_en [61:56] wr_addr(word) [55:24] wr_data
          [23] sw_ack [22:21] pl_mode [20:15] rd_addr(word)
  expect  [63:32] rd_data [18:0] {events, busy, fault, fallback, level,
          mode_cmd, sw_target, sw_req}
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from astronova import regs as R             # noqa: E402
from astronova.model import CtrlModel       # noqa: E402

# Sim-scale configuration written after every hard reset
SIM_CFG = [
    (R.PRESCALE, 3),
    (R.FRESH_TO, 60),
    (R.DWELL_UP, 0),
    (R.DWELL_DN, 40),
    (R.SW_TO, 80),
    (R.TH_ELEV, R.thresholds(0x180, 0x140)),
    (R.TH_EXTR, R.thresholds(0x400, 0x300)),
    (R.MODE_MAP, R.mode_map(R.M_BASELINE, R.M_TMR, R.M_TMR_PLUS, R.M_TMR)),
    (R.LIMITS, R.limits(3, 2, 3)),
]


class StochasticPayload:
    """Payload with random latency and occasional misbehaviour. Its outputs
    are registered: step() computes the values seen next cycle."""

    def __init__(self, rng, flaky):
        self.rng, self.flaky = rng, flaky
        self.mode, self.ack = rng.randrange(4), 0
        self.state, self.count, self.target = "idle", 0, 0
        self.ack_mode = 0

    def step(self, sw_req, sw_target):
        rng, p = self.rng, self.flaky
        if self.state == "idle":
            if sw_req:
                self.target = sw_target
                r = rng.random()
                if r < p * 0.3:
                    self.state, self.count = "switching", rng.randint(90, 200)   # too slow
                elif r < p * 0.5:
                    self.state, self.count = "switching", 1 << 30               # never answers
                else:
                    self.state, self.count = "switching", rng.randint(1, 40)
                self.ack_mode = rng.randrange(4) if rng.random() < p * 0.3 else sw_target
            else:
                if rng.random() < p * 0.002:
                    self.mode = rng.randrange(4)              # spontaneous mode change
                if rng.random() < p * 0.001:
                    self.state, self.count, self.ack = "spurious", rng.randint(1, 120), 1
        elif self.state == "switching":
            if not sw_req:                                    # controller gave up
                self.mode = rng.choice([self.mode, self.target])
                self.state = "idle"
            else:
                self.count -= 1
                if self.count <= 0:
                    self.mode, self.ack, self.state = self.ack_mode, 1, "acked"
        elif self.state == "acked":
            if not sw_req:
                stuck = rng.random() < p * 0.2
                self.state = "releasing"
                self.count = rng.randint(90, 200) if stuck else rng.randint(0, 6)
        elif self.state == "releasing":
            self.count -= 1
            if self.count <= 0:
                self.ack, self.state = 0, "idle"
        elif self.state == "spurious":
            self.count -= 1
            if self.count <= 0:
                self.ack, self.state = 0, "idle"


class PsWriter:
    """Queue of register writes that a PS process would issue."""

    def __init__(self, rng):
        self.rng = rng
        self.queue = []
        self.seq = 0
        self.metric = 0x100

    def configure(self):
        self.queue += list(SIM_CFG)

    def telemetry(self):
        rng = self.rng
        # random walk with jumps across all thresholds
        if rng.random() < 0.15:
            self.metric = rng.choice([0x0F0, 0x150, 0x17F, 0x180, 0x2FF, 0x300, 0x3FF, 0x400, 0x900])
        else:
            self.metric = max(0, min(0xFFFF, self.metric + rng.randint(-0x60, 0x60)))
        self.seq = (self.seq + (1 if rng.random() < 0.9 else rng.randint(2, 140))) & 0xFF
        word = R.telemetry_word(self.metric, self.seq, rng.random() > 0.05)
        crc = R.crc8_word(word)
        r = rng.random()
        if r < 0.05:
            crc ^= 1 << rng.randrange(8)                       # corrupted CRC
        elif r < 0.08:
            word |= 1 << rng.randint(25, 31)                   # reserved bit set
            crc = R.crc8_word(word)
        elif r < 0.11:
            word = (word & ~0xFF0000) | (((self.seq - rng.randint(0, 3)) & 0xFF) << 16)  # replay
            crc = R.crc8_word(word)
        self.queue += [(R.TDATA, word), (R.TCRC, crc)]

    def random_config(self):
        rng = self.rng
        choice = rng.randrange(7)
        if choice == 0:
            self.queue.append((R.CTRL, rng.randrange(16) if rng.random() < 0.5 else 0))
        elif choice == 1:
            self.queue.append((R.DWELL_DN, rng.choice([0, 5, 40, 100])))
        elif choice == 2:
            self.queue.append((R.DWELL_UP, rng.choice([0, 0, 10, 30])))
        elif choice == 3:
            self.queue.append((R.MODE_MAP, rng.randrange(256)))
        elif choice == 4:
            self.queue.append((R.LIMITS, R.limits(rng.randrange(5), rng.randrange(4), rng.randrange(5))))
        elif choice == 5:
            self.queue.append((R.SW_TO, rng.choice([0, 30, 80, 300])))
        else:
            self.queue.append((R.FRESH_TO, rng.choice([0, 20, 60, 200])))


def generate(n_cycles, seed, out_path):
    rng = random.Random(seed)
    ctrl = CtrlModel(build_tmr=1)
    payload = StochasticPayload(rng, flaky=0.3)
    ps = PsWriter(rng)
    gap = 0
    lines = []
    ev_hits = [0] * len(R.EVENTS)
    fsm_hits = [0] * 8
    level_hits = [0] * 4
    mode_hits = [0] * 4
    rd_words = list(range(0x00, 0x15)) + [0x15, 0x1F, 0x3F]

    for cyc in range(n_cycles):
        rst = 1 if cyc < 2 or rng.random() < 0.0002 else 0
        if rst:
            ps.queue.clear()
            ps.configure()
            payload.flaky = rng.choice([0.0, 0.1, 0.3, 0.8])
        wr_en, wr_addr, wr_data = 0, 0, 0
        if not rst:
            if not ps.queue:
                r = rng.random()
                if r < 0.03:
                    ps.telemetry()
                elif r < 0.0305:
                    ps.random_config()
                elif r < 0.0310:
                    ps.queue.append((R.CMD, R.CMD_CLEAR_FAULT))
                elif r < 0.0312:
                    ps.queue.append((R.CMD, R.CMD_SOFT_RESET))
                elif r < 0.0313:
                    ps.queue.append((R.CMD, R.CMD_CLEAR_DIAG | R.CMD_CLEAR_FAULT))
                elif r < 0.0315:
                    gap = rng.randint(100, 600)                # telemetry outage
            if gap:
                gap -= 1
            elif ps.queue and rng.random() < 0.7:
                wr_addr, wr_data = ps.queue.pop(0)
                wr_en = 1
        rd_addr = rng.choice(rd_words) << 2
        ack, mode = payload.ack, payload.mode

        o = ctrl.step(rst=rst, wr_en=wr_en, wr_addr=wr_addr, wr_data=wr_data,
                      rd_addr=rd_addr, sw_ack=ack, pl_mode=mode)
        payload.step(o["sw_req"], o["sw_target"])

        inp = (rst << 63 | wr_en << 62 | (wr_addr >> 2) << 56 | wr_data << 24
               | ack << 23 | mode << 21 | (rd_addr >> 2) << 15)
        out_bits = (o["sw_req"] | o["sw_target"] << 1 | o["mode_cmd"] << 3 | o["level"] << 5
                    | o["fallback"] << 7 | o["fault"] << 8 | o["busy"] << 9 | o["events"] << 10)
        exp = o["rd_data"] << 32 | out_bits
        lines.append(f"{inp:016x} {exp:016x}\n")
        for e in range(len(R.EVENTS)):
            ev_hits[e] += (o["events"] >> e) & 1
        fsm_hits[ctrl.s["fsm"]] += 1
        level_hits[o["level"]] += 1
        mode_hits[o["mode_cmd"]] += 1

    with open(out_path, "w") as f:
        f.writelines(lines)
    print(f"gen_cosim: {n_cycles} cycles, seed {seed} -> {out_path}")
    print("  events : " + ", ".join(f"{n}={c}" for n, c in zip(R.EVENTS, ev_hits)))
    print("  fsm    : " + ", ".join(f"{R.FSM_NAMES[i]}={fsm_hits[i]}" for i in range(5)))
    print("  level  : " + ", ".join(f"{R.LEVEL_NAMES[i]}={level_hits[i]}" for i in range(3)))
    print("  mode   : " + ", ".join(f"{R.MODE_NAMES[i]}={mode_hits[i]}" for i in range(4)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cycles", type=int, default=200_000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="cosim_trace.hex")
    a = ap.parse_args()
    generate(a.cycles, a.seed, a.out)


if __name__ == "__main__":
    main()
