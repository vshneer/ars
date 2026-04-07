variable "aws_region" {
  type        = string
  description = "AWS region for the stack"
  default     = "us-east-1"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for AWS resource names"
  default     = "ars"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type"
  default     = "t3.micro"
}

variable "root_volume_size_gb" {
  type        = number
  description = "Root disk size in GiB"
  default     = 20
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for the ubuntu user"
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "CIDR allowed to SSH into the instance"
}

variable "repo_clone_url" {
  type        = string
  description = "Git clone URL used by the bootstrap script"
  default     = "git@github.com:vshneer/ars.git"
}

variable "github_deploy_key_parameter_name" {
  type        = string
  description = "SSM parameter holding the GitHub deploy key private key"
  default     = ""
}

variable "notify_config_parameter_name" {
  type        = string
  description = "SSM parameter holding notify-config.yaml contents"
  default     = ""
}

variable "subfinder_config_parameter_name" {
  type        = string
  description = "SSM parameter holding subfinder-config.yaml contents"
  default     = ""
}

variable "enable_scanners" {
  type        = bool
  description = "Enable subfinder, httpx, and nuclei in cron"
  default     = false
}
