data "aws_db_subnet_group" "existing" {
  count = var.db_subnet_group_name != null ? 1 : 0
  name  = var.db_subnet_group_name
}

data "aws_route53_zone" "selected" {
  count        = local.dns_zone_normalized != "" ? 1 : 0
  name         = "${trimsuffix(local.dns_zone_normalized, ".")}."
  private_zone = true
}

# IAM role for RDS Enhanced Monitoring, created only when Enhanced Monitoring is
# enabled (var.monitoring_interval > 0) and the caller has not supplied their own
# role via var.monitoring_role_arn.
data "aws_iam_policy_document" "rds_monitoring_assume" {
  count = var.monitoring_interval > 0 && var.monitoring_role_arn == null ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  count              = var.monitoring_interval > 0 && var.monitoring_role_arn == null ? 1 : 0
  name               = "${var.project_name}-${var.environment}-aurora-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume[0].json

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-aurora-monitoring"
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  count      = var.monitoring_interval > 0 && var.monitoring_role_arn == null ? 1 : 0
  role       = aws_iam_role.rds_enhanced_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_subnet_group" "this" {
  count      = var.db_subnet_group_name == null ? 1 : 0
  name       = "${var.project_name}-${var.environment}-aurora-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-aurora-subnet-group"
  })
}

resource "aws_security_group" "this" {
  for_each    = var.security_group_ids == null ? var.clusters : {}
  name        = "${var.project_name}-${var.environment}-${each.key}-aurora-sg"
  description = "Security group for ${each.key} Aurora cluster"
  vpc_id      = var.vpc_id

  ingress {
    # Look up the port based on the cluster's engine type (or explicit override).
    from_port   = local.cluster_ports[each.key]
    to_port     = local.cluster_ports[each.key]
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Ingress to ${each.key} Aurora cluster"
  }

  egress {
    # Egress is restricted to the database port over TCP and scoped to the
    # allowed CIDR blocks, rather than opening all protocols/ports (protocol -1).
    from_port   = local.cluster_ports[each.key]
    to_port     = local.cluster_ports[each.key]
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Egress from ${each.key} Aurora cluster"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-${each.key}-aurora-sg"
  })
}

resource "aws_rds_cluster_parameter_group" "this" {
  for_each = local.cluster_parameter_groups_to_create

  name        = each.value.name
  family      = each.value.family
  description = each.value.description

  dynamic "parameter" {
    for_each = each.value.parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = each.value.family != null
      error_message = "cluster_parameter_group_family must be set when create_cluster_parameter_group is true."
    }

    precondition {
      condition     = length([for _, config in local.cluster_parameter_groups_to_create : config.name]) == length(distinct([for _, config in local.cluster_parameter_groups_to_create : config.name]))
      error_message = "Module-created cluster parameter groups cannot be shared across clusters."
    }
  }

  tags = merge(var.tags, {
    Name = each.value.name
  })
}

resource "aws_rds_cluster" "this" {
  for_each = var.clusters

  cluster_identifier = each.value.name
  engine             = each.value.engine
  engine_mode        = each.value.engine_mode
  engine_version     = each.value.snapshot_identifier == null ? each.value.engine_version : null

  # No plaintext password: either the module manages the master user password in
  # Secrets Manager, or the master_username is set for a caller-managed secret.
  database_name               = each.value.snapshot_identifier == null ? each.value.database_name : null
  master_username             = (each.value.snapshot_identifier == null && each.value.manage_master_user_password) ? each.value.master_username : null
  manage_master_user_password = each.value.snapshot_identifier == null ? each.value.manage_master_user_password : null

  port                            = local.cluster_ports[each.key]
  db_subnet_group_name            = var.db_subnet_group_name != null ? data.aws_db_subnet_group.existing[0].name : aws_db_subnet_group.this[0].name
  db_cluster_parameter_group_name = local.cluster_parameter_group_name_by_cluster[each.key]
  vpc_security_group_ids          = var.security_group_ids != null ? concat([var.security_group_ids[each.key]], var.vpc_security_group_ids) : concat([aws_security_group.this[each.key].id], var.vpc_security_group_ids)

  # Automated backups: retention is enforced module-wide (>= 1 day) and cluster
  # tags are always copied to snapshots.
  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = each.value.preferred_backup_window
  preferred_maintenance_window = each.value.preferred_maintenance_window
  copy_tags_to_snapshot        = true

  # Minor engine upgrades are always applied automatically; major upgrades remain
  # an explicit per-cluster opt-in.
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = each.value.allow_major_version_upgrade

  # IAM database authentication is enforced module-wide.
  iam_database_authentication_enabled = var.iam_database_authentication_enabled

  # Storage is always encrypted at rest; kms_key_id optionally selects a CMK.
  storage_encrypted = true
  kms_key_id        = each.value.kms_key_id

  # Deletion protection is enforced module-wide (default on).
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = each.value.skip_final_snapshot
  final_snapshot_identifier       = each.value.final_snapshot_identifier
  snapshot_identifier             = each.value.snapshot_identifier
  enabled_cloudwatch_logs_exports = each.value.enabled_cloudwatch_logs_exports

  dynamic "serverlessv2_scaling_configuration" {
    for_each = each.value.serverlessv2_scaling != null ? [each.value.serverlessv2_scaling] : []
    content {
      min_capacity             = serverlessv2_scaling_configuration.value.min_capacity
      max_capacity             = serverlessv2_scaling_configuration.value.max_capacity
      seconds_until_auto_pause = serverlessv2_scaling_configuration.value.seconds_until_auto_pause
    }
  }

  tags = merge(var.tags, {
    Name = each.value.name
  })

  timeouts {
    create = "120m"
    update = "120m"
    delete = "120m"
  }
}

