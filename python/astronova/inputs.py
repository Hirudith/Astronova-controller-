"""Every number the analysis (Blocks 1, 2, 5) uses, with its source and status.

Status values:
  PROPOSAL     stated in the research proposal with a citation; check against
               the cited source before publication
  STANDARD     textbook constant or formula
  TO-VERIFY    a published value recalled here; confirm from the source
  DERIVED      computed from other entries
  PLACEHOLDER  illustrative only; must be replaced (data, model output or
               V2 hardware measurement) before any result is reported

Any output computed with a PLACEHOLDER entry is labelled as such by the
evaluation engine (see evaluate.provenance).
"""

from dataclasses import dataclass, field
import math


@dataclass(frozen=True)
class Param:
    nom: float
    lo: float = None
    hi: float = None
    unit: str = ""
    source: str = ""
    status: str = "PLACEHOLDER"

    def __post_init__(self):
        if self.lo is None:
            object.__setattr__(self, "lo", self.nom)
        if self.hi is None:
            object.__setattr__(self, "hi", self.nom)
        if not self.lo <= self.nom <= self.hi:
            raise ValueError(f"range does not contain nominal: {self}")

    def sample(self, rng):
        """Triangular in value, or in log10 when the range spans > 10x."""
        if self.lo == self.hi:
            return self.nom
        if self.lo > 0 and self.hi / self.lo > 10:
            lo, nom, hi = (math.log10(v) for v in (self.lo, self.nom, self.hi))
            return 10 ** rng.triangular(lo, hi, nom)
        return rng.triangular(self.lo, self.hi, self.nom)

    def value(self, rng=None):
        return self.nom if rng is None else self.sample(rng)


# ---------------------------------------------------------------------------
# Device (Block 1)
# ---------------------------------------------------------------------------
DEVICE = {
    "cram_bits": Param(32e6, unit="bit", status="PROPOSAL",
                       source="proposal 1.1: XC7Z020 'roughly 32 Mb of CRAM'; UG470 bitstream "
                              "length (32,364,512 bit) is an upper bound (TO-VERIFY)"),
    "fit_per_mbit": Param(75, 60, 90, unit="FIT/Mb (NYC sea level)", status="PROPOSAL",
                          source="proposal 1.1 / UG116 [43]: 7-series CRAM 75 FIT/Mb; range is a "
                                 "PLACEHOLDER until the UG116 confidence interval is entered"),
}

REFERENCE_FLUX_NYC = Param(13, unit="n/cm2/h, E>10 MeV", status="TO-VERIFY",
                           source="JESD89A [44] reference flux, New York City sea level")

# ---------------------------------------------------------------------------
# Sites (decision D4: final list of 4-6 sites still open)
#   cutoff_factor : geomagnetic-cutoff (and solar-cycle) factor relative to NYC,
#                   to come from the JESD89A location model or EXPACS/PARMA
#   nm_transfer   : site SEU-flux increase per unit increase of the reference
#                   neutron monitor during a GLE (decision D3: AniMAIRE /
#                   published model outputs / NM proxy)
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Site:
    name: str
    alt_m: float
    cutoff_factor: Param
    nm_transfer: Param
    note: str = ""


SITES = [
    Site("Sea level, mid-latitude (NYC reference)", 0,
         Param(1.0, status="STANDARD", source="reference location by definition"),
         Param(1.0, 0.5, 1.5, source="NM proxy (D3), illustrative range")),
    Site("Denver data centre (1.6 km)", 1609,
         Param(0.95, 0.85, 1.05, source="placeholder pending JESD89A location model"),
         Param(1.0, 0.5, 2.0, source="NM proxy (D3), illustrative range"),
         "fleet example of Keller and Wirthlin [1]"),
    Site("High latitude, sea level", 0,
         Param(1.15, 1.0, 1.3, source="placeholder pending JESD89A location model"),
         Param(1.5, 1.0, 3.0, source="NM proxy (D3), illustrative range")),
    Site("High-altitude observatory (5 km, low latitude)", 5050,
         Param(0.6, 0.4, 0.8, source="placeholder pending JESD89A / Hubert et al. [18]"),
         Param(0.5, 0.2, 1.5, source="placeholder pending published GLE results at ALMA [18]")),
    Site("Polar plateau (2.8 km)", 2835,
         Param(1.3, 1.1, 1.5, source="placeholder pending JESD89A location model"),
         Param(2.0, 1.0, 4.0, source="placeholder; GLE #77 South Pole NM +102% [23]")),
    Site("Aviation cruise, high latitude (FL350)", 10668,
         Param(1.3, 1.0, 1.6, source="placeholder pending MAIRE+/Lei et al. [19]"),
         Param(5.0, 2.0, 20.0, source="placeholder pending Hubert et al. [17], Lei et al. [19]"),
         "altitude factor formula is outside its best-tested range here"),
]

