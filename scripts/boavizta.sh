#!/bin/bash
# Embodied (and Boavizta's own operational) GWP for one instance type, location and duration.
# Usage: ./scripts/boavizta.sh <instance-type> <ISO3-country> <hours> [workload%]
# Example: ./scripts/boavizta.sh m5.large SWE 0.1667 100
set -euo pipefail
ITYPE=${1:?}; LOC=${2:?}; HOURS=${3:?}; LOAD=${4:-100}
cd "$(dirname "$0")/.."
OUT=data/coefficients/boavizta-$ITYPE-$LOC.json
curl -s -X POST "https://api.boavizta.org/v1/cloud/instance?verbose=true&duration=$HOURS&criteria=gwp" \
  -H 'Content-Type: application/json' \
  -d "{\"provider\":\"aws\",\"instance_type\":\"$ITYPE\",\"usage\":{\"usage_location\":\"$LOC\",\"time_workload\":$LOAD}}" \
  > "$OUT"
echo "Saved $OUT (accessed $(date -u +%F))"
jq '{embedded_kgCO2e: .impacts.gwp.embedded.value, use_kgCO2e: .impacts.gwp.use.value, warnings: .impacts.gwp.embedded.warnings}' "$OUT"
