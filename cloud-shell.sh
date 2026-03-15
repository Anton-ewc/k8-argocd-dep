#!/bin/bash
set -euo pipefail

ARGOCD_VERSION=v2.11.4
ARGO_WORKFLOWS_VERSION="${ARGO_WORKFLOWS_VERSION:-v3.5.9}"


echo "=== k8_builder Cloud Shell automated setup ==="
echo

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found in PATH. Run this from Google Cloud Shell."
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH. Run this from Google Cloud Shell."
  exit 1
fi

PLATFORM_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"

# If gcloud config is unset, try Cloud Shell metadata server
if [ -z "${PLATFORM_PROJECT_ID:-}" ] || [ "$PLATFORM_PROJECT_ID" = "(unset)" ]; then
  METADATA_PROJECT_ID="$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id || true)"
  if [ -n "${METADATA_PROJECT_ID:-}" ]; then
    PLATFORM_PROJECT_ID="$METADATA_PROJECT_ID"
  fi
fi

# If still unset, pick the first available project from gcloud (excluding "test")
if [ -z "${PLATFORM_PROJECT_ID:-}" ] || [ "$PLATFORM_PROJECT_ID" = "(unset)" ]; then
  # Prefer a project whose ID and name do NOT contain "test"
  FIRST_PROJECT_ID="$(gcloud projects list --format='value(projectId,name)' 2>/dev/null \
    | grep -vi 'test' \
    | head -n1 \
    | awk '{print $1}' || true)"
  if [ -n "${FIRST_PROJECT_ID:-}" ]; then
    PLATFORM_PROJECT_ID="$FIRST_PROJECT_ID"
  fi
fi

if [ -z "${PLATFORM_PROJECT_ID:-}" ] || [ "$PLATFORM_PROJECT_ID" = "(unset)" ]; then
  echo "Unable to determine platform project ID automatically (no gcloud config, metadata, or projects listed)."
  exit 1
fi

echo "Detected platform project ID: $PLATFORM_PROJECT_ID"
read -rp "Set this as the active gcloud project? [Y/n]: " CONFIRM_PROJECT
CONFIRM_PROJECT="${CONFIRM_PROJECT:-Y}"
if [[ "$CONFIRM_PROJECT" =~ ^[Yy]$ ]]; then
  gcloud config set project "$PLATFORM_PROJECT_ID" >/dev/null
else
  echo "Aborting: platform project not confirmed."
  exit 1
fi

BILLING_ACCOUNT_ID=""

# Try to auto-detect a non-test billing account ID from billing accounts list
RAW_BILLING="$(gcloud beta billing accounts list --format='value(name,displayName)' 2>/dev/null || true)"
if [ -n "$RAW_BILLING" ]; then
  BILLING_ACCOUNT_ID="$(echo "$RAW_BILLING" \
    | grep -vi 'test' \
    | head -n1 \
    | awk '{print $1}' \
    | sed 's#billingAccounts/##' || true)"
fi

# If still empty, try to read billing from the detected platform project
if [ -z "${BILLING_ACCOUNT_ID:-}" ]; then
  PROJECT_BILLING_NAME="$(gcloud billing projects describe "$PLATFORM_PROJECT_ID" --format='value(billingAccountName)' 2>/dev/null || true)"
  if [ -n "$PROJECT_BILLING_NAME" ]; then
    BILLING_ACCOUNT_ID="$(echo "$PROJECT_BILLING_NAME" | sed 's#billingAccounts/##')"
  fi
fi

if [ -z "${BILLING_ACCOUNT_ID:-}" ]; then
  read -rp "No billing account detected. Enter billing account ID (e.g. --): " BILLING_ACCOUNT_ID
fi

if [ -z "${BILLING_ACCOUNT_ID:-}" ]; then
  echo "Billing account ID is required."
  exit 1
fi

echo "Detected billing account ID: $BILLING_ACCOUNT_ID"
read -rp "Use this billing account for auto-created projects? [Y/n]: " CONFIRM_BILLING
CONFIRM_BILLING="${CONFIRM_BILLING:-Y}"
if [[ ! "$CONFIRM_BILLING" =~ ^[Yy]$ ]]; then
  echo "Aborting: billing account not confirmed."
  exit 1