# ---------------------------------------------------------------------------
# Events (decision D4: 4-6 event classes)
#   nm_peak_pct : peak increase (+) or decrease (-) of the reference neutron
#                 monitor, percent
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class EventClass:
    name: str
    kind: str                    # "gle" or "forbush"
    nm_peak_pct: Param
    rise_min: Param
    decay_min: Param
    per_year: Param


FD_TRANSFER = Param(1.0, 0.7, 1.5, source="placeholder: site SEU-flux change per unit NM change "
                                         "during a Forbush decrease (NM proxy, D3)")

GLE_RATE = Param(77 / 84, unit="1/yr", status="DERIVED",
                 source="77 GLEs from GLE #1 (1942) to GLE #77 (2025) [22]")

EVENTS = [
    EventClass("Forbush decrease", "forbush",
               Param(-8, -15, -3, unit="%", source="placeholder; typical FD depth"),
               Param(60, 30, 180, unit="min", source="placeholder"),
               Param(3 * 1440, 1440, 7 * 1440, unit="min", source="placeholder; recovery over days"),
               Param(3, 1, 6, unit="1/yr", source="placeholder")),
    EventClass("Small GLE (NM +20%)", "gle",
               Param(20, 10, 30, unit="%", source="placeholder; scale of GLE #77 at Moscow (+21%) [23]"),
               Param(15, 5, 30, unit="min", source="placeholder"),
               Param(90, 45, 180, unit="min", source="placeholder"),
               Param(GLE_RATE.nom * 0.6, GLE_RATE.nom * 0.3, GLE_RATE.nom * 0.8, unit="1/yr",
                     source="placeholder split of the GLE rate (DERIVED total)")),
    EventClass("GLE #77-class (NM +125%)", "gle",
               Param(125, 100, 150, unit="%", status="PROPOSAL",
                     source="GLE #77 peak about +125% on standard NMs [22]"),
               Param(15, 5, 30, unit="min", source="placeholder"),
               Param(120, 60, 240, unit="min", source="placeholder"),
               Param(GLE_RATE.nom * 0.35, GLE_RATE.nom * 0.15, GLE_RATE.nom * 0.6, unit="1/yr",
                     source="placeholder split of the GLE rate (DERIVED total)")),
    EventClass("Extreme GLE (GLE #5-class)", "gle",
               Param(4500, 1000, 5000, unit="%", status="TO-VERIFY",
                     source="GLE #5 (23 Feb 1956), the largest recorded NM increase"),
               Param(15, 5, 30, unit="min", source="placeholder"),
               Param(240, 120, 600, unit="min", source="placeholder"),
               Param(1 / 70, 1 / 200, 1 / 30, unit="1/yr", source="placeholder")),
]

# ---------------------------------------------------------------------------
# Alert systems (Block 2)
#   offset_min: alert time relative to the GLE onset at the NM network
#               (negative = early warning, positive = after onset)
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class AlertSystem:
    name: str
    pod: Param               # probability of detecting an event
    far: Param               # false-alarm ratio = false / (false + true alerts)
    offset_min: Param
    hold_min: Param          # how long an alert stays active after the event ends
    note: str = ""


NM_LEAD_OVER_FIRST_ALERT = Param(8, 4, 12, unit="min", status="PROPOSAL",
                                 source="UMASEP-500 ~8 min before the first NM alert [28]; "
                                        "range PLACEHOLDER")

