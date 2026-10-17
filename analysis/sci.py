#!/usr/bin/env python3
"""Compute Software Carbon Intensity (ISO/IEC 21031) per region from raw runs.

    SCI = ((E * I) + M) / R

Inputs (relative to repo root):
  data/raw/<region>/<instance-id>/sysbench_runN.txt, cloudwatch.csv, timeline.txt, meta.json
  data/coefficients/power.csv, pue.csv, grid-intensity.csv, regions.csv, boavizta-<type>-<ISO3>.json
  data/coefficients/em-hourly.csv (fallback for hourly grid intensity)
Output:
  data/processed/sci-results.csv   (one row per run, three accounting views)
  data/processed/sci-summary.csv   (one row per region: mean, SD, CV, shares)

Standard library only.
"""
from __future__ import annotations

import csv
import json
import re
import statistics
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
COEF = ROOT / "data" / "coefficients"
OUT = ROOT / "data" / "processed"


def read_csv(path: Path) -> list[dict]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def parse_ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


# coefficients

def load_power_curve(instance_type: str) -> list[tuple[float, float]]:
    rows = [r for r in read_csv(COEF / "power.csv") if r["instance_type"] == instance_type]
    curve = []
    for r in rows:
        if r["watts"].upper() == "TODO":
            raise SystemExit(f"power.csv: fill TODO for {instance_type} @ {r['load_pct']}%")
        curve.append((float(r["load_pct"]), float(r["watts"])))
    if len(curve) < 2:
        raise SystemExit(f"power.csv: need >= 2 points for {instance_type}")
    return sorted(curve)


def interpolate(curve: list[tuple[float, float]], load_pct: float) -> float:
    """Linear interpolation between Teads load points (clamped at the ends)."""
    if load_pct <= curve[0][0]:
        return curve[0][1]
    for (x0, y0), (x1, y1) in zip(curve, curve[1:]):
        if load_pct <= x1:
            return y0 + (y1 - y0) * (load_pct - x0) / (x1 - x0)
    return curve[-1][1]


def load_region_table() -> dict[str, dict]:
    pue = {r["region"]: r for r in read_csv(COEF / "pue.csv")}
    grid = {r["region"]: r for r in read_csv(COEF / "grid-intensity.csv")}
    regions = {r["region"]: r for r in read_csv(COEF / "regions.csv")}
    table = {}
    for region, meta in regions.items():
        g = grid[region]
        if g["annual_gco2e_kwh"].upper() == "TODO":
            raise SystemExit(f"grid-intensity.csv: fill TODO for {region}")
        table[region] = {
            "iso3": meta["country_iso3"],
            "pue": float(pue[region]["pue"]),
            "i_annual": float(g["annual_gco2e_kwh"]),
            "em_zone": g["em_zone"],
        }
    return table


def load_boavizta_embedded(instance_type: str, iso3: str) -> float | None:
    """kgCO2e embodied allocated to the duration passed when boavizta.sh was called."""
    path = COEF / f"boavizta-{instance_type}-{iso3}.json"
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    return float(data["impacts"]["gwp"]["embedded"]["value"])


# raw run parsing

EVENTS_RE = re.compile(r"events per second:\s*([\d.]+)")
TOTAL_RE = re.compile(r"total number of events:\s*(\d+)")
TIME_RE = re.compile(r"total time:\s*([\d.]+)s")


def parse_sysbench(path: Path) -> dict:
    text = path.read_text()
    return {
        "events_per_sec": float(EVENTS_RE.search(text).group(1)),
        "total_events": int(TOTAL_RE.search(text).group(1)),
        "total_time_s": float(TIME_RE.search(text).group(1)),
    }


def parse_timeline(path: Path) -> dict[str, datetime]:
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = parse_ts(v.strip())
    return out


def mean_cpu(cloudwatch_csv: Path, start: datetime, end: datetime) -> float | None:
    vals = []
    for r in read_csv(cloudwatch_csv):
        ts = parse_ts(r["timestamp"])
        if start <= ts < end:
            vals.append(float(r["avg"]))
    # first/last minute of a window mix idle and load (CloudWatch 1-min
    # windows align to instance launch); drop boundary minutes when possible
    if len(vals) >= 4:
        vals = vals[1:-1]
    return statistics.fmean(vals) if vals else None


EM_HOURLY_WINDOW = timedelta(minutes=90)


def load_em_hourly() -> list[dict]:
    """Manually captured Electricity Maps values (one row per region per session)."""
    path = COEF / "em-hourly.csv"
    if not path.exists():
        return []
    rows = read_csv(path)
    for r in rows:
        r["utc"] = parse_ts(r["utc"])
    return rows


def hourly_intensity(em_json: Path | None, em_hourly: list[dict], region: str,
                     start: datetime, end: datetime) -> tuple[float | None, str]:
    """Grid intensity for the run window and where it came from (em-history.json
    if present, else em-hourly.csv rows within +/-90 min of the run start)."""
    if em_json is not None and em_json.exists():
        data = json.loads(em_json.read_text())
        vals = []
        for h in data.get("history", []):
            ts = parse_ts(h["datetime"])
            if start.replace(minute=0, second=0) <= ts <= end:
                if h.get("carbonIntensity") is not None:
                    vals.append(float(h["carbonIntensity"]))
        return (statistics.fmean(vals), "em-history.json") if vals else (None, "")
    vals = [float(r["gco2e_kwh"]) for r in em_hourly
            if r["region"] == region and abs(r["utc"] - start) <= EM_HOURLY_WINDOW]
    return (statistics.fmean(vals), "em-hourly.csv") if vals else (None, "")


