variable "project_id" {
  description = "Google Cloud project that hosts the example."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run and Artifact Registry."
  type        = string
  default     = "europe-west1"
}

variable "prefix" {
  description = "Prefix of every resource name. A deleted Endpoints service stays reserved for 30 days: change the prefix to redeploy sooner."
  type        = string
  default     = "orders-tf"
}

variable "esp_version" {
  description = "ESPv2 release used as the base image (gcr.io/endpoints-release/endpoints-runtime-serverless)."
  type        = string
  default     = "2.57.2"
}