ALERTS = {
    "nm_alarm": AlertSystem(
        "Neutron-monitor GLE alarm (P2)",
        Param(0.95, 0.85, 1.0, source="placeholder; 'confirms arrival' [27]"),
        Param(0.02, 0.0, 0.05, source="placeholder; 'very few false alarms' (proposal, [27])"),
        Param(5, 2, 10, unit="min", source="placeholder; alarm after onset [27]"),
        Param(30, 10, 60, unit="min", source="placeholder")),
    "umasep": AlertSystem(
        "Satellite early warning, UMASEP-500 (P3)",
        Param(0.54, 0.40, 0.65, status="PROPOSAL", source="Nunez et al. 2017 [28]: ~54% detection"),
        Param(0.30, 0.20, 0.40, status="PROPOSAL", source="Nunez et al. 2017 [28]: ~30% FAR"),
        Param(5 - NM_LEAD_OVER_FIRST_ALERT.nom, 5 - 12, 5 - 4, unit="min",
              source="NM alarm offset (placeholder) minus the UMASEP lead over the first "
                     "NM alert (~8 min, PROPOSAL [28])"),
        Param(30, 10, 60, unit="min", source="placeholder")),
}

DROPOUT = {
    "p_outage_per_day": Param(0.05, 0.0, 0.2, source="placeholder; GLE #77 degradation [24]"),
    "outage_min": Param(30, 5, 240, unit="min", source="placeholder"),
    "p_outage_during_event": Param(0.2, 0.0, 0.5, source="placeholder; feeds degraded during GLE #77 [24]"),
}

# ---------------------------------------------------------------------------
# Hardware (Blocks 3-4). V2 measurements replace these.
#   pf_*  : probability that one configuration upset anywhere in the device
#           causes a payload failure (SDC or hang) in that mode
# ---------------------------------------------------------------------------
HARDWARE = {
    "pf_simplex": Param(0.05, 0.01, 0.2, source="placeholder until SEM IP campaign (V2)"),
    "tmr_reduction_static": Param(0.99, 0.95, 0.995, status="PROPOSAL",
                                  source="full TMR ~99% cross-section reduction [2]"),
    "tmr_reduction_switchable": Param(0.97, 0.85, 0.99,
                                      source="placeholder for RQ5; 85% partial-TMR result [2] as low end"),
    "simplex_overhead_switchable": Param(1.1, 1.0, 1.5,
                                         source="placeholder: SIMPLEX mode of the switchable build vs "
                                                "the baseline build (mode and load logic)"),
    "dmr_sdc_fraction": Param(0.1, 0.02, 0.3,
                              source="placeholder: share of DMR-mode failures not caught by the compare"),
    "pf_switch": Param(0.5, 0.0, 1.0, source="placeholder; switch-window campaign (RQ4)"),
    "switch_window_s": Param(2 / 100e6, unit="s", status="DERIVED",
                             source="Level-1 switch measured at 2 cycles at 100 MHz in simulation (V1)"),
    "pf_controller": Param(0.002, 0.0005, 0.01,
                           source="placeholder; controller SEM campaign (V2)"),
    # power, decision D9 (Vivado estimate or external measurement)
    "p_static_w": Param(0.10, 0.08, 0.15, unit="W", source="placeholder"),
    "p_replica_w": Param(0.05, 0.02, 0.10, unit="W", source="placeholder: one active replica"),
    "p_voter_w": Param(0.005, 0.002, 0.01, unit="W", source="placeholder: voters in TMR"),
    "p_ctrl_w": Param(0.01, 0.005, 0.02, unit="W", source="placeholder: controller"),
    "p_scrub_w": Param(0.01, 0.005, 0.02, unit="W", source="placeholder: continuous scrubbing"),
    "e_switch_j": Param(1e-9, 0, 1e-6, unit="J", source="placeholder; negligible for Level 1"),
}

FLEET_SIZES = [1, 1_000, 100_000]


def all_params():
    """(group, name, Param) for every scalar input, for provenance tables."""
    out = [("device", k, v) for k, v in DEVICE.items()]
    out.append(("reference", "flux_nyc", REFERENCE_FLUX_NYC))
    out.append(("event", "fd_transfer", FD_TRANSFER))
    out.append(("event", "gle_rate", GLE_RATE))
    for s in SITES:
        out += [("site", f"{s.name}: cutoff_factor", s.cutoff_factor),
                ("site", f"{s.name}: nm_transfer", s.nm_transfer)]
    for e in EVENTS:
        out += [("event", f"{e.name}: {f}", getattr(e, f))
                for f in ("nm_peak_pct", "rise_min", "decay_min", "per_year")]
    for k, a in ALERTS.items():
        out += [("alert", f"{k}: {f}", getattr(a, f)) for f in ("pod", "far", "offset_min", "hold_min")]
    out += [("dropout", k, v) for k, v in DROPOUT.items()]
    out += [("hardware", k, v) for k, v in HARDWARE.items()]
    return out
