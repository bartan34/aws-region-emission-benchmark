# aws-region-carbon-benchmark

Run the same CPU-bound benchmark in five AWS regions and compute the lifecycle
carbon footprint per unit of work using the Software Carbon Intensity (SCI)
formula from ISO/IEC 21031:2024:

    SCI = ((E × I) + M) / R

| Term | Meaning | Where it comes from |
|---|---|---|
| E | Energy (kWh) | Measured CPU utilisation (CloudWatch, 1-min) × per-instance power curve (Teads) × AWS regional PUE |
| I | Grid carbon intensity (gCO₂e/kWh), location-based | Electricity Maps / Google Cloud region table / Ember |
| M | Embodied emissions (gCO₂e) allocated to the run | Boavizta API |
| R | Functional unit | sysbench events (per 10⁶) or one benchmark run |

Why estimate instead of measure: EC2 instances do not expose RAPL counters,
so every published cloud-carbon method (Teads, Cloud Carbon Footprint,
Boavizta) models power from utilisation. This repo makes that model
explicit, parametric and reproducible: every coefficient lives in
`data/coefficients/` with its source, year and access date, and all inputs
are the raw benchmark outputs committed under `data/raw/`.

## Results

Two sessions on 2026-10-11, each 5 × 10-minute sysbench cpu runs plus a
10-minute idle baseline, m5.large (2 vCPU), one instance per region:

| Region | CPU model | events/s ± SD | CI annual (g/kWh) | SCI annual (g/10⁶ events) | SCI hourly (g/10⁶ events) | Embodied share |
|---|---|---|---|---|---|---|
| ap-south-1 | Xeon 8175M | 666.4 ± 31.2 | 598 | 6.5817 ± 0.2958 | 7.5281 | 2.9% |
| us-east-1 | Xeon 8259CL | 643.4 ± 0.9 | 343 | 3.5719 ± 0.0047 | 4.4354 | 5.5% |
| eu-west-1 | 8175M/8259CL | 643.0 ± 0.8 | 301.2 | 3.1108 ± 0.0040 | 2.1048 | 6.3% |
| us-west-2 | 8175M/8259CL | 643.1 ± 1.0 | 98 | 1.1618 ± 0.0018 | 3.6480 | 17.0% |
| eu-north-1 | Xeon 8259CL | 644.3 ± 0.4 | 21.3 | 0.4023 ± 0.0003 | 0.4138 | 48.9% |

On a near-zero-carbon grid (Stockholm, SE3) the embodied emissions of the
server dominate (49% of SCI); on high-carbon grids the operational
electricity is ~95% of the footprint. Full per-run values:
`data/processed/sci-results.csv`, per-region summary:
`data/processed/sci-summary.csv`. Figures and tables:
`docs/figures/sci-tables-figures.pdf`.

## Quick start

Prerequisites: AWS CLI v2 configured, `jq`, Python 3.10+, an IAM instance
profile named `carbon-bench-ec2-role` (see `docs/iam-setup.md`), and an AWS
Budget alarm. Set one up before launching anything.

```bash
# 1. Pilot: one region, 2-minute runs, confirm the pipeline end to end
./scripts/launch.sh us-east-1 m5.large 1 120 60

# 2. Full run: 5 × 10-min runs + 10-min idle baseline, per region
for r in us-east-1 us-west-2 eu-west-1 eu-north-1 ap-south-1; do
  ./scripts/launch.sh $r m5.large 5 600 600
done

# 3. After each instance reports done_utc in S3 (≈70 min), pull metrics
./scripts/pull-cloudwatch.sh us-east-1 i-0123456789abcdef0 carbon-bench-us-east-1-XXXX

# 4. Embodied emissions per region (country code, hours)
./scripts/boavizta.sh m5.large USA 0.1667

# 5. Compute SCI
python3 analysis/sci.py
```

The instance terminates itself when the benchmark finishes
(`--instance-initiated-shutdown-behavior terminate`). Run
`./scripts/cleanup.sh <region>` afterwards to confirm nothing is left.

`git status` stays clean after step 5: the committed `data/processed/` files
are byte-identical to what `analysis/sci.py` regenerates from the committed
raw data.

## Repository layout

```
scripts/            launch, user-data (benchmark), metric pull, Boavizta, cleanup
data/coefficients/  every external number with source, year, access date
data/raw/<region>/  per-instance outputs: sysbench, lscpu, meta.json, cloudwatch.csv
data/processed/     sci-results.csv, sci-summary.csv
analysis/sci.py     the SCI computation
docs/               IAM policy, figures
```

## Assumptions and limitations

- Power is modelled, not measured; Teads data dates from 2021.
- PUE is AWS's published regional average, not per data centre.
- Grid intensity zone mapping is approximate for us-west-2 and ap-south-1.
- Boavizta covers the server share only (no network, storage, building).
- One CPU-bound workload; results do not transfer to memory/IO-bound jobs.
- Data-transfer and latency costs of actually moving a workload are out
  of scope (see Sukprasert et al. 2024).

## Coefficient sources

See `data/coefficients/*.csv` — each row carries source URL, year and
access date: Teads EC2 dataset (Davy 2021), AWS sustainability page (PUE),
Google Cloud region carbon table, Electricity Maps Grid in Review 2025,
Boavizta API, Cloud Carbon Footprint methodology, ISO/IEC 21031:2024.

## Licence

Code: MIT. Data under `data/`: CC BY 4.0 (compatible with the Teads
dataset licence). See `LICENSE` and `data/LICENSE`.
