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
