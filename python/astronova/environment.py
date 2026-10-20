"""Block 1: from space-weather data to a configuration-upset rate lambda(t).

    lambda(t) = lambda_ref * S_site * R_site(t)

  lambda_ref  device CRAM upset rate at the JESD89 reference location
              (CRAM bits x FIT/Mb)
  S_site      background factor of the site: altitude factor x cutoff factor
  R_site(t)   storm enhancement: 1 + k_site * dNM(t) / 100, where dNM is the
              percentage change of a reference neutron monitor (NMDB data or a
              synthetic profile) and k_site the site transfer factor (D3)

Times are in minutes, rates in upsets per hour per device. Every quantity
can be drawn from its uncertainty range by passing a random.Random.
"""

import math

import numpy as np

from . import inputs as I

MIN_PER_H = 60.0


# ---------------------------------------------------------------------------
# Reference rate and site background
# ---------------------------------------------------------------------------
def lambda_ref_per_h(rng=None, device=I.DEVICE):
    """Device CRAM upsets per hour at the reference location."""
    mbit = device["cram_bits"].value(rng) / 1e6
    return mbit * device["fit_per_mbit"].value(rng) * 1e-9


def atmospheric_depth(alt_m):
    """Atmospheric depth in g/cm^2 from the ICAO standard atmosphere (STANDARD)."""
    if alt_m <= 11_000:
        p_hpa = 1013.25 * (1 - 2.25577e-5 * alt_m) ** 5.25588
    else:
        p_hpa = 226.32 * math.exp(-(alt_m - 11_000) / 6341.6)
    return p_hpa * 1.019716            # 1 hPa = 1.019716 g/cm^2


def altitude_factor(alt_m):
    """Neutron flux relative to sea level: exp((1033 - d) / 131.3).
    Form of the JESD89A Annex A altitude dependence (TO-VERIFY); least reliable
    above ~12 km, near the Pfotzer maximum."""
    return math.exp((1033.0 - atmospheric_depth(alt_m)) / 131.3)


def site_factor(site, rng=None):
    return altitude_factor(site.alt_m) * site.cutoff_factor.value(rng)


def lambda_background_per_h(site, rng=None):
    return lambda_ref_per_h(rng) * site_factor(site, rng)


# ---------------------------------------------------------------------------
# Storm profiles of the reference neutron monitor (percent change)
# ---------------------------------------------------------------------------
def gle_profile(t_min, onset_min, peak_pct, rise_min, decay_min):
    """Synthetic GLE: (1 - exp(-t/rise)) * exp(-t/decay), scaled to peak_pct.
    Shape only; replace with NMDB data for real events."""
    t = np.asarray(t_min, dtype=float) - onset_min
    shape = np.where(t > 0, (1 - np.exp(-t / rise_min)) * np.exp(-t / decay_min), 0.0)
    tp = rise_min * math.log(1 + decay_min / rise_min)            # time of the maximum
    peak = (1 - math.exp(-tp / rise_min)) * math.exp(-tp / decay_min)
    return peak_pct * shape / peak


def forbush_profile(t_min, onset_min, depth_pct, fall_min, recovery_min):
    """Synthetic Forbush decrease: fall over fall_min, exponential recovery.
    depth_pct is negative."""
    t = np.asarray(t_min, dtype=float) - onset_min
    fall = np.clip(t / fall_min, 0, 1)
    rec = np.where(t > fall_min, np.exp(-(t - fall_min) / recovery_min), 1.0)
    return np.where(t > 0, depth_pct * fall * rec, 0.0)


def event_profile(event, t_min, onset_min, rng=None):
    peak = event.nm_peak_pct.value(rng)
    rise = event.rise_min.value(rng)
    decay = event.decay_min.value(rng)
    if event.kind == "gle":
        return gle_profile(t_min, onset_min, peak, rise, decay)
    return forbush_profile(t_min, onset_min, peak, rise, decay)


def load_nmdb(path, baseline_min=120):
    """Read an NMDB NEST ASCII export ("YYYY-MM-DD HH:MM:SS;value" lines) and
    return (t_min, percent change from the mean of the first baseline_min
    minutes). Lines that do not parse (header, comments, 'null') are skipped."""
    import datetime as dt
    ts, vals = [], []
    with open(path) as f:
        for line in f:
            parts = line.strip().split(";")
            if len(parts) < 2:
                continue
            try:
                t = dt.datetime.strptime(parts[0].strip(), "%Y-%m-%d %H:%M:%S")
                v = float(parts[1])
            except ValueError:
                continue
            ts.append(t)
            vals.append(v)
    if not ts:
        raise ValueError(f"no NMDB samples in {path}")
    t0 = ts[0]
    t_min = np.array([(t - t0).total_seconds() / 60 for t in ts])
    v = np.array(vals)
    base = v[t_min < t_min[0] + baseline_min].mean()
    return t_min, 100.0 * (v - base) / base


def enhancement(nm_pct, site, rng=None, kind="gle"):
    """R_site(t) from the reference-NM percent change (never below zero). GLEs
    use the site's transfer factor; Forbush decreases a common one."""
    k = site.nm_transfer.value(rng) if kind == "gle" else I.FD_TRANSFER.value(rng)
    return np.maximum(0.0, 1.0 + k * np.asarray(nm_pct) / 100.0)


def lambda_trace(site, event, horizon_min, onset_min, dt_min=1.0, rng=None):
    """lambda(t) in upsets/h per device on a dt_min grid, plus the profile."""
    t = np.arange(0, horizon_min, dt_min)
    nm = event_profile(event, t, onset_min, rng)
    lam = lambda_background_per_h(site, rng) * enhancement(nm, site, rng, event.kind)
    return t, lam, nm


# ---------------------------------------------------------------------------
# RQ1: should the field studies have seen the storm?
# ---------------------------------------------------------------------------
def field_detectability(rate_per_h_background, exposure_units, excess_integral_h, window_h):
    """Expected upsets in an observation window around an event and the
    significance of the storm excess against Poisson noise.

    rate_per_h_background : upsets/h per unit (device, Mbit, ...) at the site
    exposure_units        : number of units observed
    excess_integral_h     : integral of (R(t) - 1) dt over the window, hours
    window_h              : length of the window, hours
    """
    background = rate_per_h_background * exposure_units * window_h
    excess = rate_per_h_background * exposure_units * excess_integral_h
    z = excess / math.sqrt(background) if background > 0 else float("inf")
    return {"background": background, "excess": excess, "z": z}