resource "aws_rds_cluster_instance" "this" {
  for_each = local.cluster_instances

  identifier         = each.value.identifier
  cluster_identifier = aws_rds_cluster.this[each.value.cluster_key].id
  instance_class     = each.value.instance_class
  engine             = each.value.cluster.engine
  engine_version     = each.value.cluster.engine_version

  db_subnet_group_name = var.db_subnet_group_name != null ? data.aws_db_subnet_group.existing[0].name : aws_db_subnet_group.this[0].name

  # Minor engine upgrades are always applied automatically.
  auto_minor_version_upgrade = true

  # Performance Insights is always enabled; encryption key and retention remain
  # configurable per cluster.
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = each.value.cluster.performance_insights_kms_key_id
  performance_insights_retention_period = each.value.cluster.performance_insights_retention_period

  # Enhanced Monitoring is enforced module-wide via var.monitoring_interval.
  # A module-created role is used unless the caller supplies monitoring_role_arn.
  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? coalesce(var.monitoring_role_arn, try(aws_iam_role.rds_enhanced_monitoring[0].arn, null)) : null

  tags = merge(var.tags, {
    Name = each.value.identifier
  })
}

resource "aws_route53_record" "writer" {
  for_each = local.writer_dns_records

  zone_id = data.aws_route53_zone.selected[0].id
  name    = trimspace(each.value.dns.writer_name)
  type    = "CNAME"
  ttl     = coalesce(try(each.value.dns.ttl, null), var.dns_ttl)
  records = [aws_rds_cluster.this[each.key].endpoint]

  lifecycle {
    precondition {
      condition     = local.dns_record_names_unique
      error_message = "Duplicate value in clusters[*].dns.*_name. Each DNS record name must be unique within its hosted zone."
    }
  }
}

resource "aws_route53_record" "reader" {
  for_each = local.reader_dns_records

  zone_id = data.aws_route53_zone.selected[0].id
  name    = trimspace(each.value.dns.reader_name)
  type    = "CNAME"
  ttl     = coalesce(try(each.value.dns.ttl, null), var.dns_ttl)
  records = [aws_rds_cluster.this[each.key].reader_endpoint]

  lifecycle {
    precondition {
      condition     = local.dns_record_names_unique
      error_message = "Duplicate value in clusters[*].dns.*_name. Each DNS record name must be unique within its hosted zone."
    }
  }
}

# =============================================================================
# AWS Backup
#
# When create_backup_plan is true (the default) the module creates a backup
# vault, a plan and a selection covering every managed Aurora cluster. This
# supplements the clusters' automated RDS backups with a managed AWS Backup plan.
# =============================================================================

resource "aws_backup_vault" "this" {
  count       = var.create_backup_plan ? 1 : 0
  name        = "${var.project_name}-${var.environment}-aurora-vault"
  kms_key_arn = var.backup_vault_kms_key_arn

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-aurora-vault"
  })
}

resource "aws_backup_plan" "this" {
  count = var.create_backup_plan ? 1 : 0
  name  = "${var.project_name}-${var.environment}-aurora-plan"

  rule {
    rule_name         = "${var.project_name}-${var.environment}-aurora-daily"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = var.backup_schedule

    lifecycle {
      delete_after = var.backup_delete_after_days
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-aurora-plan"
  })
}

data "aws_iam_policy_document" "backup_assume" {
  count = var.create_backup_plan ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count              = var.create_backup_plan ? 1 : 0
  name               = "${var.project_name}-${var.environment}-aurora-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume[0].json

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-aurora-backup"
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.create_backup_plan ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "this" {
  count        = var.create_backup_plan ? 1 : 0
  name         = "${var.project_name}-${var.environment}-aurora-selection"
  iam_role_arn = aws_iam_role.backup[0].arn
  plan_id      = aws_backup_plan.this[0].id

  resources = [for k, v in aws_rds_cluster.this : v.arn]
}
