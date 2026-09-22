locals {
  dns_zone_normalized = var.dns_zone == null ? "" : trimspace(var.dns_zone)

  # Default listener ports by Aurora engine family.
  engine_ports = {
    aurora-mysql      = 3306
    aurora-postgresql = 5432
  }

  # Resolved port per cluster: explicit override, else engine default.
  cluster_ports = {
    for key, cluster in var.clusters : key => coalesce(
      cluster.port,
      lookup(local.engine_ports, cluster.engine, 3306)
    )
  }

  # Flatten cluster instances into a map keyed by "<cluster>-<index>" so we can
  # drive aws_rds_cluster_instance with for_each (never count). instance_count
  # defaults to 2 for HA (one writer, one or more readers).
  cluster_instances = merge([
    for key, cluster in var.clusters : {
      for i in range(cluster.instance_count) :
      "${key}-${i}" => {
        cluster_key    = key
        identifier     = "${cluster.name}-${i}"
        instance_class = cluster.instance_class
        cluster        = cluster
      }
    }
  ]...)

  # DNS record names collected across writer + reader for uniqueness validation.
  dns_record_names = flatten([
    for _, cluster in var.clusters : [
      for candidate in [
        try(trimspace(cluster.dns.writer_name), ""),
        try(trimspace(cluster.dns.reader_name), ""),
      ] : lower(candidate) if candidate != ""
    ]
  ])

  dns_record_names_unique = length(local.dns_record_names) == length(distinct(local.dns_record_names))

  # Writer DNS records to create, keyed by cluster key.
  writer_dns_records = local.dns_zone_normalized != "" ? {
    for key, cluster in var.clusters : key => cluster
    if try(trimspace(cluster.dns.writer_name), "") != ""
  } : {}

  # Reader DNS records to create, keyed by cluster key.
  reader_dns_records = local.dns_zone_normalized != "" ? {
    for key, cluster in var.clusters : key => cluster
    if try(trimspace(cluster.dns.reader_name), "") != ""
  } : {}

  # Per-cluster cluster parameter group definitions for module-managed creation.
  cluster_parameter_groups_to_create = {
    for key, cluster in var.clusters : key => {
      name        = try(trimspace(cluster.cluster_parameter_group_name), "") != "" ? trimspace(cluster.cluster_parameter_group_name) : "${cluster.name}-cluster-parameter-group"
      family      = try(trimspace(cluster.cluster_parameter_group_family), "") != "" ? trimspace(cluster.cluster_parameter_group_family) : null
      description = try(trimspace(cluster.cluster_parameter_group_description), "") != "" ? trimspace(cluster.cluster_parameter_group_description) : "Cluster parameter group for ${cluster.name}"
      parameters  = try(cluster.cluster_parameter_group_parameters, [])
    }
    if try(cluster.create_cluster_parameter_group, false)
  }

  # Final cluster parameter group name each cluster attaches to.
  cluster_parameter_group_name_by_cluster = {
    for key, cluster in var.clusters : key => try(cluster.create_cluster_parameter_group, false) ? aws_rds_cluster_parameter_group.this[key].name : (
      try(trimspace(cluster.cluster_parameter_group_name), "") != "" ? trimspace(cluster.cluster_parameter_group_name) : null
    )
  }
}