fi

read -rp "Organization ID (optional, press Enter to skip): " ORG_ID
read -rp "Folder ID (optional, press Enter to skip): " FOLDER_ID

# Try to auto-detect a default region from gcloud or existing clusters
AUTO_REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
if [ -z "${AUTO_REGION:-}" ] || [ "$AUTO_REGION" = "(unset)" ]; then
  ZONE_FROM_CONFIG="$(gcloud config get-value compute/zone 2>/dev/null || true)"
  if [ -n "${ZONE_FROM_CONFIG:-}" ] && [ "$ZONE_FROM_CONFIG" != "(unset)" ]; then
    AUTO_REGION="${ZONE_FROM_CONFIG%-*}"
  fi
fi

# Prefer region(s) of existing clusters if config is unset
if [ -z "${AUTO_REGION:-}" ] || [ "$AUTO_REGION" = "(unset)" ]; then
  FIRST_LOCATION="$(gcloud container clusters list --format='value(location)' 2>/dev/null | head -n1 || true)"
  if [ -n "${FIRST_LOCATION:-}" ]; then
    # location can be region or zone; if zone, strip last -letter
    AUTO_REGION="$(echo "$FIRST_LOCATION" | sed 's/-[a-z]$//')"
  fi
fi

# As a last resort, try metadata
if [ -z "${AUTO_REGION:-}" ] || [ "$AUTO_REGION" = "(unset)" ]; then
  ZONE_FROM_METADATA="$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null || true)"
  if [ -n "${ZONE_FROM_METADATA:-}" ]; then
    # zone looks like projects/123456789/zones/us-central1-a
    AUTO_REGION="$(echo "$ZONE_FROM_METADATA" | awk -F/ '{print $NF}' | sed 's/-[a-z]$//')"
  fi
fi

if [ -z "${AUTO_REGION:-}" ] || [ "$AUTO_REGION" = "(unset)" ]; then
  AUTO_REGION="us-central1"
fi

read -rp "Region for cluster and Artifact Registry [$AUTO_REGION]: " INPUT_REGION
REGION="${INPUT_REGION:-$AUTO_REGION}"

# Try to auto-detect an existing cluster name to use as default
AUTO_CLUSTER_NAME="$(gcloud container clusters list --format='value(name)' --region "$REGION" 2>/dev/null | grep -vi 'test' | head -n1 || true)"
if [ -z "${AUTO_CLUSTER_NAME:-}" ]; then
  #AUTO_CLUSTER_NAME="argo-cluster"
  AUTO_CLUSTER_NAME="autopilot-ufo"
fi

read -rp "GKE Autopilot cluster name [$AUTO_CLUSTER_NAME]: " INPUT_CLUSTER_NAME
CLUSTER_NAME="${INPUT_CLUSTER_NAME:-$AUTO_CLUSTER_NAME}"

echo
echo "Using settings:"
echo "  PLATFORM_PROJECT_ID = $PLATFORM_PROJECT_ID"
echo "  BILLING_ACCOUNT_ID  = $BILLING_ACCOUNT_ID"
echo "  ORG_ID              = ${ORG_ID:-<none>}"
echo "  FOLDER_ID           = ${FOLDER_ID:-<none>}"
echo "  REGION              = $REGION"
echo "  CLUSTER_NAME        = $CLUSTER_NAME"
echo

read -rp "Continue with automated setup? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborting."
  exit 0
fi

echo
echo "=== Step 1: Configure gcloud project and enable APIs ==="
gcloud config set project "$PLATFORM_PROJECT_ID"
gcloud services enable container.googleapis.com artifactregistry.googleapis.com

echo
echo "=== Step 2: Create Artifact Registry repo (idempotent) ==="
gcloud artifacts repositories create k8-builder-images \
  --repository-format=docker \
  --location="$REGION" || true

echo
echo "=== Step 3: Build and push k8_builder image ==="
gcloud auth configure-docker "$REGION-docker.pkg.dev"

