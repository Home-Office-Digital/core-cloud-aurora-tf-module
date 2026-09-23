# core-cloud-aurora-tf-module

A Core Cloud Terraform module for provisioning [Amazon Aurora](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/CHAP_AuroraOverview.html) clusters. It supports Aurora MySQL and Aurora PostgreSQL, both provisioned and Serverless v2 capacity, and mirrors the conventions of the `core-cloud-rds-tf-module`.

## Overview

The module takes a `clusters` map of typed objects and, for each entry, creates:

- An `aws_rds_cluster` (the Aurora cluster itself).
- One or more `aws_rds_cluster_instance` members via `for_each` (defaults to 2 for high availability — one writer plus one reader).
- An optional `aws_rds_cluster_parameter_group` when `create_cluster_parameter_group` is set.
- A per-cluster `aws_security_group` (unless you supply your own via `security_group_ids`), with ingress and egress scoped to `allowed_cidr_blocks`.
- Optional Route53 `CNAME` records for the writer and reader endpoints.

A single `aws_db_subnet_group` is shared across clusters (or you can pass an existing one with `db_subnet_group_name`).

Key design choices:

- **No plaintext passwords.** Aurora always manages the master user password in AWS Secrets Manager (this is enforced, not configurable). The secret ARN is exposed via the `master_user_secret_arns` output.
- **`for_each`, not `count`.** Both clusters and cluster instances are keyed maps, so adding or removing a cluster does not churn unrelated resources.
- **Scoped egress.** Module-created security groups restrict egress to `allowed_cidr_blocks` rather than allowing all outbound traffic.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.7.5 |
| aws | >= 6.61.0 |

