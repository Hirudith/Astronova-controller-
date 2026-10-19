"""Register map, encodings and telemetry framing for the Astronova controller.

Mirrors rtl/astro_ctrl_defs.vh. The co-simulation (tb/tb_cosim.v) reads every
register through this map, so a mismatch with the RTL fails the test.
"""

# Byte offsets ---------------------------------------------------------------
ID = 0x00
VERSION = 0x04
CTRL = 0x08
CMD = 0x0C
STATUS = 0x10
TSTAT = 0x14
AGE = 0x18
DWELL = 0x1C
TDATA = 0x20
TCRC = 0x24
PRESCALE = 0x28
FRESH_TO = 0x2C
DWELL_UP = 0x30
DWELL_DN = 0x34
SW_TO = 0x38
TH_ELEV = 0x3C
TH_EXTR = 0x40
MODE_MAP = 0x44
LIMITS = 0x48
RTCNT = 0x4C
WD = 0x50

# Diagnostic counters (outside the TMR boundary)
DIAG_EVENT_BASE = 0x80     # + 4*event index, see EVENTS
LAST_LAT = 0xA4
MAX_LAT = 0xA8
TMR_ERR = 0xAC
CYCLE_LO = 0xB0
CYCLE_HI = 0xB4
STICKY = 0xB8

ASTRO_ID = 0x41535452      # "ASTR"
VER_MAJOR, VER_MINOR = 1, 0

# CMD bits
CMD_CLEAR_FAULT = 1 << 0
CMD_SOFT_RESET = 1 << 1
CMD_CLEAR_DIAG = 1 << 2

# CTRL bits
CTRL_FB_HOLD = 1 << 0      # D6: 0 = fail to FALLBACK mode, 1 = hold last mode
CTRL_STATIC_EN = 1 << 1    # policy override (P0 / P1 with the same bitstream)
CTRL_STATIC_SHIFT = 2

# FSM states
S_INIT, S_IDLE, S_REQ, S_REL, S_FAULT = range(5)
FSM_NAMES = {S_INIT: "INIT", S_IDLE: "IDLE", S_REQ: "REQ", S_REL: "REL", S_FAULT: "FAULT"}

# Threat levels
LV_NORMAL, LV_ELEVATED, LV_EXTREME = 0, 1, 2
LEVEL_NAMES = {0: "NORMAL", 1: "ELEVATED", 2: "EXTREME", 3: "?"}

# Protection modes, ordered by protection strength
M_BASELINE, M_PARTIAL, M_TMR, M_TMR_PLUS = 0, 1, 2, 3
MODE_NAMES = {0: "BASELINE", 1: "PARTIAL", 2: "TMR", 3: "TMR_PLUS"}

# Telemetry reject reasons (bit mask)
RJ_CRC, RJ_RSVD, RJ_SRC, RJ_SEQ = 1, 2, 4, 8

# Event vector bits (core -> diag counters)
EVENTS = ["ACCEPT", "REJECT", "FB_ENTER", "FB_EXIT", "SW_START", "SW_DONE",
          "SW_FAIL", "MISMATCH", "ILLEGAL"]
EV = {name: i for i, name in enumerate(EVENTS)}

# Reset defaults (must equal the DEF_* parameters of the RTL)
DEFAULTS = {
    "ctrl": 0x0,
    "prescale": 99_999,          # 1 ms tick at 100 MHz
    "fresh_to": 180_000,         # ticks
    "dwell_up": 0,               # ticks
    "dwell_dn": 600_000,         # ticks
    "sw_to": 10_000_000,         # cycles
    "th_elev": (0x0140 << 16) | 0x0180,   # fall 1.25x, rise 1.5x (Q8.8)
    "th_extr": (0x0300 << 16) | 0x0400,   # fall 3.0x,  rise 4.0x (Q8.8)
    "mode_map": 0xA8,            # FB=TMR X=TMR E=TMR N=BASELINE
    "limits": 0x3_03_03,         # retry 3, recover 3, invalid 3
}


def crc8(data: bytes) -> int:
    """CRC-8/SMBUS: poly 0x07, init 0x00, no reflection, no final XOR."""
    c = 0
    for byte in data:
        c ^= byte
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def crc8_word(word: int) -> int:
    return crc8((word & 0xFFFFFFFF).to_bytes(4, "big"))


def q88(ratio: float) -> int:
    """Encode an upset-rate enhancement ratio (1.0 = background) as Q8.8."""
    return max(0, min(0xFFFF, int(round(ratio * 256))))


def telemetry_word(metric: int, seq: int, source_ok: bool = True) -> int:
    """TDATA layout: [15:0] metric, [23:16] seq, [24] source-ok, [31:25] zero."""
    return (metric & 0xFFFF) | ((seq & 0xFF) << 16) | (int(bool(source_ok)) << 24)


def thresholds(rise: int, fall: int) -> int:
    return ((fall & 0xFFFF) << 16) | (rise & 0xFFFF)


def mode_map(normal: int, elevated: int, extreme: int, fallback: int) -> int:
    return (normal & 3) | ((elevated & 3) << 2) | ((extreme & 3) << 4) | ((fallback & 3) << 6)


def limits(invalid_limit: int, recover_n: int, retry_max: int) -> int:
    return (invalid_limit & 0xFF) | ((recover_n & 0xFF) << 8) | ((retry_max & 0xF) << 16)


def decode_status(v: int) -> dict:
    return {
        "fsm": FSM_NAMES.get(v & 7, f"ILLEGAL({v & 7})"),
        "level": LEVEL_NAMES[(v >> 3) & 3],
        "mode_cmd": MODE_NAMES[(v >> 5) & 3],
        "target": MODE_NAMES[(v >> 7) & 3],
        "fallback": bool(v >> 9 & 1),
        "stale": bool(v >> 10 & 1),
        "invalid": bool(v >> 11 & 1),
        "fault": bool(v >> 12 & 1),
        "busy": bool(v >> 13 & 1),
        "sw_req": bool(v >> 14 & 1),
        "sw_ack": bool(v >> 15 & 1),
        "pl_mode": MODE_NAMES[(v >> 16) & 3],
        "desired": MODE_NAMES[(v >> 18) & 3],
    }
