data "aws_db_subnet_group" "existing" {
  count = var.db_subnet_group_name != null ? 1 : 0
  name  = var.db_subnet_group_name
}

data "aws_route53_zone" "selected" {
  count        = local.dns_zone_normalized != "" ? 1 : 0
  name         = "${trimsuffix(local.dns_zone_normalized, ".")}."
  private_zone = true
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
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Egress is scoped to the allowed CIDR blocks rather than left open.
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

  backup_retention_period      = each.value.backup_retention_period
  preferred_backup_window      = each.value.preferred_backup_window
  preferred_maintenance_window = each.value.preferred_maintenance_window
  copy_tags_to_snapshot        = each.value.copy_tags_to_snapshot

  # Cluster-level version upgrade control (aws_rds_cluster.auto_minor_version_upgrade,
  # aligned with terraform-aws-modules/rds-aurora v10.3.0). Performance Insights and
  # Enhanced Monitoring are configured per-instance below, matching how the upstream
  # module wires standard (non-Multi-AZ) Aurora clusters.
  auto_minor_version_upgrade  = each.value.auto_minor_version_upgrade
  allow_major_version_upgrade = each.value.allow_major_version_upgrade

  storage_encrypted = each.value.storage_encrypted
  kms_key_id        = each.value.kms_key_id

  deletion_protection             = each.value.deletion_protection
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

  auto_minor_version_upgrade = each.value.cluster.auto_minor_version_upgrade

  # Performance Insights and Enhanced Monitoring are per-instance for standard
  # Aurora (see terraform-aws-modules/rds-aurora aws_rds_cluster_instance).
  performance_insights_enabled          = each.value.cluster.performance_insights_enabled
  performance_insights_kms_key_id       = each.value.cluster.performance_insights_kms_key_id
  performance_insights_retention_period = each.value.cluster.performance_insights_enabled ? each.value.cluster.performance_insights_retention_period : null
  monitoring_interval                   = each.value.cluster.monitoring_interval
  monitoring_role_arn                   = each.value.cluster.monitoring_interval > 0 ? each.value.cluster.monitoring_role_arn : null

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
