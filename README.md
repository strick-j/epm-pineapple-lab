# epm-pineapple-lab

Terraform module that deploys a configurable number of RHEL EC2 instances into an existing AWS VPC for lab use.

Each instance is keyed by hostname so individual hosts can be added or removed without disturbing the rest of the fleet.

## Prerequisites

- Terraform `>= 1.10.0` (uses S3-native state locking via `use_lockfile`).
- An AWS account, an existing VPC + private subnet, and an existing EC2 key pair in the target region.
- An existing S3 bucket for state. Update the placeholder in `backend.tf` before running `terraform init`.
- AWS credentials available via the standard chain (`AWS_PROFILE`, env vars, or instance metadata).

## Usage

```bash
# 1. Edit backend.tf: replace REPLACE_ME-tfstate with your S3 bucket name.

# 2. Provide your values.
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 3. Initialize.
terraform init

# 4. Review what will be created.
terraform plan

# 5. Apply.
terraform apply
```

## Day-2 operations

| Task | Command |
|---|---|
| Add an instance | Append a name to `instance_names` in `terraform.tfvars`, then `terraform apply`. |
| Permanently destroy one instance | Remove the name from `instance_names`, then `terraform apply`. |
| Destroy one instance ad-hoc (will be recreated on next non-targeted apply) | `terraform destroy -target='aws_instance.rhel["epm-rhel-02"]'` |
| Rebuild one instance on the latest RHEL AMI | `terraform apply -replace='aws_instance.rhel["epm-rhel-02"]'` |
| Destroy the entire fleet | `terraform destroy` |

## Outputs

- `instances` — map of `hostname => { instance_id, private_ip, private_dns, availability_zone }`
- `security_group_id` — ID of the fleet security group
- `ami_id` — AMI ID resolved at the last apply

## Design

See [docs/superpowers/specs/2026-05-15-rhel-aws-terraform-design.md](docs/superpowers/specs/2026-05-15-rhel-aws-terraform-design.md).
