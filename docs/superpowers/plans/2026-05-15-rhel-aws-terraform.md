# RHEL Fleet on AWS — Terraform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a configurable RHEL EC2 fleet in an existing AWS VPC using a single flat Terraform root module where each instance can be added or destroyed independently.

**Architecture:** Flat root module. `for_each` over a hostname list keyed by string so individual instances are addressable. Dynamic AMI lookup (Red Hat owner ID) with `ignore_changes = [ami]` so existing instances aren't replaced when Red Hat publishes a new RHEL. S3 backend with native locking (Terraform 1.10+).

**Tech Stack:** Terraform `>= 1.10.0`, AWS provider `~> 5.0`, RHEL 8/9 (configurable), S3 backend with `use_lockfile = true`.

**Spec:** `docs/superpowers/specs/2026-05-15-rhel-aws-terraform-design.md`

**Verification model for Terraform:**
Terraform doesn't have a unit test framework that applies here. The verification loop at each task is:
1. `terraform fmt -check -diff` — formatting
2. `terraform validate` — syntax, references, type checks (needs providers; run `terraform init -backend=false` once at the start so this works without an S3 bucket)
3. `terraform plan` — only at the final task, and only if the executor has AWS credentials + real VPC/subnet IDs

Each task commits after `fmt` and `validate` succeed.

---

## File Structure

```
.
├── README.md                  # MODIFY: add usage section (Task 9)
├── .gitignore                 # CREATE: Task 1
├── versions.tf                # CREATE: Task 1
├── backend.tf                 # CREATE: Task 2
├── variables.tf               # CREATE: Task 3
├── main.tf                    # CREATE empty → fill across Tasks 4, 5, 6
├── outputs.tf                 # CREATE: Task 7
└── terraform.tfvars.example   # CREATE: Task 8
```

One file per concern. `main.tf` is split across three tasks (provider+AMI → SG → instances) so each step stays small enough to validate independently.

---

## Task 1: Bootstrap — `.gitignore` and `versions.tf`

**Files:**
- Create: `.gitignore`
- Create: `versions.tf`

- [ ] **Step 1.1: Create `.gitignore`**

Write `.gitignore` at the repo root:

```gitignore
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
terraform.tfvars
*.auto.tfvars
crash.log
crash.*.log

# OS noise
.DS_Store
```

Notes:
- `terraform.tfvars` is gitignored because it will contain real VPC/subnet IDs. The `terraform.tfvars.example` template (Task 8) is committed.
- `.terraform.lock.hcl` is excluded because this is a personal lab module; in a team setting it would normally be committed.

- [ ] **Step 1.2: Create `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

- [ ] **Step 1.3: Initialize providers without backend**

Run: `terraform init -backend=false`

Expected output (last lines):
```
Terraform has been successfully initialized!
```

This downloads the AWS provider so future `terraform validate` calls work. Backend is skipped because the S3 bucket may not exist yet at this point.

- [ ] **Step 1.4: Format check**

Run: `terraform fmt -check -diff`

Expected: exit code 0, no diff output. If it fails, run `terraform fmt` and re-check.

- [ ] **Step 1.5: Validate**

Run: `terraform validate`

Expected:
```
Success! The configuration is valid.
```

- [ ] **Step 1.6: Commit**

```bash
git add .gitignore versions.tf
git commit -m "Add gitignore and Terraform version pins"
```

---

## Task 2: S3 Backend Configuration

**Files:**
- Create: `backend.tf`

- [ ] **Step 2.1: Create `backend.tf`**

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

Notes:
- `bucket` and `region` are literals and must be filled in by the operator before running `terraform init` without `-backend=false`.
- `use_lockfile = true` uses S3-native locking and requires Terraform `>= 1.10.0` (already pinned in `versions.tf`).
- Backend blocks cannot reference variables, which is why the placeholder is hardcoded.

- [ ] **Step 2.2: Format and validate**

Run: `terraform fmt -check -diff && terraform validate`

Expected: format passes, `Success! The configuration is valid.`

- [ ] **Step 2.3: Commit**

```bash
git add backend.tf
git commit -m "Configure S3 backend with native state locking"
```

---

## Task 3: Input Variables with Validation

**Files:**
- Create: `variables.tf`

- [ ] **Step 3.1: Create `variables.tf`**

```hcl
variable "aws_region" {
  description = "AWS region for the workload (e.g., us-east-1). Distinct from the backend region in backend.tf."
  type        = string
}

variable "vpc_id" {
  description = "ID of the existing VPC the security group attaches to."
  type        = string
}

variable "subnet_id" {
  description = "ID of the existing private subnet all instances launch into."
  type        = string
}

variable "key_pair_name" {
  description = "Name of a pre-existing EC2 key pair in this region."
  type        = string
}

variable "rhel_major_version" {
  description = "RHEL major version to look up. Only 8 or 9 are supported."
  type        = string
  default     = "9"

  validation {
    condition     = contains(["8", "9"], var.rhel_major_version)
    error_message = "rhel_major_version must be \"8\" or \"9\"."
  }
}

