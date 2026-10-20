"""Block 2: alert timelines and the telemetry the controller receives.

An alert system is described by its probability of detection (POD), false-alarm
ratio (FAR = false / (false + true alerts)), timing relative to the GLE onset and
how long an alert stays raised. Ensembles are drawn around the published
figures because they rest on few events.

Telemetry is a list of (minute, metric, source_ok) messages, the same framing
the controller checks in hardware. The metric is Q8.8; with the default
controller thresholds 1.0 is NORMAL, 2.0 ELEVATED and 5.0 EXTREME.
"""

import numpy as np

from . import inputs as I
from .regs import q88

METRIC_QUIET = q88(1.0)
METRIC_ALERT = q88(2.0)           # decision D7: what an alert maps to
MIN_PER_YEAR = 365.25 * 1440


def false_alarm_rate_per_year(system, event_rate_per_year, rng=None):
    """False alerts per year implied by POD and FAR at a given event rate."""
    pod, far = system.pod.value(rng), system.far.value(rng)
    if far >= 1:
        return float("inf")
    return far / (1 - far) * pod * event_rate_per_year


def event_end(t_min, profile, frac=0.1):
    """First time after the peak at which |profile| falls below frac * peak."""
    i_pk = int(np.argmax(np.abs(profile)))
    pk = abs(profile[i_pk])
    after = np.nonzero(np.abs(profile[i_pk:]) < frac * pk)[0]
    return float(t_min[-1]) if after.size == 0 else float(t_min[i_pk + after[0]])


def event_alerts(system, onset_min, end_min, rng=None):
    """Alert interval raised for one real event, or [] if it is missed."""
    pod = system.pod.value(rng)
    detected = (rng.random() < pod) if rng is not None else pod >= 0.5
    if not detected:
        return []
    start = onset_min + system.offset_min.value(rng)
    return [(start, max(start, end_min) + system.hold_min.value(rng))]


def false_alerts(system, horizon_min, event_rate_per_year, rng):
    """Poisson false alerts over the horizon, each lasting hold_min."""
    rate = false_alarm_rate_per_year(system, event_rate_per_year, rng)
    n = np.random.default_rng(rng.getrandbits(32)).poisson(rate * horizon_min / MIN_PER_YEAR)
    out = []
    for _ in range(int(n)):
        s = rng.uniform(0, horizon_min)
        out.append((s, s + system.hold_min.value(rng)))
    return out


def outages(horizon_min, rng, event_window=None, dropout=I.DROPOUT):
    """Telemetry outages: Poisson per day, plus one with some probability
    during an event window (start, end)."""
    out = []
    per_day = dropout["p_outage_per_day"].value(rng)
    n = np.random.default_rng(rng.getrandbits(32)).poisson(per_day * horizon_min / 1440)
    for _ in range(int(n)):
        s = rng.uniform(0, horizon_min)
        out.append((s, s + dropout["outage_min"].value(rng)))
    if event_window is not None and rng.random() < dropout["p_outage_during_event"].value(rng):
        s = rng.uniform(*event_window)
        out.append((s, s + dropout["outage_min"].value(rng)))
    return out


def _mask(t, intervals):
    m = np.zeros(t.shape, dtype=bool)
    for a, b in intervals:
        m |= (t >= a) & (t < b)
    return m


def messages_from_alerts(alert_iv, horizon_min, cadence_min=1.0, outage_iv=(),
                         outage_mode="gap", alert_metric=METRIC_ALERT):
    """Telemetry for an alert-driven policy (P2, P3). During an outage the PS
    either sends nothing ("gap") or flags the source as not OK ("flagged")."""
    t = np.arange(0, horizon_min, cadence_min)
    alert = _mask(t, alert_iv)
    out = _mask(t, outage_iv)
    metric = np.where(alert, alert_metric, METRIC_QUIET)
    ok = ~out
    keep = ok if outage_mode == "gap" else np.ones(t.shape, dtype=bool)
    return list(zip(t[keep].tolist(), metric[keep].tolist(), ok[keep].tolist()))


def messages_oracle(t_min, enhancement, cadence_min=1.0):
    """Telemetry for the oracle policy P4: the true enhancement R(t) itself."""
    t = np.arange(0, t_min[-1] + 1, cadence_min)
    r = np.interp(t, t_min, enhancement)
    metric = np.clip(np.round(r * 256), 0, 0xFFFF).astype(int)
    return list(zip(t.tolist(), metric.tolist(), [True] * len(t)))