# main

def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    regions = load_region_table()
    em_hourly = load_em_hourly()
    rows = []

    for region_dir in sorted(p for p in RAW.iterdir() if p.is_dir()):
        region = region_dir.name
        if region not in regions:
            print(f"skip {region}: not in regions.csv")
            continue
        for inst_dir in sorted(p for p in region_dir.iterdir() if p.is_dir()):
            meta = json.loads((inst_dir / "meta.json").read_text())
            itype = meta["instance_type"]
            curve = load_power_curve(itype)
            timeline = parse_timeline(inst_dir / "timeline.txt")
            cw = inst_dir / "cloudwatch.csv"
            em = inst_dir / "em-history.json"
            reg = regions[region]
            m_kg = load_boavizta_embedded(itype, reg["iso3"])

            idle_cpu = mean_cpu(cw, timeline["idle_start_utc"], timeline["idle_end_utc"])

            for i in range(1, int(meta["runs"]) + 1):
                sb = parse_sysbench(inst_dir / f"sysbench_run{i}.txt")
                start, end = timeline[f"run{i}_start_utc"], timeline[f"run{i}_end_utc"]
                cpu = mean_cpu(cw, start, end)
                hours = sb["total_time_s"] / 3600
                watts = interpolate(curve, cpu) if cpu is not None else None
                e_kwh = watts * hours * reg["pue"] / 1000 if watts else None
                i_hourly, i_hourly_src = hourly_intensity(em, em_hourly, region, start, end)
                m_g = m_kg * 1000 if m_kg is not None else None
                r_units = sb["total_events"] / 1e6

                op_annual = e_kwh * reg["i_annual"] if e_kwh else None
                op_hourly = e_kwh * i_hourly if (e_kwh and i_hourly) else None

                def sci(op, m):
                    if op is None or m is None:
                        return None
                    return (op + m) / r_units

                rows.append({
                    "region": region, "instance_id": meta["instance_id"], "instance_type": itype,
                    "cpu_model": meta.get("cpu_model", ""), "run": i,
                    "start_utc": start.isoformat(), "end_utc": end.isoformat(),
                    "events_per_sec": sb["events_per_sec"], "total_events": sb["total_events"],
                    "idle_cpu_pct": idle_cpu, "run_cpu_pct": cpu, "watts_est": watts,
                    "pue": reg["pue"], "e_kwh": e_kwh,
                    "i_annual": reg["i_annual"], "i_hourly": i_hourly, "i_hourly_source": i_hourly_src,
                    "op_g_lbm_annual": op_annual, "op_g_lbm_hourly": op_hourly,
                    "embodied_g": m_g,
                    "sci_lbm_annual_g_per_1e6ev": sci(op_annual, m_g),
                    "sci_lbm_hourly_g_per_1e6ev": sci(op_hourly, m_g),
                    "sci_mbm_g_per_1e6ev": (m_g / r_units) if m_g is not None else None,  # Scope 2 = 0 assumption
                })

    if not rows:
        raise SystemExit("no runs found under data/raw/")

    with (OUT / "sci-results.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)

    # per-region summary
    summary = []
    for region in sorted({r["region"] for r in rows}):
        rr = [r for r in rows if r["region"] == region]
        eps = [r["events_per_sec"] for r in rr]
        sci_vals = [r["sci_lbm_annual_g_per_1e6ev"] for r in rr if r["sci_lbm_annual_g_per_1e6ev"] is not None]
        op = [r["op_g_lbm_annual"] for r in rr if r["op_g_lbm_annual"] is not None]
        emb = rr[0]["embodied_g"]
        summary.append({
            "region": region, "n_runs": len(rr),
            "cpu_models": ";".join(sorted({r["cpu_model"] for r in rr})),
            "events_per_sec_mean": statistics.fmean(eps),
            "events_per_sec_sd": statistics.stdev(eps) if len(eps) > 1 else 0.0,
            "events_per_sec_cv_pct": (statistics.stdev(eps) / statistics.fmean(eps) * 100) if len(eps) > 1 else 0.0,
            "op_g_mean": statistics.fmean(op) if op else None,
            "embodied_g": emb,
            "embodied_share_pct": (emb / (statistics.fmean(op) + emb) * 100) if (op and emb is not None) else None,
            "sci_lbm_annual_mean": statistics.fmean(sci_vals) if sci_vals else None,
            "sci_lbm_annual_sd": statistics.stdev(sci_vals) if len(sci_vals) > 1 else 0.0,
        })
    with (OUT / "sci-summary.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(summary[0].keys()))
        w.writeheader(); w.writerows(summary)

    print(f"wrote {len(rows)} runs -> {OUT / 'sci-results.csv'}")
    print(f"wrote {len(summary)} regions -> {OUT / 'sci-summary.csv'}")
    for s in summary:
        print(f"  {s['region']:12s} SCI={s['sci_lbm_annual_mean']!s:>10} g/1e6ev  embodied share={s['embodied_share_pct']!s}%")


if __name__ == "__main__":
    main()