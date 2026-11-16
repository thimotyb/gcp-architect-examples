#!/usr/bin/env bash
# Remove what gcloud/deploy.sh created. Same PROJECT_ID, REGION and PREFIX as the deploy.
# Note: a deleted Endpoints service stays reserved for 30 days (it can be undeleted):
# deploy again with another PREFIX, or run  gcloud endpoints services undelete HOST.
set -uo pipefail
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
PREFIX="${PREFIX:-orders-cli}"
gc() { gcloud --project="$PROJECT_ID" --quiet "$@"; }

for key in $(gc services api-keys list --filter="displayName=$PREFIX-key" --format='value(name)'); do
  # A key used in the last 7 days is protected: skip that check, the API is being removed too.
  gc services api-keys delete "$key" --no-check-existing-usage
done
gc endpoints services delete "$PREFIX-gw.endpoints.$PROJECT_ID.cloud.goog"
gc run services delete "$PREFIX-gw" --region="$REGION"
gc run services delete "$PREFIX-backend" --region="$REGION"
gc projects remove-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$PREFIX-gw@$PROJECT_ID.iam.gserviceaccount.com" \
  --role=roles/servicemanagement.serviceController --condition=None >/dev/null
gc iam service-accounts delete "$PREFIX-gw@$PROJECT_ID.iam.gserviceaccount.com"
gc iam service-accounts delete "$PREFIX-backend@$PROJECT_ID.iam.gserviceaccount.com"
gc artifacts repositories delete "$PREFIX" --location="$REGION"