The AWS provider floor (`>= 6.61.0`) matches the requirement of [`terraform-aws-modules/rds-aurora`](https://registry.terraform.io/modules/terraform-aws-modules/rds-aurora/aws/latest) v10, whose recent conventions this module follows.

## Clusters input

Each entry in `var.clusters` is an object with the following attributes.

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | — | Cluster identifier and base name for instances/records. |
| `database_name` | string | `null` | Initial database name. Ignored when restoring from a snapshot. |
| `master_username` | string | `"root"` | Master username. Set only when not restoring from a snapshot. |
| `engine` | string | — | `aurora-mysql` or `aurora-postgresql`. |
| `engine_mode` | string | `"provisioned"` | Cluster engine mode. Use `provisioned` for Serverless v2. |
| `engine_version` | string | `null` | Engine version (e.g. `8.0.mysql_aurora.3.05.2`, `15.10`). |
| `instance_count` | number | `2` | Number of cluster instances. Defaults to 2 for HA. |
| `instance_class` | string | — | Instance class (e.g. `db.r6g.large`, or `db.serverless` for Serverless v2). |
| `serverlessv2_scaling` | object | `null` | `{ max_capacity, min_capacity = 0.5, seconds_until_auto_pause = null }` in ACUs. Set for Serverless v2. Use `min_capacity = 0` with `seconds_until_auto_pause` to enable scale-to-zero auto-pause. |
| `allowed_cidr_blocks` | list(string) | `[]` | Reserved for per-cluster overrides; module SG uses `var.allowed_cidr_blocks`. |
| `port` | number | `null` | Listener port override. Defaults to the engine port (3306 / 5432). |
| `preferred_backup_window` | string | `"22:00-03:00"` | Daily backup window (must not overlap maintenance). |
| `preferred_maintenance_window` | string | `"sun:06:00-sun:07:00"` | Weekly maintenance window. |
| `skip_final_snapshot` | bool | `true` | Skip the final snapshot on destroy. |
| `final_snapshot_identifier` | string | `null` | Name for the final snapshot when not skipped. |
| `snapshot_identifier` | string | `null` | Restore the cluster from this snapshot. |
| `kms_key_id` | string | `null` | KMS key ARN for storage encryption (a CMK; storage is always encrypted). |
| `allow_major_version_upgrade` | bool | `false` | Allow major engine version upgrades when changing `engine_version`. |
| `enabled_cloudwatch_logs_exports` | list(string) | `[]` | Log types to export to CloudWatch. |
| `performance_insights_kms_key_id` | string | `null` | KMS key for Performance Insights data. |
| `performance_insights_retention_period` | number | `null` | Days to retain Performance Insights data (7, or `31 * n`, or 731). |
| `create_cluster_parameter_group` | bool | `false` | Create a module-managed cluster parameter group. |
| `cluster_parameter_group_name` | string | `null` | Name for the created/attached cluster parameter group. |
| `cluster_parameter_group_family` | string | `null` | Family (required when creating). |
| `cluster_parameter_group_description` | string | `null` | Description for the created group. |
| `cluster_parameter_group_parameters` | list(object) | `[]` | `{ name, value, apply_method }` entries. |
| `dns` | object | `null` | `{ writer_name, reader_name, ttl }` for Route53 records. |

### Enforced security baseline

To guarantee a compliant, secure-by-default posture, the following are applied to **every** cluster and cannot be weakened per cluster:

- Storage is always encrypted at rest.
- Performance Insights and automatic minor version upgrades are always on.
- Tags are always copied to snapshots.

These are configured module-wide (not per cluster) so a caller cannot silently disable them:

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `backup_retention_period` | number | `7` | Days to retain automated backups for every cluster (minimum 1). |
| `iam_database_authentication_enabled` | bool | `true` | Enable IAM database authentication for every cluster. |
| `deletion_protection` | bool | `true` | Enable deletion protection for every cluster. Set `false` only for disposable/test clusters. |
| `monitoring_interval` | number | `60` | Enhanced Monitoring interval (seconds) for every instance; `0` disables. A monitoring IAM role is created automatically when enabled. |
| `monitoring_role_arn` | string | `null` | Bring your own Enhanced Monitoring role instead of the module-created one. |
| `create_backup_plan` | bool | `true` | Create an AWS Backup vault, plan and selection covering every managed cluster. |
| `backup_schedule` | string | `"cron(0 5 ? * * *)"` | Schedule for the AWS Backup plan rule. |
| `backup_delete_after_days` | number | `35` | Days after which AWS Backup recovery points are deleted. |
| `backup_vault_kms_key_arn` | string | `null` | KMS key ARN for the AWS Backup vault. |

Other module-level inputs include `project_name`, `environment`, `vpc_id`, `subnet_ids` (or `db_subnet_group_name`), `security_group_ids`, `vpc_security_group_ids`, `allowed_cidr_blocks`, `dns_zone`, `dns_ttl`, and the mandatory Core Cloud `tags` object. The master user password is always managed by Aurora in Secrets Manager and is not configurable.

## Required IAM permissions

The secure-by-default posture means the principal that runs `terraform apply` needs more than basic RDS permissions. In particular, the defaults pull in Secrets Manager, AWS Backup and IAM. A deploy role scoped only to `rds:*` will fail partway through an apply. The permissions below reflect what the module actually creates with default settings; scope the resource ARNs to your account and region where the action supports it.

| Feature (default) | Permissions the deploy role needs |
|---|---|
| RDS cluster + instances, subnet group, parameter group | `rds:CreateDBCluster`, `rds:CreateDBInstance`, `rds:CreateDBSubnetGroup`, `rds:CreateDBClusterParameterGroup`, the matching `Delete`/`Modify`/`Describe`/tag actions, plus `rds:DescribeDBEngineVersions`, `rds:DescribeOrderableDBInstanceOptions` and `rds:DescribeGlobalClusters` (the provider reads global clusters while creating a cluster) |
| Security group | `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroup{Ingress,Egress}`, `ec2:RevokeSecurityGroup{Ingress,Egress}`, `ec2:DeleteSecurityGroup`, `ec2:CreateTags`, and the `ec2:Describe*` reads for VPCs, subnets, security groups and AZs |
| Managed master password (always enabled) | `secretsmanager:CreateSecret`, `DeleteSecret`, `DescribeSecret`, `GetSecretValue`, `TagResource` on `rds!*` secrets. Without `CreateSecret` the cluster create fails with "not authorized to create a secret in AWS Secrets Manager" |
| Storage / Performance Insights encryption | `kms:CreateKey`/`CreateAlias`/`DescribeKey`, plus `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey`, `kms:CreateGrant`, `kms:RetireGrant` on the keys used |
| Enhanced Monitoring role + AWS Backup role (`monitoring_interval > 0`, `create_backup_plan = true`) | `iam:CreateRole`, `iam:PassRole`, `iam:AttachRolePolicy`, `iam:GetRole`, and the matching `Delete`/`Detach`/`List`/tag actions for the module-created `*-aurora-monitoring` and `*-aurora-backup` roles |
| AWS Backup vault, plan, selection (`create_backup_plan = true`) | `backup:CreateBackupVault`/`BackupPlan`/`BackupSelection` (+ `Delete`/`Get`/`Update`/tag), `backup-storage:MountCapsule` (required to create a vault), and the KMS permissions above for the vault key |

If a feature is disabled (for example `create_backup_plan = false` or `monitoring_interval = 0`), the matching permissions are not required. The `module-testing/aurora-state-bootstrap` root module in [core-cloud-common-tf-module-testing](https://github.com/Home-Office-Digital/core-cloud-common-tf-module-testing) contains a working, least-privilege IAM policy for the full default feature set that can be used as a reference.

## Examples

### Aurora MySQL (provisioned, HA default of 2)

```hcl
module "aurora_mysql" {
  source = "git::https://github.com/Home-Office-Digital/core-cloud-aurora-tf-module.git"

  project_name        = "payments"
  environment         = "prod"
  vpc_id              = "vpc-0123456789abcdef0"
  subnet_ids          = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
  allowed_cidr_blocks = ["10.0.0.0/8"]

  clusters = {
    orders = {
      name           = "payments-orders"
      database_name  = "orders"
      engine         = "aurora-mysql"
      engine_version = "8.0.mysql_aurora.3.05.2"
      instance_class = "db.r6g.large"
      # instance_count defaults to 2 (one writer + one reader)
    }
  }

  tags = local.mandatory_tags
}
```

### Aurora PostgreSQL

```hcl
module "aurora_postgresql" {
  source = "git::https://github.com/Home-Office-Digital/core-cloud-aurora-tf-module.git"

  project_name        = "analytics"
  environment         = "prod"
  vpc_id              = "vpc-0123456789abcdef0"
  subnet_ids          = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
  allowed_cidr_blocks = ["10.0.0.0/8"]

  clusters = {
    warehouse = {
      name           = "analytics-warehouse"
      database_name  = "warehouse"
      engine         = "aurora-postgresql"
      engine_version = "15.10"
      instance_class = "db.r6g.xlarge"
      instance_count = 3
    }
  }

  tags = local.mandatory_tags
}
```

### Aurora Serverless v2

Serverless v2 uses `engine_mode = "provisioned"` (the default) with `instance_class = "db.serverless"` and a `serverlessv2_scaling` block.

```hcl
module "aurora_serverless" {
  source = "git::https://github.com/Home-Office-Digital/core-cloud-aurora-tf-module.git"

  project_name        = "sandbox"
  environment         = "dev"
  vpc_id              = "vpc-0123456789abcdef0"
  subnet_ids          = ["subnet-aaa", "subnet-bbb"]
  allowed_cidr_blocks = ["10.0.0.0/8"]

  clusters = {
    api = {
      name           = "sandbox-api"
      database_name  = "api"
      engine         = "aurora-postgresql"
      engine_version = "15.10"
      instance_class = "db.serverless"
      instance_count = 1
      serverlessv2_scaling = {
        min_capacity             = 0 # scale-to-zero
        max_capacity             = 4
        seconds_until_auto_pause = 3600
      }
    }
  }

  tags = local.mandatory_tags
}
```

## Outputs

| Name | Description |
|------|-------------|
| `cluster_ids` | Map of Aurora cluster identifiers keyed by cluster key. |
| `cluster_arns` | Map of Aurora cluster ARNs keyed by cluster key. |
| `writer_endpoints` | Map of writer (primary) endpoints. Use for read/write connections. |
| `reader_endpoints` | Map of reader endpoints. Use for load-balanced read-only connections. |
| `cluster_ports` | Map of the resolved listener port for each cluster. |
| `cluster_instance_ids` | Map of cluster instance identifiers keyed by `"<cluster>-<index>"`. |
| `master_user_secret_arns` | Map of Secrets Manager secret ARNs for the managed master password (sensitive). |
| `security_group_ids` | Map of module-created security group IDs. |

### Writer vs reader endpoints

Aurora exposes two cluster-level endpoints:

- **Writer endpoint** (`writer_endpoints`) always points to the current primary instance and accepts reads and writes. Failovers are handled transparently by Aurora, so applications should connect here for anything that writes.
- **Reader endpoint** (`reader_endpoints`) load-balances read-only connections across the Aurora Replicas in the cluster. Direct read-only traffic here to offload the writer. With a single instance the reader endpoint resolves to the primary; it becomes useful once the cluster has one or more replicas (the default `instance_count` of 2 provides one).

## Testing

Tests use Terraform's native test framework with a mocked AWS provider, so no real AWS calls are made:

```bash
terraform init -backend=false
terraform test
```
