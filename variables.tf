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

    # Backup / maintenance
    backup_retention_period      = optional(number, 7)
    preferred_backup_window      = optional(string, "22:00-03:00")
    preferred_maintenance_window = optional(string, "sun:06:00-sun:07:00")
    copy_tags_to_snapshot        = optional(bool, true)

    # Snapshots / lifecycle
    deletion_protection       = optional(bool, true)
    skip_final_snapshot       = optional(bool, true)
    final_snapshot_identifier = optional(string, null)
    snapshot_identifier       = optional(string, null)

    # Encryption
    storage_encrypted = optional(bool, true)
    kms_key_id        = optional(string, null)

    # Security / secrets
    manage_master_user_password = optional(bool, true)

    # Upgrades / monitoring.
    # auto_minor_version_upgrade is applied at the cluster level (mirrors
    # terraform-aws-modules/rds-aurora v10.3.0) as well as on each instance.
    auto_minor_version_upgrade      = optional(bool, true)
    allow_major_version_upgrade     = optional(bool, false)
    enabled_cloudwatch_logs_exports = optional(list(string), [])

    # Performance Insights and Enhanced Monitoring are configured at the cluster
    # level (mirrors upstream cluster_performance_insights_* / cluster_monitoring_interval,
    # v9.8.0 and v9.12.0) and propagate to the cluster instances.
    performance_insights_enabled          = optional(bool, true)
    performance_insights_kms_key_id       = optional(string, null)
    performance_insights_retention_period = optional(number, null)
    monitoring_interval                   = optional(number, 0)
    monitoring_role_arn                   = optional(string, null)

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

variable "manage_master_user_password" {
  description = "Set to true to allow Aurora to manage the master user password in Secrets Manager. When true, no plaintext password is set."
  type        = bool
  default     = true
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