variable "instance_type" {
  description = "EC2 instance type for every host in the fleet."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 30
}

variable "root_volume_type" {
  description = "Root EBS volume type."
  type        = string
  default     = "gp3"
}

variable "instance_names" {
  description = "Hostnames for the fleet. One EC2 instance is created per element. Must be unique; used as the for_each key so naming changes destroy/recreate."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.instance_names) == length(distinct(var.instance_names))
    error_message = "instance_names must contain unique values; duplicates would collide as for_each keys."
  }
}

variable "ingress_cidrs" {
  description = "CIDR blocks allowed inbound on port 22 (and any extra_ingress_ports)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.ingress_cidrs : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", c))
    ])
    error_message = "Every ingress_cidrs entry must be IPv4 CIDR notation, e.g. 10.0.0.0/8."
  }
}

variable "extra_ingress_ports" {
  description = "Optional additional TCP ports to open from ingress_cidrs. Port 22 is always opened."
  type        = list(number)
  default     = []
}

variable "common_tags" {
  description = "Tags applied to every taggable resource. Must include a \"Project\" key (used in the security group name)."
  type        = map(string)
  default     = {}

  validation {
    condition     = contains(keys(var.common_tags), "Project")
    error_message = "common_tags must include a \"Project\" key."
  }
}

variable "user_data" {
  description = "Optional cloud-init / user-data string. Passed verbatim if non-empty."
  type        = string
  default     = ""
}
```

- [ ] **Step 3.2: Format and validate**

Run: `terraform fmt -check -diff && terraform validate`

Expected: format passes, `Success! The configuration is valid.`

Note: `validate` only checks that variable declarations are well-formed. It does not exercise the validation rules — those only fire when values are supplied. That's tested at the final plan step in Task 9.

- [ ] **Step 3.3: Commit**

```bash
git add variables.tf
git commit -m "Add input variables with validation rules"
```

---

## Task 4: Provider and RHEL AMI Data Source

**Files:**
- Create: `main.tf`

- [ ] **Step 4.1: Create `main.tf` with provider and AMI lookup**

```hcl
provider "aws" {
  region = var.aws_region
}

# Latest RHEL AMI published by Red Hat (owner ID 309956199498).
# Re-runs of `terraform apply` after Red Hat releases a new AMI will not
# replace running instances because the aws_instance resource pins via
# lifecycle.ignore_changes — see main.tf in Task 6.
data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199498"]

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

- [ ] **Step 4.2: Format and validate**

Run: `terraform fmt -check -diff && terraform validate`

Expected: format passes, `Success! The configuration is valid.`

- [ ] **Step 4.3: Commit**

```bash
git add main.tf
git commit -m "Add AWS provider and RHEL AMI data source"
```

---

## Task 5: Security Group and Ingress/Egress Rules

**Files:**
- Modify: `main.tf` (append)

- [ ] **Step 5.1: Append security group + rules to `main.tf`**

Append (do NOT overwrite the existing content from Task 4):

```hcl
resource "aws_security_group" "rhel" {
  name        = "${var.common_tags["Project"]}-rhel-sg"
  description = "RHEL fleet access"
  vpc_id      = var.vpc_id
  tags        = var.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ingress_cidrs)

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

Why split rules into separate `aws_vpc_security_group_*_rule` resources instead of inline `ingress`/`egress` blocks on the SG: separate resources let you add/remove individual rules without recreating the SG (which would detach it from running instances). The composite key `"${pair[0]}-${pair[1]}"` keeps the `for_each` map stable as long as CIDRs and ports don't change.

- [ ] **Step 5.2: Format and validate**

Run: `terraform fmt -check -diff && terraform validate`

Expected: format passes, `Success! The configuration is valid.`

- [ ] **Step 5.3: Commit**

```bash
git add main.tf
git commit -m "Add security group with per-rule resources"
```

---

## Task 6: EC2 Instance Resource

**Files:**
- Modify: `main.tf` (append)

- [ ] **Step 6.1: Append EC2 instance resource to `main.tf`**

Append (do NOT overwrite the existing content):

```hcl
resource "aws_instance" "rhel" {
  for_each = toset(var.instance_names)

  ami                         = data.aws_ami.rhel.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.rhel.id]
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

  # Don't replace running instances when Red Hat publishes a newer AMI.
  # New instances still get the latest AMI at creation time. To rebuild
  # an instance on the newest AMI:
  #   terraform apply -replace='aws_instance.rhel["<name>"]'
  lifecycle {
    ignore_changes = [ami]
  }
}
```

- [ ] **Step 6.2: Format and validate**

Run: `terraform fmt -check -diff && terraform validate`

Expected: format passes, `Success! The configuration is valid.`

- [ ] **Step 6.3: Commit**

```bash
git add main.tf
git commit -m "Add EC2 instance resource with for_each over hostnames"
```

---

## Task 7: Outputs

**Files:**
- Create: `outputs.tf`

- [ ] **Step 7.1: Create `outputs.tf`**

```hcl
output "instances" {
  description = "Map of hostname => instance attributes for downstream scripting."
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
  description = "ID of the security group attached to every RHEL instance."
  value       = aws_security_group.rhel.id
}

