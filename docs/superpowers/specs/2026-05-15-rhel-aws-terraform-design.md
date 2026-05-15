# RHEL Fleet on AWS — Terraform Design

**Date:** 2026-05-15
**Status:** Approved
**Repo:** `epm-pineapple-lab`

## Purpose

Stand up a configurable number of RHEL EC2 instances in an existing AWS VPC for lab work. The configuration must let the operator add or destroy individual instances without affecting the rest of the fleet, and must resolve the latest RHEL AMI dynamically.

## Requirements

1. Deploy N RHEL instances (latest minor release of a configurable major version).
2. VPC and subnet are pre-existing; their IDs come from tfvars.
3. Any one instance can be destroyed without disturbing the others.
4. Tags are sourced from tfvars (not a separate JSON file).
5. Remote state in S3 with native S3 state locking.
6. Private subnet placement (no public IPs).
7. Access via an existing EC2 key pair.
8. Optional cloud-init / user-data hook.

## Architecture

A single root Terraform module with a flat file layout. Resources iterate with `for_each` keyed by hostname so each instance is addressable by string key — this is what makes per-instance destroy clean (`count` shifts indices when an element is removed; `for_each` does not).

```
terraform.tfvars (inputs)
        |
        v
+----------------------------------+
| Root module (this repo)          |
|                                  |
|  data "aws_ami" --> latest RHEL  |
|  aws_security_group              |
|  aws_vpc_security_group_*_rule   |
|  aws_instance (for_each)         |
+----------------------------------+
        |
        v
S3 backend (state + native lockfile)
```

Only one AWS provider, region from tfvars. No nested modules; if a second fleet is later required, the flat layout can be promoted to a child module without breaking changes.

## File Layout

```
.
├── README.md
├── .gitignore
├── backend.tf
├── versions.tf
├── variables.tf
├── main.tf
├── outputs.tf
├── terraform.tfvars.example   # committed
└── terraform.tfvars           # gitignored
```

## Inputs (`variables.tf`)

| Variable | Type | Default | Notes |
|---|---|---|---|
| `aws_region` | string | — | e.g., `us-east-1` |
| `vpc_id` | string | — | Existing VPC, used by the SG |
| `subnet_id` | string | — | Existing private subnet for all instances |
| `key_pair_name` | string | — | Pre-existing EC2 key pair name |
| `rhel_major_version` | string | `"9"` | `"8"` or `"9"`; drives AMI lookup |
| `instance_type` | string | `"t3.medium"` | EC2 instance type |
| `root_volume_size_gb` | number | `30` | Root EBS size in GB |
| `root_volume_type` | string | `"gp3"` | EBS type |
| `instance_names` | list(string) | `[]` | One EC2 per element; must be unique |
| `ingress_cidrs` | list(string) | `[]` | CIDRs allowed inbound on port 22 (and any extras) |
| `extra_ingress_ports` | list(number) | `[]` | Optional additional TCP ports |
| `extra_security_group_ids` | list(string) | `[]` | Pre-existing SG IDs attached alongside the one this module creates |
| `common_tags` | map(string) | `{}` | Applied to every taggable resource; expected to include `Project` |
| `user_data` | string | `""` | Optional cloud-init; passed verbatim if non-empty |

**Validation rules in `variables.tf`:**
- `rhel_major_version` must be `"8"` or `"9"`.
- `instance_names` must contain unique values (prevents duplicate `for_each` keys).
- `ingress_cidrs` entries must match a CIDR-shaped regex.
- `common_tags` must include a `Project` key (used to name the security group).

### `terraform.tfvars.example` (committed template)

```hcl
aws_region    = "us-east-1"
vpc_id        = "vpc-0123456789abcdef0"
subnet_id     = "subnet-0123456789abcdef0"
key_pair_name = "epm-lab-key"

rhel_major_version  = "9"
instance_type       = "t3.medium"
root_volume_size_gb = 30

instance_names = [
  "epm-rhel-01",
  "epm-rhel-02",
  "epm-rhel-03",
]

ingress_cidrs = ["10.0.0.0/8"]

common_tags = {
  Project     = "epm-pineapple-lab"
  Environment = "lab"
  Owner       = "strick-j"
  ManagedBy   = "terraform"
}

user_data = ""
```

