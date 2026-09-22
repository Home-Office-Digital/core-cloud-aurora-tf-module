All notable changes to this project will be documented in this file. This will provide a record of all notable module updates with each new release. Semantic versioning (https://semver.org/) must be adhered to for all Core Cloud modules.

eg:

### [0.1.0] 2026-09-21

  * Initial tag created for Core Cloud Aurora Terraform module. Supports Aurora MySQL and Aurora PostgreSQL, provisioned and Serverless v2 clusters, writer/reader endpoints, module-managed subnet group, security groups and DNS records.

### [0.2.0] 2026-09-21

  * Aligned with terraform-aws-modules/rds-aurora v10 conventions: bumped AWS provider floor to >= 6.61.0, added cluster-level auto_minor_version_upgrade and allow_major_version_upgrade, added Serverless v2 seconds_until_auto_pause (scale-to-zero) support, and added performance_insights_retention_period on cluster instances.