IMAGE="$REGION-docker.pkg.dev/$PLATFORM_PROJECT_ID/k8-builder-images/k8-builder:latest"

echo
echo "=== Step 3: Build and push k8_builder image (using Cloud Build) ==="
if command -v docker >/dev/null 2>&1; then
  # If docker is available, use it
  docker build -t "$IMAGE" .
  docker push "$IMAGE"
else
  # Default for Cloud Shell: use Cloud Build
  gcloud builds submit --tag "$IMAGE" .
fi

echo
echo "=== Step 4: Create GKE Autopilot cluster (idempotent) ==="
if ! gcloud container clusters describe "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  gcloud container clusters create-auto "$CLUSTER_NAME" \
    --region "$REGION" \
    --workload-pool="$PLATFORM_PROJECT_ID.svc.id.goog"
else
  echo "Cluster $CLUSTER_NAME already exists in region $REGION, skipping create."
fi

gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" \
  --project "$PLATFORM_PROJECT_ID"

echo
echo "=== Step 5: Install / update Argo CD and Argo Workflows ==="

# Argo CD: if CRDs already exist, skip re-applying the full manifest to avoid CRD size errors
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  echo "Argo CD CRDs already present; skipping Argo CD install/upgrade."
else
  kubectl create namespace argocd || true
  echo "Installing Argo CD version $ARGOCD_VERSION..."
  kubectl apply -n argocd -f "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/install.yaml"
fi

# Argo Workflows: skip full install if CRDs already exist
if kubectl get crd workflows.argoproj.io >/dev/null 2>&1; then
  echo "Argo Workflows CRDs already present; skipping Argo Workflows install/upgrade."
else
  kubectl create namespace argo || true
  echo "Installing Argo Workflows version $ARGO_WORKFLOWS_VERSION..."
  kubectl apply -n argo -f "https://github.com/argoproj/argo-workflows/releases/download/$ARGO_WORKFLOWS_VERSION/install.yaml"
fi

echo
echo "=== Step 6: Configure Argo CD image-overloader plugin ==="
PLUGIN_FILE="./argocd-image-overloader-plugin.yaml"
if [ -f "$PLUGIN_FILE" ]; then
  kubectl apply -f "$PLUGIN_FILE"
  kubectl -n argocd set env deployment/argocd-repo-server \
    PROJECT_ID="$PLATFORM_PROJECT_ID" \
    REGION="$REGION" \
    MANIFEST_DIR="."
  kubectl -n argocd rollout restart deployment/argocd-repo-server
  kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=180s
else
  echo "Plugin config file not found at $PLUGIN_FILE. Skipping plugin setup."
fi

echo
echo "=== Step 7: Apply shared WorkflowTemplate (project-bootstrap) ==="
cat <<EOF | kubectl apply -n argo -f -
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: project-bootstrap
  namespace: argo
spec:
  entrypoint: bootstrap
  arguments:
    parameters:
      - name: projectId
        description: "Existing GCP project ID (optional)"
        default: ""
      - name: projectPrefix
        description: "Prefix for auto-created projects"
        default: "app-"
  templates:
    - name: bootstrap
      container:
        image: $IMAGE
        env:
          - name: BILLING_ACCOUNT_ID
            value: "$BILLING_ACCOUNT_ID"
          - name: ORG_ID
            value: "$ORG_ID"
          - name: FOLDER_ID
            value: "$FOLDER_ID"
          - name: REGION
            value: "$REGION"
          - name: PROJECT_ID
            value: "{{workflow.parameters.projectId}}"
          - name: PROJECT_PREFIX
            value: "{{workflow.parameters.projectPrefix}}"
EOF

echo
echo "=== Setup complete ==="
echo "Next steps (high level):"
echo "  1) Create a platform-config Git repo with per-project app/Workflow manifests."
echo "  2) Connect that repo in the Argo CD UI."
echo "  3) For each project folder, create an Application in Argo CD and sync."
echo "When a project syncs, Argo Workflows will run project-bootstrap, which calls k8_builder."