## Backend (`backend.tf`)

S3 backend with native locking (Terraform 1.10+). Bucket, key, and region are literals because backend blocks cannot reference variables. The S3 bucket is assumed to exist; bootstrapping it is out of scope. The backend `region` is intentionally separate from `var.aws_region` — the state can live in a different region from the workload, and is read at `terraform init` time before any variables are loaded.

```hcl
terraform {
  backend "s3" {
    bucket       = "REPLACE_ME-tfstate"
    key          = "epm-pineapple-lab/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

## Versions (`versions.tf`)

```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

## Resources (`main.tf`)

### Provider and AMI lookup

```hcl
provider "aws" {
  region = var.aws_region
}

data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-${var.rhel_major_version}.*_HVM-*-x86_64-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

### Security group

One SG attached to all instances. Ingress rules are split into separate resources (`aws_vpc_security_group_ingress_rule`) so individual rules can be added or removed without recreating the SG.

```hcl
resource "aws_security_group" "rhel" {
  name        = "${var.common_tags["Project"]}-rhel-sg"
  description = "RHEL fleet access"
  vpc_id      = var.vpc_id
  tags        = var.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.ingress_cidrs)
  security_group_id = aws_security_group.rhel.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "extra" {
  for_each = {
    for pair in setproduct(var.ingress_cidrs, var.extra_ingress_ports) :
    "${pair[0]}-${pair[1]}" => { cidr = pair[0], port = pair[1] }
  }
  security_group_id = aws_security_group.rhel.id
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.rhel.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

### EC2 instances

```hcl
resource "aws_instance" "rhel" {
  for_each = toset(var.instance_names)

  ami                         = data.aws_ami.rhel.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = concat([aws_security_group.rhel.id], var.extra_security_group_ids)
  key_name                    = var.key_pair_name
  associate_public_ip_address = false
  user_data                   = var.user_data

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = var.root_volume_type
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(
    var.common_tags,
    { Name = each.key },
  )

  lifecycle {
    ignore_changes = [ami]
  }
}
```

**Why `ignore_changes = [ami]`:** without it, every apply after Red Hat publishes a new RHEL AMI would replace every running instance. New instances still get the latest AMI at creation time; existing instances stay put. To intentionally rebuild on the newest AMI, use `terraform apply -replace='aws_instance.rhel["<name>"]'`.

## Outputs (`outputs.tf`)

```hcl
output "instances" {
  description = "Map of hostname => instance attributes."
  value = {
    for name, inst in aws_instance.rhel : name => {
      instance_id       = inst.id
      private_ip        = inst.private_ip
      private_dns       = inst.private_dns
      availability_zone = inst.availability_zone
    }
  }
}

output "security_group_id" {
  value = aws_security_group.rhel.id
}

output "ami_id" {
  description = "AMI ID resolved at last apply."
  value       = data.aws_ami.rhel.id
}
```

## Operational Flow

1. `cp terraform.tfvars.example terraform.tfvars`, fill in real values.
2. `terraform init` — connects to the S3 backend.
3. `terraform plan` — verify the resolved AMI and the planned instances.
4. `terraform apply` — fleet comes up.
5. **Add an instance:** append a name to `instance_names`, then `terraform apply`.
6. **Destroy one permanently:** remove the name from `instance_names`, then `terraform apply`.
7. **Destroy one ad-hoc:** `terraform destroy -target='aws_instance.rhel["epm-rhel-02"]'`. The instance will be recreated on the next non-targeted apply unless its name is also removed from tfvars.
8. **Rebuild one on the newest AMI:** `terraform apply -replace='aws_instance.rhel["epm-rhel-02"]'`.

## `.gitignore`

```
.terraform/
*.tfstate
*.tfstate.*
terraform.tfvars
*.auto.tfvars
crash.log
```

## Out of Scope

- VPC and subnet creation (assumed pre-existing).
- IAM roles / SSM Session Manager (SSH key access only).
- Public IPs, load balancers, Route53 records.
- Multi-region deployment.
- Bootstrapping the S3 state bucket.
- Configuration management on the instances after boot (Ansible, Satellite registration, etc.); use the `user_data` hook if needed.