output "ami_id" {
  description = "AMI ID resolved at the last apply."
  value       = data.aws_ami.rhel.id
}
```

- [ ] **Step 7.2: Format and validate**

Run: `terraform fmt -check -diff && terraform validate`

Expected: format passes, `Success! The configuration is valid.`

- [ ] **Step 7.3: Commit**

```bash
git add outputs.tf
git commit -m "Add outputs for instance map, SG ID, and resolved AMI"
```

---

## Task 8: Example tfvars Template

**Files:**
- Create: `terraform.tfvars.example`

- [ ] **Step 8.1: Create `terraform.tfvars.example`**

```hcl
# Copy this file to terraform.tfvars and fill in your real values.
# terraform.tfvars is gitignored.

aws_region    = "us-east-1"
vpc_id        = "vpc-0123456789abcdef0"
subnet_id     = "subnet-0123456789abcdef0"
key_pair_name = "epm-lab-key"

rhel_major_version  = "9"
instance_type       = "t3.medium"
root_volume_size_gb = 30
root_volume_type    = "gp3"

instance_names = [
  "epm-rhel-01",
  "epm-rhel-02",
  "epm-rhel-03",
]

# CIDRs allowed inbound on port 22 (and any extra_ingress_ports).
# Do not use 0.0.0.0/0 unless you really mean it.
ingress_cidrs       = ["10.0.0.0/8"]
extra_ingress_ports = []

common_tags = {
  Project     = "epm-pineapple-lab"
  Environment = "lab"
  Owner       = "strick-j"
  ManagedBy   = "terraform"
}

# Leave empty for a plain RHEL boot, or set to e.g. file("./cloud-init.yaml")
user_data = ""
```

- [ ] **Step 8.2: Verify tfvars is gitignored**

Run: `git check-ignore -v terraform.tfvars`

Expected output (non-empty, exit 0):
```
.gitignore:5:terraform.tfvars	terraform.tfvars
```
(Line number may vary depending on the `.gitignore` content from Task 1.)

If exit code is 1 and no output, `terraform.tfvars` is NOT ignored — fix `.gitignore` before continuing.

- [ ] **Step 8.3: Commit**

```bash
git add terraform.tfvars.example
git commit -m "Add example tfvars template"
```

---

## Task 9: README Update and Final Validation

**Files:**
- Modify: `README.md`

- [ ] **Step 9.1: Replace `README.md` contents**

Current `README.md` is just the title. Replace its contents with:

````markdown
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
````

- [ ] **Step 9.2: Final format and validate sweep**

Run: `terraform fmt -check -diff && terraform validate`

Expected: format passes, `Success! The configuration is valid.`

- [ ] **Step 9.3: Optional — run `terraform plan` if AWS credentials and a real S3 bucket are available**

Only if the executor has:
- AWS credentials in the environment (`aws sts get-caller-identity` succeeds), and
- An S3 bucket they've put into `backend.tf`, and
- A real `terraform.tfvars` with valid VPC/subnet/key-pair IDs.

Run:
```bash
terraform init
terraform plan
```

Expected: a plan showing `N + 3 to add` (N instances + 1 SG + 1 egress rule + at least 1 ingress rule), `0 to change`, `0 to destroy`. The plan output should reference the resolved RHEL AMI ID for `data.aws_ami.rhel`.

If no AWS credentials are available, skip this step — `terraform validate` already proved the configuration is well-formed.

- [ ] **Step 9.4: Commit**

```bash
git add README.md
git commit -m "Document Terraform module usage and day-2 ops"
```

---

## Coverage check against the spec

| Spec requirement | Implemented in |
|---|---|
| N RHEL instances, latest minor of configurable major | Task 4 (AMI), Task 6 (instance) |
| Existing VPC/subnet from tfvars | Task 3 (variables), Task 5/6 (consumers) |
| Per-instance destroy | Task 6 (`for_each` over hostnames), Task 9 README |
| Tags from tfvars | Task 3 (`common_tags`), Task 5/6 (merged) |
| S3 backend + native locking | Task 2 |
| Private subnet, no public IP | Task 6 (`associate_public_ip_address = false`) |
| Existing key pair | Task 3 + Task 6 |
| Optional user_data | Task 3 + Task 6 |
| Validations (RHEL version, unique names, CIDRs, Project tag) | Task 3 |
| `terraform.tfvars.example` committed, `terraform.tfvars` gitignored | Task 1, Task 8 |
| Lifecycle ignore on AMI to prevent surprise replacements | Task 6 |
