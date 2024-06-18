resource "google_project_service" "compute_engine" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "vpc_network" {
  name                    = "${var.project_id}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute_engine]
}

# Cloud Router
resource "google_compute_router" "router" {
  name    = "${var.project_id}-router"
  region  = var.region
  network = google_compute_network.vpc_network.name
}

# Cloud NAT
resource "google_compute_router_nat" "nat" {
  name                               = "${var.project_id}-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Subnetwork for GKE (with secondary IP ranges for pods and services)
resource "google_compute_subnetwork" "gke_subnetwork" {
  name          = "${var.project_id}-gke-subnet"
  ip_cidr_range = var.gke_subnetwork_cidr_range
  region        = var.region
  network       = google_compute_network.vpc_network.name

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr_range
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr_range
  }
}

resource "google_compute_global_address" "private_ip_address" {
  name          = "${var.project_id}-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc_network.id
}


resource "google_project_service" "servicenetworking_api" {
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
  depends_on              = [google_project_service.servicenetworking_api]
}

resource "google_sql_database_instance" "postgres_instance" {
  name                = "${var.project_id}-pg"
  database_version    = "POSTGRES_14"
  region              = var.region
  deletion_protection = false


  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier = var.postgres_tier
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc_network.id
      enable_private_path_for_google_cloud_services = true

    }
  }
}

output "postgres_host" {
  value = google_sql_database_instance.postgres_instance.private_ip_address
}


resource "google_project_service" "redis_googleapis_com_api" {
  service            = "redis.googleapis.com"
  disable_on_destroy = false
}


# Cloud Memorystore Redis
resource "google_redis_instance" "redis_instance" {
  name               = "${var.project_id}-redis"
  tier               = var.redis_tier
  memory_size_gb     = var.redis_memory_size
  region             = var.region
  authorized_network = google_compute_network.vpc_network.id
  depends_on         = [google_project_service.redis_googleapis_com_api]
}

output "redis_host" {
  value = google_redis_instance.redis_instance.host
}
output "redis_port" {
  value = google_redis_instance.redis_instance.port
}

resource "google_project_service" "container_googleapis_com" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager_googleapis_com" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# GKE Cluster (with private nodes and ingress enabled)
resource "google_container_cluster" "gke_cluster" {
  provider            = google-beta
  name                = "${var.project_id}-gke"
  location            = var.region
  deletion_protection = false

  depends_on = [google_service_networking_connection.private_vpc_connection]

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_cidr_blocks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
    gcp_public_cidrs_access_enabled = true
  }

  # Private Cluster Configuration
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # https://cloud.google.com/secret-manager/docs/secret-manager-managed-csi-component
  secret_manager_config {
    enabled = true
  }

  # Workload Identity allows Kubernetes service accounts to act as a user-managed Google IAM Service Account.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # IP Allocation Policy (for private IPs)
  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.gke_subnetwork.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.gke_subnetwork.secondary_ip_range[1].range_name
  }

  # Ingress Configuration
  addons_config {
    http_load_balancing {
      disabled = true
    }
    istio_config {
      disabled = false
    }

  }


  remove_default_node_pool = true
  initial_node_count       = 1

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  protect_config {
    workload_vulnerability_mode = "BASIC"
  }

  # https://cloud.google.com/binary-authorization/docs/getting-started-cli#view_the_default_policy
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  network    = google_compute_network.vpc_network.id
  subnetwork = google_compute_subnetwork.gke_subnetwork.name
}

data "google_project" "current" {}

resource "google_project_iam_member" "my_secret_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/default/sa/default"
}

resource "google_container_node_pool" "primary_nodes" {
  name     = "${var.project_id}-gke-primary"
  location = var.region
  cluster  = google_container_cluster.gke_cluster.name

  depends_on = [google_container_cluster.gke_cluster]

  autoscaling {
    min_node_count = 1
    max_node_count = 10
  }

  node_config {
    machine_type = "e2-medium"
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "docker_repo" {
  location      = var.region
  repository_id = "regentmarkets"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifactregistry]
}

#Enable builds
resource "google_project_service" "cloudbuild_googleapi_com" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_artifact_registry_repository.docker_repo]
}

# Enabe Vulnerability scanning
resource "google_project_service" "container_scanning_api" {
  service            = "containerscanning.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_artifact_registry_repository.docker_repo]
}

# Enabe Cloud Deploy
resource "google_project_service" "clouddeploy_googleapis_com" {
  service = "clouddeploy.googleapis.com"
}

# Enabe Binary Authorization API
resource "google_project_service" "binaryauthorization_googleapis_com" {
  service = "binaryauthorization.googleapis.com"
}

