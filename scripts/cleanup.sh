#!/bin/bash
# List (and optionally delete) leftover resources from benchmark runs in a region.
# Usage: ./scripts/cleanup.sh <region> [--delete]
set -euo pipefail
REGION=${1:?}; MODE=${2:-}
TAG=${PROJECT_TAG:-carbon-bench}

echo "== Instances tagged Project=$TAG (non-terminated) =="
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,LaunchTime]' --output table

echo "== Available (unattached) volumes =="
aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table

echo "== Unassociated Elastic IPs =="
aws ec2 describe-addresses --region "$REGION" \
  --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table

echo "== Buckets with prefix carbon-bench-$REGION =="
aws s3api list-buckets --query "Buckets[?starts_with(Name,'carbon-bench-$REGION')].Name" --output text

if [ "$MODE" = "--delete" ]; then
  for b in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'carbon-bench-$REGION')].Name" --output text); do
    echo "Emptying and deleting $b"; aws s3 rb "s3://$b" --force --region "$REGION"
  done
  for v in $(aws ec2 describe-volumes --region "$REGION" --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text); do
    echo "Deleting volume $v"; aws ec2 delete-volume --region "$REGION" --volume-id "$v"
  done
fi
