# Coefficients

Every external number used by `analysis/sci.py` lives here with its source,
year and access date:

- `power.csv` — per-instance power draw at 0/10/50/100% CPU load (Teads dataset).
- `pue.csv` — AWS regional Power Usage Effectiveness.
- `grid-intensity.csv` — annual grid carbon intensity per region, with an
  alternative value and source in `alt_*` columns.
- `regions.csv` — region → country mapping used for Boavizta location.
- `storage.csv` — storage energy parameters (documented, not used by sci.py).
- `em-hourly.csv` — hourly/5-minute Electricity Maps values read from the app
  at run time, used as the hourly grid-intensity fallback.
- `boavizta-<type>-<ISO3>.json` — embodied-emission responses from
  `scripts/boavizta.sh`, one per instance type and country.
