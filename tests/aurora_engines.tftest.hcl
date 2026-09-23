// Mock provider to avoid real AWS calls during tests.
// aws_iam_policy_document.json is mocked with a valid JSON policy so IAM roles
// (Enhanced Monitoring and AWS Backup) accept it during plan.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  project_name = "demo"
  environment  = "dev"
  vpc_id       = "vpc-00000000000000000"
  subnet_ids   = ["subnet-aaaaaaaaaaaaaaaaa", "subnet-bbbbbbbbbbbbbbbbb"]

  allowed_cidr_blocks = ["10.0.0.0/8"]

  // Required organization tags
  tags = {
    cost-centre      = "CC1001"
    account-code     = "AC2002"
    portfolio-id     = "PF3003"
    project-id       = "PR4004"
    service-id       = "SV5005"
    environment-type = "nonprod"
    owner-business   = "platform"
    budget-holder    = "finops"
    source-repo      = "Home-Office-Digital/core-cloud-aurora-tf-module"
    hosting-platform = "test-platform"
  }

  // Default cluster used unless a run block overrides it.
  clusters = {
    app = {
      name           = "app-aurora"
      database_name  = "appdb"
      engine         = "aurora-mysql"
      engine_version = "8.0.mysql_aurora.3.05.2"
      instance_class = "db.r6g.large"
    }
  }
}

# Aurora MySQL: default HA topology (2 instances) and port 3306.
run "aurora_mysql_defaults" {
  command = plan

  variables {
    security_group_ids = null
    clusters = {
      mysql = {
        name           = "test-aurora-mysql"
        database_name  = "appdb"
        engine         = "aurora-mysql"
        engine_version = "8.0.mysql_aurora.3.05.2"
        instance_class = "db.r6g.large"
      }
    }
  }

  # Cluster engine is Aurora MySQL.
  assert {
    condition     = aws_rds_cluster.this["mysql"].engine == "aurora-mysql"
    error_message = "Cluster engine must be aurora-mysql"
  }

  # Aurora MySQL listens on 3306.
  assert {
    condition     = aws_rds_cluster.this["mysql"].port == 3306
    error_message = "Aurora MySQL must use port 3306"
  }

  # Security group ingress uses the MySQL port.
  assert {
    condition = alltrue([
      for rule in aws_security_group.this["mysql"].ingress :
      rule.from_port == 3306 && rule.to_port == 3306 && rule.protocol == "tcp"
    ])
    error_message = "Aurora MySQL security group ingress must be TCP/3306"
  }

  # instance_count defaults to 2 for high availability.
  assert {
    condition     = length([for k, _ in aws_rds_cluster_instance.this : k if startswith(k, "mysql-")]) == 2
    error_message = "Aurora MySQL cluster must default to 2 instances for HA"
  }

  # No plaintext password: Aurora manages the master user password.
  assert {
    condition     = aws_rds_cluster.this["mysql"].manage_master_user_password == true
    error_message = "manage_master_user_password must default to true"
  }

  # auto_minor_version_upgrade is set at the cluster level (upstream v10.3.0).
  assert {
    condition     = aws_rds_cluster.this["mysql"].auto_minor_version_upgrade == true
    error_message = "auto_minor_version_upgrade must default to true at the cluster level"
  }

  # IAM database authentication is enabled by default.
  assert {
    condition     = aws_rds_cluster.this["mysql"].iam_database_authentication_enabled == true
    error_message = "iam_database_authentication_enabled must default to true"
  }

  # Storage is always encrypted at rest.
  assert {
    condition     = aws_rds_cluster.this["mysql"].storage_encrypted == true
    error_message = "storage_encrypted must be enforced to true"
  }

  # Deletion protection is enabled by default.
  assert {
    condition     = aws_rds_cluster.this["mysql"].deletion_protection == true
    error_message = "deletion_protection must default to true"
  }

  # Automated backups retained for at least 1 day (default 7).
  assert {
    condition     = aws_rds_cluster.this["mysql"].backup_retention_period == 7
    error_message = "backup_retention_period must default to 7 days"
  }

  # Cluster tags are copied to snapshots.
  assert {
    condition     = aws_rds_cluster.this["mysql"].copy_tags_to_snapshot == true
    error_message = "copy_tags_to_snapshot must be enforced to true"
  }

  # Performance Insights is enabled on instances.
  assert {
    condition = alltrue([
      for k, inst in aws_rds_cluster_instance.this : inst.performance_insights_enabled == true
      if startswith(k, "mysql-")
    ])
    error_message = "performance_insights_enabled must be enforced to true"
  }

  # Enhanced Monitoring is enabled by default (interval > 0).
  assert {
    condition = alltrue([
      for k, inst in aws_rds_cluster_instance.this : inst.monitoring_interval == 60
      if startswith(k, "mysql-")
    ])
    error_message = "monitoring_interval must default to 60 seconds"
  }

  # An AWS Backup selection covers the managed cluster by default.
  assert {
    condition     = length(aws_backup_selection.this) == 1
    error_message = "An AWS Backup selection must be created by default"
  }
}

