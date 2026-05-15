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
