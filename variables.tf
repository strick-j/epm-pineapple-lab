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
