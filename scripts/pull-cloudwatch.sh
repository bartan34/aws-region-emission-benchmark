#!/bin/bash
# Download instance outputs from S3 and pull 1-minute CPUUtilization for the run window.
# Usage: ./scripts/pull-cloudwatch.sh <region> <instance-id> <bucket>
set -euo pipefail
REGION=${1:?}; IID=${2:?}; BUCKET=${3:?}
cd "$(dirname "$0")/.."
DEST=data/raw/$REGION/$IID
mkdir -p "$DEST"

aws s3 sync "s3://$BUCKET/$REGION/$IID/" "$DEST/" --region "$REGION"

START=$(grep idle_start_utc "$DEST/timeline.txt" | cut -d= -f2)
END=$(grep done_utc "$DEST/timeline.txt" | cut -d= -f2)
echo "Window $START .. $END"

aws cloudwatch get-metric-statistics --region "$REGION" \
  --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value="$IID" \
  --start-time "$START" --end-time "$END" \
  --period 60 --statistics Average Maximum \
  --output json > "$DEST/cloudwatch.json"

echo "timestamp,avg,max" > "$DEST/cloudwatch.csv"
jq -r '.Datapoints | sort_by(.Timestamp)[] | [.Timestamp,.Average,.Maximum] | @csv' \
  "$DEST/cloudwatch.json" >> "$DEST/cloudwatch.csv"

echo "Datapoints: $(($(wc -l < "$DEST/cloudwatch.csv") - 1))"
echo "Reminder: fetch Electricity Maps hourly values for this window within 24 h:"
echo "  curl -s 'https://api.electricitymaps.com/v3/carbon-intensity/history?zone=<ZONE>&emissionFactorType=lifecycle' -H 'auth-token: \$EM_TOKEN' > $DEST/em-history.json"
