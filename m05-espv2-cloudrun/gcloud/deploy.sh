#!/usr/bin/env bash
# Orders API (FastAPI) behind ESPv2 on Cloud Run, with gcloud only.
# Follows "Set up Endpoints OpenAPI for Cloud Run with ESPv2":
# https://docs.cloud.google.com/endpoints/docs/openapi/set-up-cloud-run-espv2
#
#   PROJECT_ID=my-project ./deploy.sh        (REGION and PREFIX are optional)
#
# Uses the gcloud account that is already logged in; nothing is written to the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
PREFIX="${PREFIX:-orders-cli}"           # prefix of every resource; change it to deploy a second copy
ESP_VERSION="${ESP_VERSION:-2.57.2}"  # ESPv2 release used as base image
BACKEND="$PREFIX-backend"
GATEWAY="$PREFIX-gw"
REPO="$PREFIX"
AR="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO"
gc() { gcloud --project="$PROJECT_ID" --quiet "$@"; }

echo "== 0. APIs, Artifact Registry and service accounts"
gc services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  servicemanagement.googleapis.com servicecontrol.googleapis.com endpoints.googleapis.com \
  apikeys.googleapis.com
gc artifacts repositories describe "$REPO" --location="$REGION" >/dev/null 2>&1 ||
  gc artifacts repositories create "$REPO" --location="$REGION" --repository-format=docker
for sa in "$BACKEND" "$GATEWAY"; do
  gc iam service-accounts describe "$sa@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1 ||
    gc iam service-accounts create "$sa"
done
BACKEND_SA="$BACKEND@$PROJECT_ID.iam.gserviceaccount.com"
GATEWAY_SA="$GATEWAY@$PROJECT_ID.iam.gserviceaccount.com"

echo "== 1. Backend: build the FastAPI image and deploy it as a PRIVATE Cloud Run service"
gc builds submit app --tag="$AR/orders-backend:latest" --region="$REGION"
# max-instances=1: the demo keeps orders in memory, one instance keeps them consistent.
gc run deploy "$BACKEND" --image="$AR/orders-backend:latest" --region="$REGION" \
  --service-account="$BACKEND_SA" --no-allow-unauthenticated --max-instances=1
BACKEND_URL=$(gc run services describe "$BACKEND" --region="$REGION" --format='value(status.url)')

# The tutorial reserves the run.app hostname and uses it as the service name; Service
# Management now refuses that name ("Ownership ... cannot be verified"), so the service
# uses the name Google always lets a project own: NAME.endpoints.PROJECT_ID.cloud.goog.
HOST="$GATEWAY.endpoints.$PROJECT_ID.cloud.goog"

echo "== 2. Deploy the OpenAPI document as the Endpoints service $HOST"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
HOST="$HOST" BACKEND_URL="$BACKEND_URL" envsubst '${HOST} ${BACKEND_URL}' \
  < openapi/openapi.yaml.tmpl > "$tmp/openapi.yaml"
gc endpoints services deploy "$tmp/openapi.yaml"
CONFIG_ID=$(gc endpoints configs list --service="$HOST" --sort-by=~id --limit=1 --format='value(id)')
gc services enable "$HOST"

echo "== 3. Build the ESPv2 image with configuration $CONFIG_ID baked in"
curl -sSfL -o "$tmp/gcloud_build_image" \
  https://raw.githubusercontent.com/GoogleCloudPlatform/esp-v2/master/docker/serverless/gcloud_build_image
chmod +x "$tmp/gcloud_build_image"
"$tmp/gcloud_build_image" -s "$HOST" -c "$CONFIG_ID" -p "$PROJECT_ID" -v "$ESP_VERSION" -g "$AR"
ESP_IMAGE="$AR/endpoints-runtime-serverless:$ESP_VERSION-$HOST-$CONFIG_ID"

echo "== 4. Deploy ESPv2 as the public gateway"
gc projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$GATEWAY_SA" \
  --role=roles/servicemanagement.serviceController --condition=None >/dev/null
gc run deploy "$GATEWAY" --image="$ESP_IMAGE" --region="$REGION" \
  --service-account="$GATEWAY_SA" --allow-unauthenticated
GATEWAY_URL=$(gc run services describe "$GATEWAY" --region="$REGION" --format='value(status.url)')

echo "== 5. Only the gateway may call the backend"
gc run services add-iam-policy-binding "$BACKEND" --region="$REGION" \
  --member="serviceAccount:$GATEWAY_SA" --role=roles/run.invoker >/dev/null

echo "== 6. API key restricted to this API"
KEY_NAME=$(gc services api-keys list --filter="displayName=$PREFIX-key" --format='value(name)' | head -1)
if [[ -z "$KEY_NAME" ]]; then
  gc services api-keys create --display-name="$PREFIX-key" --api-target=service="$HOST" >/dev/null
  KEY_NAME=$(gc services api-keys list --filter="displayName=$PREFIX-key" --format='value(name)' | head -1)
fi

cat <<EOF

Deployed. Run the tests with (the key is read from gcloud, not stored):

  export GATEWAY_URL=$GATEWAY_URL
  export BACKEND_URL=$BACKEND_URL
  export API_KEY=\$(gcloud services api-keys get-key-string $KEY_NAME --format='value(keyString)')
  ./test.sh
EOF
