variable "clusters" {
  description = "A map of Aurora cluster configurations, keyed by an arbitrary cluster key."
  type = map(object({
    # Naming / identity
    name            = string
    database_name   = optional(string, null)
    master_username = optional(string, "root")

    # Engine
    engine         = string
    engine_mode    = optional(string, "provisioned")
    engine_version = optional(string, null)

    # Cluster instance topology.
    # instance_count defaults to 2 for high availability (one writer + one reader).
    instance_count = optional(number, 2)
    instance_class = string

    # Serverless v2 scaling. When set, instance_class should be "db.serverless".
    # seconds_until_auto_pause enables scale-to-zero (Aurora Serverless v2 auto-pause);
    # mirrors terraform-aws-modules/rds-aurora serverlessv2_scaling_configuration (v9.11.0+).
    serverlessv2_scaling = optional(object({
      max_capacity             = number
      min_capacity             = optional(number, 0.5)
      seconds_until_auto_pause = optional(number, null)
    }), null)

    # Networking / access
    allowed_cidr_blocks = optional(list(string), [])
    port                = optional(number, null)

    # Backup / maintenance windows (retention is enforced module-wide via
    # var.backup_retention_period).
    preferred_backup_window      = optional(string, "22:00-03:00")
    preferred_maintenance_window = optional(string, "sun:06:00-sun:07:00")

    # Snapshots / lifecycle
    skip_final_snapshot       = optional(bool, true)
    final_snapshot_identifier = optional(string, null)
    snapshot_identifier       = optional(string, null)

    # Encryption. Storage is always encrypted; kms_key_id optionally selects a
    # customer-managed key (otherwise the AWS-managed aws/rds key is used).
    kms_key_id = optional(string, null)

    # Security / secrets. The master password is always managed by Aurora in
    # Secrets Manager (not configurable), so there is no manage_master_user_password
    # attribute. master_username names the managed master user.

    # Upgrades.
    allow_major_version_upgrade     = optional(bool, false)
    enabled_cloudwatch_logs_exports = optional(list(string), [])

    # Performance Insights encryption/retention (Performance Insights itself is
    # always enabled). Enhanced Monitoring is enforced module-wide via
    # var.monitoring_interval / var.monitoring_role_arn.
    performance_insights_kms_key_id       = optional(string, null)
    performance_insights_retention_period = optional(number, null)

    # Optional module-managed cluster parameter group
    create_cluster_parameter_group      = optional(bool, false)
    cluster_parameter_group_name        = optional(string, null)
    cluster_parameter_group_family      = optional(string, null)
    cluster_parameter_group_description = optional(string, null)
    cluster_parameter_group_parameters = optional(list(object({
      name         = string
      value        = string
      apply_method = optional(string, null)
    })), [])

    # Optional DNS records for the writer and reader endpoints.
    dns = optional(object({
      writer_name = optional(string, null)
      reader_name = optional(string, null)
      ttl         = optional(number, null)
    }), null)
  }))
}

variable "project_name" {
  description = "Name of the project."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)."
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC where the Aurora cluster will be created."
  type        = string
}

variable "subnet_ids" {
  description = "A list of subnet IDs for the DB subnet group. Used only when db_subnet_group_name is not provided."
  type        = list(string)
  default     = []
}

variable "db_subnet_group_name" {
  description = "The name of an existing DB subnet group to use. If null, the module creates one from subnet_ids."
  type        = string
  default     = null
}

variable "security_group_ids" {
  description = "A map of existing security group IDs to use, keyed by the cluster key. If null, the module creates a security group per cluster."
  type        = map(string)
  default     = null
}

variable "vpc_security_group_ids" {
  description = "A list of additional VPC security group IDs to attach to every cluster."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "A list of CIDR blocks allowed to reach the cluster. Used for both ingress and egress on module-created security groups."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "dns_zone" {
  description = "Private Route53 hosted zone name used to create DNS records for cluster endpoints. If null/empty, no DNS records are created."
  type        = string
  default     = null
}

variable "dns_ttl" {
  description = "Time to live, in seconds, for Route53 DNS records created for Aurora endpoints."
  type        = number
  default     = 300
}

# =============================================================================
# Security baseline (module-wide)
#
# These settings are applied to every cluster/instance so the module enforces a
# secure-by-default posture. They are module-level (not per-cluster) so the
# baseline cannot be silently weakened for an individual cluster.
# =============================================================================

variable "backup_retention_period" {
  description = "Days to retain automated backups for every cluster. Must be at least 1."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1
    error_message = "backup_retention_period must be at least 1 day."
  }
}

variable "iam_database_authentication_enabled" {
  description = "Enable IAM database authentication for every cluster."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable deletion protection for every cluster. Set to false only for disposable/test clusters."
  type        = bool
  default     = true
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds for every instance (0 disables). Defaults to 60."
  type        = number
  default     = 60
}

variable "monitoring_role_arn" {
  description = "IAM role ARN for Enhanced Monitoring. If null and monitoring_interval > 0, the module creates one."
  type        = string
  default     = null
}

variable "create_backup_plan" {
  description = "Create an AWS Backup vault, plan and selection covering every managed cluster. Enabled by default so clusters are protected by a managed backup plan in addition to automated RDS backups."
  type        = bool
  default     = true
}

variable "backup_schedule" {
  description = "Cron expression for the AWS Backup plan rule when create_backup_plan is true."
  type        = string
  default     = "cron(0 5 ? * * *)"
}

variable "backup_delete_after_days" {
  description = "Number of days after which AWS Backup recovery points are deleted."
  type        = number
  default     = 35
}

variable "backup_vault_kms_key_arn" {
  description = "KMS key ARN for the AWS Backup vault. If null, AWS Backup uses its default key."
  type        = string
  default     = null
}

variable "tags" {
  type = object({
    cost-centre      = string
    account-code     = string
    portfolio-id     = string
    project-id       = string
    service-id       = string
    environment-type = string
    owner-business   = string
    budget-holder    = string
    source-repo      = string
    hosting-platform = string
  })
  description = "The following tags must be applied to all resources: cost-centre, account-code, portfolio-id, project-id, service-id, environment-type, owner-business and budget-holder."
  nullable    = false
}
