provider "aws" {
  region = var.aws_region
}

# Latest RHEL AMI published by Red Hat (owner ID 309956199498).
# Re-runs of `terraform apply` after Red Hat releases a new AMI will not
# replace running instances because aws_instance.rhel pins ami via
# lifecycle.ignore_changes.
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
  tags              = var.common_tags
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
  tags              = var.common_tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.rhel.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  tags              = var.common_tags
}

resource "aws_instance" "rhel" {
  for_each = toset(var.instance_names)

  ami                         = data.aws_ami.rhel.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = concat([aws_security_group.rhel.id], var.extra_security_group_ids)
  iam_instance_profile        = var.iam_instance_profile
  key_name                    = var.key_pair_name
  associate_public_ip_address = false

  user_data = <<-EOF
#!/bin/bash -xe

# Security updates only — avoid pulling unrelated kernel/feature updates on first boot
dnf update -y --security

# Dependencies needed by /opt/sia/*.sh
dnf install -y unzip jq

# AWS CLI v2 (stock RHEL 9 repos don't ship an aws-cli package)
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# Export variables for scripts
export IDENTITY_TENANT_ID="${var.identity_tenant_id}"
export PLATFORM_TENANT_NAME="${var.platform_tenant_name}"
export WORKSPACE_ID="${var.workspace_id}"
export WORKSPACE_TYPE="${var.workspace_type}"
export AWS_ROLE_NAME="${var.aws_role_name}"
export SERVICE_ID="${var.service_id}"
export HOST_ID="${var.host_id}"
export USERNAME_VARIABLE="${var.username_variable}"
export PASSWORD_VARIABLE="${var.password_variable}"

# EPM agent install
export EPM_INSTALLER_S3_URI="s3://${var.s3_bucket_name}/${var.epm_installer_s3_key}"
export EPM_INSTALLATION_KEY="${var.epm_installation_key}"

SSHD_DIR=/var/run/sshd
SCRIPTS_DIR=/opt/sia
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$SSHD_DIR"

aws s3 cp s3://${var.s3_bucket_name}/scripts "$SCRIPTS_DIR" --recursive

# make scripts executable
chmod +x "$SCRIPTS_DIR"/*.sh

# run them
"$SCRIPTS_DIR/01_init.sh" "${each.key}"
"$SCRIPTS_DIR/02_configure_target.sh"
"$SCRIPTS_DIR/03_install_epm.sh"
EOF

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = var.root_volume_type
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = merge(
    var.common_tags,
    {
      Name               = each.key
      Team               = var.team_name
      AssetOwner         = var.asset_owner_name
      iScheduler         = var.iScheduler
      iCreator_CreatorBy = var.iCreator_CreatorBy
    },
  )

  # Don't replace running instances when Red Hat publishes a newer AMI.
  # New instances still get the latest AMI at creation time. To rebuild
  # an instance on the newest AMI:
  #   terraform apply -replace='aws_instance.rhel["<name>"]'
  lifecycle {
    ignore_changes = [ami]
  }
}
