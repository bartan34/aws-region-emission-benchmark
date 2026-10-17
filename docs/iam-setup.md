# IAM setup (one-time)

Create the instance role with least privilege plus SSM access (no SSH keys, no port 22):

```bash
aws iam create-role --role-name carbon-bench-ec2-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name carbon-bench-ec2-role \
  --policy-name write-outputs --policy-document file://docs/iam-policy.json
aws iam attach-role-policy --role-name carbon-bench-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name carbon-bench-ec2-role
aws iam add-role-to-instance-profile --instance-profile-name carbon-bench-ec2-role --role-name carbon-bench-ec2-role
```

IAM is global; this works in every region. Allow ~10 s for the profile to propagate before the first launch.
