output "cluster_ids" {
  description = "A map of Aurora cluster identifiers keyed by cluster key."
  value       = { for k, v in aws_rds_cluster.this : k => v.id }
}

output "cluster_arns" {
  description = "A map of Aurora cluster ARNs keyed by cluster key."
  value       = { for k, v in aws_rds_cluster.this : k => v.arn }
}

output "writer_endpoints" {
  description = "A map of writer (primary) endpoints keyed by cluster key. Use this for read/write connections."
  value       = { for k, v in aws_rds_cluster.this : k => v.endpoint }
}

output "reader_endpoints" {
  description = "A map of reader endpoints keyed by cluster key. Use this for load-balanced read-only connections across replicas."
  value       = { for k, v in aws_rds_cluster.this : k => v.reader_endpoint }
}

output "cluster_ports" {
  description = "A map of the resolved listener port for each cluster keyed by cluster key."
  value       = local.cluster_ports
}

output "cluster_instance_ids" {
  description = "A map of Aurora cluster instance identifiers keyed by \"<cluster>-<index>\"."
  value       = { for k, v in aws_rds_cluster_instance.this : k => v.id }
}

output "master_user_secret_arns" {
  description = "A map of the Secrets Manager secret ARNs for the managed master user password, keyed by cluster key. Null for clusters restored from a snapshot (which reuse the snapshot's credentials)."
  value = {
    for k, v in aws_rds_cluster.this : k => try(v.master_user_secret[0].secret_arn, null)
  }
  sensitive = true
}

output "security_group_ids" {
  description = "A map of module-created security group IDs keyed by cluster key."
  value       = { for k, v in aws_security_group.this : k => v.id }
}
