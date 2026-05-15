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

  # Don't replace running instances when Red Hat publishes a newer AMI.
  # New instances still get the latest AMI at creation time. To rebuild
  # an instance on the newest AMI:
  #   terraform apply -replace='aws_instance.rhel["<name>"]'
  lifecycle {
    ignore_changes = [ami]
  }
}
