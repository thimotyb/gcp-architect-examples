# Orders API (FastAPI) behind ESPv2 on Cloud Run, as in
# https://docs.cloud.google.com/endpoints/docs/openapi/set-up-cloud-run-espv2
#
#   client --(API key)--> ESPv2 gateway (public Cloud Run) --(ID token)--> FastAPI backend (private Cloud Run)
#                               |
#                               +--> Service Control: key check, quota, logs and metrics

locals {
  backend      = "${var.prefix}-backend"
  gateway      = "${var.prefix}-gw"
  service_name = "${local.gateway}.endpoints.${var.project_id}.cloud.goog"
  registry     = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  app_dir      = "${path.module}/../app"
  app_hash     = sha1(join("", [for f in sort(fileset(local.app_dir, "**")) : filesha1("${local.app_dir}/${f}")]))
}

# ---------------------------------------------------------------- APIs and registry

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com", "cloudbuild.googleapis.com", "artifactregistry.googleapis.com",
    "servicemanagement.googleapis.com", "servicecontrol.googleapis.com", "endpoints.googleapis.com",
    "apikeys.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "images" {
  repository_id = var.prefix
  location      = var.region
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

resource "google_service_account" "backend" {
  account_id   = local.backend
  display_name = "Orders API backend"
}

resource "google_service_account" "gateway" {
  account_id   = local.gateway
  display_name = "Orders API ESPv2 gateway"
}

# ---------------------------------------------------------------- 1. Backend (private)

# Cloud Build builds the FastAPI image; the tag is the hash of the source, so a change rebuilds it.
resource "terraform_data" "backend_image" {
  triggers_replace = [local.app_hash]
  input            = "${local.registry}/orders-backend:${local.app_hash}"
  provisioner "local-exec" {
    command = "gcloud builds submit '${local.app_dir}' --project='${var.project_id}' --region='${var.region}' --tag='${self.input}' --quiet"
  }
}

resource "google_cloud_run_v2_service" "backend" {
  name                = local.backend
  location            = var.region
  deletion_protection = false
  template {
    service_account = google_service_account.backend.email
    scaling {
      max_instance_count = 1 # orders live in memory: one instance keeps them consistent
    }
    containers {
      image = terraform_data.backend_image.output
    }
  }
}

# No allUsers binding: only the gateway may invoke the backend.
resource "google_cloud_run_v2_service_iam_member" "gateway_invokes_backend" {
  name     = google_cloud_run_v2_service.backend.name
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.gateway.member
}

# ---------------------------------------------------------------- 2. Endpoints service

resource "google_endpoints_service" "orders" {
  service_name = local.service_name
  openapi_config = templatefile("${path.module}/../openapi/openapi.yaml.tmpl", {
    HOST        = local.service_name
    BACKEND_URL = google_cloud_run_v2_service.backend.uri
  })
  depends_on = [google_project_service.apis]
}

# Enabling the API in the project lets its API keys call it.
resource "google_project_service" "orders_api" {
  service            = google_endpoints_service.orders.service_name
  disable_on_destroy = false
}

# ---------------------------------------------------------------- 3. ESPv2 image with the configuration baked in

# The official script downloads the service configuration and builds it into the ESPv2 image.
# Pinning the version (-v) makes the image name predictable.
resource "terraform_data" "esp_image" {
  triggers_replace = [google_endpoints_service.orders.config_id, var.esp_version]
  input            = "${local.registry}/endpoints-runtime-serverless:${var.esp_version}-${local.service_name}-${google_endpoints_service.orders.config_id}"
  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      script=$(mktemp)
      curl -sSfL -o "$script" https://raw.githubusercontent.com/GoogleCloudPlatform/esp-v2/master/docker/serverless/gcloud_build_image
      bash "$script" -s '${local.service_name}' -c '${google_endpoints_service.orders.config_id}' \
        -p '${var.project_id}' -v '${var.esp_version}' -g '${local.registry}'
      rm -f "$script"
    EOT
    interpreter = ["bash", "-c"]
  }
}

# ---------------------------------------------------------------- 4. Gateway (public)

resource "google_project_iam_member" "gateway_service_controller" {
  project = var.project_id
  role    = "roles/servicemanagement.serviceController"
  member  = google_service_account.gateway.member
}

resource "google_cloud_run_v2_service" "gateway" {
  name                = local.gateway
  location            = var.region
  deletion_protection = false
  template {
    service_account = google_service_account.gateway.email
    containers {
      image = terraform_data.esp_image.output
    }
  }
  depends_on = [google_project_iam_member.gateway_service_controller]
}

resource "google_cloud_run_v2_service_iam_member" "public_gateway" {
  name     = google_cloud_run_v2_service.gateway.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ---------------------------------------------------------------- 5. API key

resource "google_apikeys_key" "client" {
  name         = "${var.prefix}-key"
  display_name = "${var.prefix}-key"
  restrictions {
    api_targets {
      service = google_project_service.orders_api.service
    }
  }
}
