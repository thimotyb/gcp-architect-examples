# M05 · Cloud Endpoints with ESPv2 on Cloud Run

A FastAPI **Orders API** on a private Cloud Run service, published through an **ESPv2** gateway on a public Cloud Run service. The same architecture is built twice: with **gcloud** commands (`gcloud/`) and with **Terraform** (`terraform/`). It follows the Google tutorial [Set up Endpoints OpenAPI for Cloud Run with ESPv2](https://docs.cloud.google.com/endpoints/docs/openapi/set-up-cloud-run-espv2).

```
client --(?key=API_KEY)--> ESPv2 gateway        --(ID token)--> FastAPI backend
                           Cloud Run, public                    Cloud Run, private
                              |
                              +--> Service Control: API key, quota, logs, metrics
```

| Folder | Content |
| --- | --- |
| `app/` | Orders API from module M02 of the companion course *Designing APIs* ([demo-api-design](https://github.com/thimotyb/demo-api-design/tree/main/moduli/m02/orders_api)), plus a `Dockerfile` |
| `openapi/openapi.yaml.tmpl` | OpenAPI 2.0 contract: backend address, API key on every path except `/`, and a quota of 10 writes per minute per consumer project |
| `gcloud/deploy.sh`, `gcloud/destroy.sh` | The tutorial's steps as gcloud commands |
| `terraform/` | The same resources as Terraform code |
| `test.sh` | End-to-end test used by both variants |

## What the example shows

- **Private backend**: the FastAPI service has no public invoker. A direct call returns 403. Only the gateway's service account has `roles/run.invoker`, and ESPv2 adds an ID token to each call.
- **The contract is the gateway**: ESPv2 forwards only the paths and methods in the OpenAPI document. `/docs`, for example, returns 404 at the gateway.
- **API key**: a call without a key returns 401, and a call with a wrong key returns 400. The key is restricted to this API only.
- **Quota**: `x-google-management` and `x-google-quota` limit the write calls (POST, PUT, PATCH, DELETE) to 10 per minute. When the limit is exceeded, ESPv2 returns 429.
- **Observability**: each call is visible on the Endpoints page of the console (requests, errors, latency per method and per consumer).

## Prerequisites

- A Google Cloud project with billing enabled, and the Owner role (or equivalent roles).
- `gcloud` logged in: `gcloud auth login`. For Terraform, also run `gcloud auth application-default login`.
- `bash`, `curl`, `envsubst` (package `gettext`) and Terraform 1.5 or later.

No credentials are stored in this repository. The scripts use the logged-in gcloud account. The API key is read when it is needed and is never written to disk. The Terraform state contains the key, and `.gitignore` excludes it.

## Variant 1: gcloud

```bash
cd m05-espv2-cloudrun
PROJECT_ID=my-project ./gcloud/deploy.sh      # about 5 minutes
# copy the three export lines printed at the end, then:
./test.sh
PROJECT_ID=my-project ./gcloud/destroy.sh
```

## Variant 2: Terraform

```bash
cd m05-espv2-cloudrun/terraform
terraform init
terraform apply -var project_id=my-project    # or copy terraform.tfvars.example to terraform.tfvars
cd ..
export GATEWAY_URL=$(terraform -chdir=terraform output -raw gateway_url)
export BACKEND_URL=$(terraform -chdir=terraform output -raw backend_url)
export API_KEY=$(terraform -chdir=terraform output -raw api_key)
./test.sh
terraform -chdir=terraform destroy -var project_id=my-project
```

The two images are built by Cloud Build from `terraform_data` resources with `local-exec`:
- the backend image is tagged with a hash of `app/`, so a code change rebuilds it;
- the ESPv2 image is rebuilt when the Endpoints configuration ID changes.

## Deploying again: change the prefix

Each resource name starts with a prefix: `orders-cli` for gcloud and `orders-tf` for Terraform. The Endpoints service is named `PREFIX-gw.endpoints.PROJECT_ID.cloud.goog`.

**Why the prefix must change.** When you delete an Endpoints service, with `destroy.sh` or `terraform destroy`, Service Management does not free its name right away:
- the service is *soft-deleted* and stays reserved for **30 days**, so it can be restored with `gcloud endpoints services undelete`;
- during that time, a deployment with the same name fails;
- the other resources (Cloud Run, Artifact Registry, service accounts, API key) are not reserved and can be re-created at once.

To deploy again within 30 days, choose a new prefix:

```bash
# gcloud
PROJECT_ID=my-project PREFIX=orders-demo ./gcloud/deploy.sh
PROJECT_ID=my-project PREFIX=orders-demo ./gcloud/destroy.sh     # same prefix to remove it

# Terraform
terraform -chdir=terraform apply   -var project_id=my-project -var prefix=orders-demo
terraform -chdir=terraform destroy -var project_id=my-project -var prefix=orders-demo
```

- Use a different prefix for each variant if both run in the same project, for example `orders-demo-cli` and `orders-demo-tf`.
- Keep the prefix short: it becomes part of service-account IDs, which are limited to 30 characters (the longest is `PREFIX-backend`, so the prefix can have at most 22 characters).
- **Do not** undelete the old service to reuse its name with Terraform: Terraform would find an existing service it did not create, and the apply would fail.
- **For a live demo**, deploy at least 5 minutes in advance. A new API key returns 403 for a minute or two. For the first few minutes Service Control does not enforce the quota yet, so no 429 is returned.

## Differences from the tutorial (checked on 2026-11-16)

- **Service name**: the tutorial reserves the gateway's `run.app` hostname and uses it as the Endpoints service name. Service Management now refuses that name with *"Ownership for domain name ... cannot be verified"*. The example uses `PREFIX-gw.endpoints.PROJECT_ID.cloud.goog` instead, a name that every project owns. As a side effect, the placeholder deployment is no longer needed.
- **Registry**: `gcloud_build_image` pushes to `gcr.io` by default. The example passes `-g` to use Artifact Registry, and `-v` to pin the ESPv2 version (2.57.2), so the image name is known in advance.
- **API key with Terraform**: when Terraform authenticates as a user (ADC), the API Keys API needs a quota project. The provider sets `billing_project` and `user_project_override`.

## Things to know

- **Propagation**: right after deployment, a new API key returns 403 for a minute or two (`test.sh` waits for it). Service Control can also return *"Failed to load service"* for the first few minutes. During that time ESPv2 fails open on the quota check, so no 429 is returned.
- **The quota is not exact**: quota is checked in aggregate and enforced with some delay, so 10 to 20 writes pass before the first 429.
- **In-memory data**: the orders live in the process memory. The backend runs with at most one instance, and the data resets when the instance restarts.
- **Deleting a service**: a deleted Endpoints service name stays reserved for 30 days. See [Deploying again: change the prefix](#deploying-again-change-the-prefix).
- **Cost**: Cloud Run scales to zero. The ongoing cost is a few cents for the images in Artifact Registry.
