terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
}

# Credentials come from the environment (gcloud auth application-default login);
# nothing is stored in this folder.
provider "google" {
  project = var.project_id
  region  = var.region
  # The API Keys API needs a quota project when you authenticate as a user (ADC):
  # bill API calls to this project instead of the gcloud default client.
  billing_project       = var.project_id
  user_project_override = true
}
