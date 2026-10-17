#!/bin/bash
# Benchmark runner executed by cloud-init at first boot (Ubuntu 24.04).
# Placeholders (__X__) are substituted by launch.sh. Do not run directly.
set -euo pipefail
exec > /var/log/carbon-bench.log 2>&1

REGION="__REGION__"
BUCKET="__BUCKET__"
RUNS=__RUNS__
RUN_SECONDS=__RUN_SECONDS__
IDLE_SECONDS=__IDLE_SECONDS__
THREADS=__THREADS__
MAX_PRIME=__MAX_PRIME__

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
md() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
IID=$(md instance-id); ITYPE=$(md instance-type)
AZ=$(md placement/availability-zone); AMI=$(md ami-id)

OUT=/opt/carbon-bench/$REGION/$IID
mkdir -p "$OUT"
log() { echo "$1=$(date -u +%FT%TZ)" >> "$OUT/timeline.txt"; }

# 1. install
log install_start_utc
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y sysbench jq unzip
if ! command -v aws >/dev/null; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install || apt-get install -y awscli
fi
log install_end_utc

# 2. metadata snapshot
lscpu > "$OUT/lscpu.txt"
cat > "$OUT/meta.json" <<JSON
{
  "region": "$REGION", "az": "$AZ", "instance_id": "$IID", "instance_type": "$ITYPE",
  "ami": "$AMI", "kernel": "$(uname -r)", "os": "$(. /etc/os-release; echo $PRETTY_NAME)",
  "sysbench": "$(sysbench --version)",
  "cpu_model": "$(lscpu | grep -m1 '^Model name' | sed 's/.*: *//')",
  "vcpus": $(nproc),
  "runs": $RUNS, "run_seconds": $RUN_SECONDS, "idle_seconds": $IDLE_SECONDS,
  "threads": $THREADS, "cpu_max_prime": $MAX_PRIME,
  "meta_written_utc": "$(date -u +%FT%TZ)"
}
JSON

# 3. idle baseline
log idle_start_utc
sleep "$IDLE_SECONDS"
log idle_end_utc

# 4. benchmark runs
for i in $(seq 1 "$RUNS"); do
  log "run${i}_start_utc"
  sysbench cpu --threads="$THREADS" --time="$RUN_SECONDS" \
    --cpu-max-prime="$MAX_PRIME" --report-interval=60 run \
    > "$OUT/sysbench_run${i}.txt"
  log "run${i}_end_utc"
  sleep 60   # separates CloudWatch minutes between runs
done

# 5. upload to same-region bucket
log done_utc
aws s3 cp "$OUT" "s3://$BUCKET/$REGION/$IID/" --recursive --region "$REGION"
aws s3 cp /var/log/carbon-bench.log "s3://$BUCKET/$REGION/$IID/" --region "$REGION"

# 6. self-terminate (shutdown-behavior=terminate is set at launch)
sleep 30
shutdown -h now