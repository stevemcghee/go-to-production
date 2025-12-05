# variables.tf

variable "project_id" {
  description = "The GCP project ID to deploy to"
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources in"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone to deploy resources in"
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "The name of the GKE cluster"
  type        = string
  default     = "todo-app-cluster"
}

variable "db_instance_name" {
  description = "The name of the Cloud SQL instance"
  type        = string
  default     = "todo-app-db-instance"
}

variable "db_database_name" {
  description = "The name of the database within the Cloud SQL instance"
  type        = string
  default     = "todoapp_db"
}

variable "db_user" {
  description = "The username for the database"
  type        = string
  default     = "todoappuser"
}

variable "db_password" {
  description = "The password for the database user"
  type        = string
  sensitive   = true
}
