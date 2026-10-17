#!/bin/bash
# Launch one benchmark instance in a region.
# Usage: ./scripts/launch.sh <region> [instance-type] [runs] [run_seconds] [idle_seconds] [threads] [max_prime]
# Example: ./scripts/launch.sh us-east-1 m5.large 5 600 600
set -euo pipefail
REGION=${1:?region required}
ITYPE=${2:-m5.large}
RUNS=${3:-5}
RUN_SECONDS=${4:-600}
IDLE_SECONDS=${5:-600}
THREADS=${6:-2}
MAX_PRIME=${7:-20000}
ROLE=${IAM_ROLE:-carbon-bench-ec2-role}
PROJECT_TAG=${PROJECT_TAG:-carbon-bench}

cd "$(dirname "$0")/.."
mkdir -p data/raw/"$REGION"

SUFFIX=$(openssl rand -hex 2)
BUCKET="carbon-bench-$REGION-$SUFFIX"
echo "Creating bucket $BUCKET"
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
fi

AMI=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)
echo "AMI $AMI"

UD=/tmp/ud-$REGION-$SUFFIX.sh
sed -e "s|__REGION__|$REGION|; s|__BUCKET__|$BUCKET|; s|__RUNS__|$RUNS|" \
    -e "s|__RUN_SECONDS__|$RUN_SECONDS|; s|__IDLE_SECONDS__|$IDLE_SECONDS|" \
    -e "s|__THREADS__|$THREADS|; s|__MAX_PRIME__|$MAX_PRIME|" \
    scripts/user-data.sh > "$UD"

IID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type "$ITYPE" --count 1 \
  --iam-instance-profile Name="$ROLE" \
  --monitoring Enabled=true \
  --instance-initiated-shutdown-behavior terminate \
  --metadata-options HttpTokens=required \
  --user-data file://"$UD" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_TAG-$REGION},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' --output text)

EST_MIN=$(( (IDLE_SECONDS + RUNS * (RUN_SECONDS + 60)) / 60 + 5 ))
echo "$(date -u +%FT%TZ),$REGION,$ITYPE,$IID,$BUCKET,$RUNS,$RUN_SECONDS,$IDLE_SECONDS" >> data/run-log.csv
echo "Launched $IID in $REGION. Expect done_utc in s3://$BUCKET/$REGION/$IID/timeline.txt in ~$EST_MIN min."
echo "Then: ./scripts/pull-cloudwatch.sh $REGION $IID $BUCKET"
