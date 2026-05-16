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

variable "team_name" {
  description = "Name of the team for tagging purposes"
  type        = string
}

# Resource Tag Variables
variable "asset_owner_name" {
  description = "Name of the human that the cloud team can contact with questions"
  type        = string
}

variable "iScheduler" {
  description = "iScheduler tag value"
  type        = string
}

variable "iCreator_CreatorBy" {
  description = "iCreator_CreatorBy tag value"
  type        = string
}

# Generic variables for the CyberArk ISPSS Platform
variable "platform_tenant_name" {
  description = "Platform tenant name for Identity Tenant (e.g. subdomain)"
  type        = string
}

variable "identity_tenant_id" {
  description = "Identity tenant ID for Identity Authentication (e.g. abc12345)"
  type        = string
}

# Variables below are used to authenticate and retrieve 
# credentials from Conjur Cloud.
variable "service_id" {
  description = "Service ID for Conjur Authentication configuration"
  type        = string
}

variable "aws_role_name" {
  description = "AWS role name for the EC2 instance"
  type        = string
}

variable "host_id" {
  description = "Host ID for Conjur Authentication configuration"
  type        = string
}

variable "username_variable" {
  description = "Username variable for Conjur retrieval"
  type        = string
}

variable "password_variable" {
  description = "Password variable for Conjur retrieval"
  type        = string
}

# SIA specific variables
variable "workspace_id" {
  description = "Workspace ID for SIA configuration"
  type        = string
}

variable "workspace_type" {
  description = "Workspace type for SIA configuration"
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

variable "extra_security_group_ids" {
  description = "IDs of pre-existing security groups to attach to every instance, alongside the SG this module creates."
  type        = list(string)
  default     = []
}

variable "common_tags" {
  description = "Tags applied to every taggable resource. Must include \"Project\" (used in the security group name) and \"I_Owner\"."
  type        = map(string)
  default     = {}

  validation {
    condition     = contains(keys(var.common_tags), "Project")
    error_message = "common_tags must include a \"Project\" key."
  }

  validation {
    condition     = contains(keys(var.common_tags), "I_Owner")
    error_message = "common_tags must include an \"I_Owner\" key."
  }
}

variable "iam_instance_profile" {
  description = "Name of a pre-existing IAM instance profile to attach to every instance (e.g., for S3 access from user_data). Leave null to attach no profile."
  type        = string
  default     = null
}

variable "user_data" {
  description = "Optional cloud-init / user-data string. Passed verbatim if non-empty."
  type        = string
  default     = ""
}

# CyberArk variables
variable "s3_bucket_name" {
  description = "Name of the S3 bucket where the scripts are located"
  type        = string
}

# EPM agent install variables
variable "epm_installer_s3_key" {
  description = "S3 object key (within s3_bucket_name) of the EPM agent installer RPM, e.g. installers/epm-rhel9.x86_64.rpm."
  type        = string
}

variable "epm_installation_key" {
  description = "EPM installation key tied to the EPM set the agent should register with. Passed to scripts/03_install_epm.sh via the EPM_INSTALLATION_KEY env var."
  type        = string
  sensitive   = true
}
