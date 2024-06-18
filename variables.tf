variable "project_id" {
  description = "The GCP project ID"
  type        = string
  default     = "test"
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "us-east1"
}






variable "postgres_tier" {
  type        = string
  description = "The tier (machine type) for the PostgreSQL instance (e.g., 'db-f1-micro')"
  default     = "db-f1-micro"
}

variable "redis_tier" {
  type        = string
  description = "The tier (machine type) for the Redis instance (e.g., 'BASIC_M1')"
  default     = "BASIC"
}

variable "redis_memory_size" {
  type        = number
  description = "The memory size in GB for the Redis instance"
  default     = 1
}


variable "master_ipv4_cidr_block" {
  type        = string
  description = "The IP range in CIDR notation to use for the GKE master"
  default     = "172.16.0.0/28"
}


variable "gke_subnetwork_cidr_range" {
  type        = string
  description = "The primary IP range for the GKE subnetwork in CIDR notation"
  default     = "10.1.0.0/16"
}

variable "pods_cidr_range" {
  type        = string
  description = "The secondary IP range for pods in CIDR notation"
  default     = "10.2.0.0/16"
}

variable "services_cidr_range" {
  type        = string
  description = "The secondary IP range for services in CIDR notation"
  default     = "10.3.0.0/16"
}


variable "authorized_cidr_blocks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    { cidr_block = "1.1.1.1/32", display_name = "nordlayer-eu" }
  ]
}