# Aurora PostgreSQL: port 5432 and engine assertion.
run "aurora_postgresql_defaults" {
  command = plan

  variables {
    security_group_ids = null
    clusters = {
      postgres = {
        name           = "test-aurora-postgres"
        database_name  = "appdb"
        engine         = "aurora-postgresql"
        engine_version = "15.10"
        instance_class = "db.r6g.large"
      }
    }
  }

  assert {
    condition     = aws_rds_cluster.this["postgres"].engine == "aurora-postgresql"
    error_message = "Cluster engine must be aurora-postgresql"
  }

  # Aurora PostgreSQL listens on 5432.
  assert {
    condition     = aws_rds_cluster.this["postgres"].port == 5432
    error_message = "Aurora PostgreSQL must use port 5432"
  }

  assert {
    condition = alltrue([
      for rule in aws_security_group.this["postgres"].ingress :
      rule.from_port == 5432 && rule.to_port == 5432 && rule.protocol == "tcp"
    ])
    error_message = "Aurora PostgreSQL security group ingress must be TCP/5432"
  }
}

# Serverless v2: db.serverless instances with scaling configuration.
run "aurora_serverless_v2" {
  command = plan

  variables {
    security_group_ids = null
    clusters = {
      serverless = {
        name           = "test-aurora-serverless"
        database_name  = "appdb"
        engine         = "aurora-postgresql"
        engine_version = "15.10"
        instance_class = "db.serverless"
        instance_count = 1
        serverlessv2_scaling = {
          min_capacity             = 0
          max_capacity             = 4
          seconds_until_auto_pause = 3600
        }
      }
    }
  }

  # Serverless v2 scaling configuration is applied to the cluster, including
  # scale-to-zero auto-pause (seconds_until_auto_pause, upstream v9.11.0+).
  assert {
    condition = alltrue([
      for cfg in aws_rds_cluster.this["serverless"].serverlessv2_scaling_configuration :
      cfg.min_capacity == 0 && cfg.max_capacity == 4 && cfg.seconds_until_auto_pause == 3600
    ])
    error_message = "Serverless v2 scaling must set min 0 / max 4 ACUs with auto-pause after 3600s"
  }

  # Serverless v2 instances use the db.serverless class.
  assert {
    condition = alltrue([
      for k, inst in aws_rds_cluster_instance.this : inst.instance_class == "db.serverless"
      if startswith(k, "serverless-")
    ])
    error_message = "Serverless v2 cluster instances must use db.serverless"
  }

  # Enhanced Monitoring is unsupported on Aurora Serverless v2, so the module
  # disables it (monitoring_interval = 0) for db.serverless instances.
  assert {
    condition = alltrue([
      for k, inst in aws_rds_cluster_instance.this : inst.monitoring_interval == 0
      if startswith(k, "serverless-")
    ])
    error_message = "Enhanced Monitoring must be disabled (interval 0) for db.serverless instances"
  }
}

# Writer and reader endpoints are exposed as outputs.
run "writer_reader_endpoints" {
  command = plan

  variables {
    security_group_ids = null
    clusters = {
      endpoints = {
        name           = "test-aurora-endpoints"
        database_name  = "appdb"
        engine         = "aurora-mysql"
        engine_version = "8.0.mysql_aurora.3.05.2"
        instance_class = "db.r6g.large"
      }
    }
  }

  # Writer endpoint output is present for the cluster.
  assert {
    condition     = contains(keys(output.writer_endpoints), "endpoints")
    error_message = "writer_endpoints output must contain an entry per cluster"
  }

  # Reader endpoint output is present for the cluster.
  assert {
    condition     = contains(keys(output.reader_endpoints), "endpoints")
    error_message = "reader_endpoints output must contain an entry per cluster"
  }
}
