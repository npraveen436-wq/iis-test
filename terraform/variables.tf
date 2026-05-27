variable "golden_ami_id" {
  description = "AMI ID. Leave empty to use latest Windows 2019 stock AMI"
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "test-iis-key"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "timezone" {
  description = "Windows timezone"
  type        = string
  default     = "Eastern Standard Time"
}

variable "secret_id" {
  description = "AWS Secrets Manager secret ID for app config"
  type        = string
  default     = "dev/app-config"
}

variable "servers" {
  description = "Map of server name -> config"
  type        = map(object({}))
  default = {
    "iis-test-01" = {}
  }
}
