"""Golden model of the reference workload in rtl/payload/pl_workload.v, and the
payload register map (rtl/payload/pl_axil.v).

    python3 -m astronova.payload --seed 0x1234 --n 5000      # final state
"""

import argparse

M32 = 0xFFFFFFFF

# payload register map (byte offsets)
ID, VERSION, CTRL, CMD, SEED, STOP_AT, STATUS = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18
CNT, SIG, ACC, LFSR = 0x1C, 0x20, 0x24, 0x28
DMR_ERR, TMR_ERR, SWITCHES, STICKY = 0x2C, 0x30, 0x34, 0x38
MODE_CYC = (0x40, 0x44, 0x48, 0x4C)
PAYLOAD_ID = 0x504C4430                      # "PLD0"
CMD_CLEAR, CMD_CLEAR_DIAG = 1, 2
VARIANTS = {0: "BASELINE", 1: "STATIC_TMR", 2: "SWITCHABLE"}


def seed_state(seed):
    return {"lfsr": (seed & M32) or 1, "acc": 0, "sig": 0, "cnt": 0}


def step(s):
    lfsr = (s["lfsr"] >> 1) ^ (0x80200003 if s["lfsr"] & 1 else 0)
    acc = (s["acc"] * 0x9E3779B1 + lfsr) & M32
    sig = (((s["sig"] << 5) | (s["sig"] >> 27)) & M32) ^ acc
    return {"lfsr": lfsr, "acc": acc, "sig": sig, "cnt": (s["cnt"] + 1) & M32}


def run(seed, n):
    """State after n iterations from the seed (what the payload holds once it
    stops at STOP_AT = n)."""
    s = seed_state(seed)
    for _ in range(n):
        s = step(s)
    return s


def main():
    ap = argparse.ArgumentParser(description="reference workload golden model")
    ap.add_argument("--seed", type=lambda v: int(v, 0), required=True)
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--plusargs", metavar="PREFIX",
                    help="print as simulator plusargs +PREFIX_SIG=... etc.")
    a = ap.parse_args()
    s = run(a.seed, a.n)
    if a.plusargs:
        p = a.plusargs
        print(f"+{p}_SEED={a.seed & M32:08x} +{p}_N={a.n} +{p}_SIG={s['sig']:08x} "
              f"+{p}_ACC={s['acc']:08x} +{p}_LFSR={s['lfsr']:08x}")
    else:
        print(" ".join(f"{k}=0x{v:08x}" for k, v in s.items()))


if __name__ == "__main__":
    main()
