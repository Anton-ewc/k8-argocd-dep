#!/bin/bash
set -e

# -------- PROJECT DISCOVERY / CREATION --------
# Inputs (set by caller, e.g. Argo Workflow or local Docker run):
#   BILLING_ACCOUNT_ID  - required to create new projects
#   ORG_ID / FOLDER_ID  - optional, where to place projects
#   PROJECT_PREFIX      - e.g. "app-"
#   PROJECT_ID          - if you want to use an existing project

export PROJECT_PREFIX="${PROJECT_PREFIX:-app-}"

if [ -n "$PROJECT_ID" ]; then
  echo "Using existing project: $PROJECT_ID"
else
  echo "No PROJECT_ID provided, creating a new project..."

  RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
  PROJECT_ID="${PROJECT_PREFIX}${RANDOM_SUFFIX}"

  if [ -n "$FOLDER_ID" ]; then
    gcloud projects create "$PROJECT_ID" \
      --name="$PROJECT_ID" \
      --folder="$FOLDER_ID"
  elif [ -n "$ORG_ID" ]; then
    gcloud projects create "$PROJECT_ID" \
      --name="$PROJECT_ID" \
      --organization="$ORG_ID"
  else
    gcloud projects create "$PROJECT_ID" \
      --name="$PROJECT_ID"
  fi

  gcloud beta billing projects link "$PROJECT_ID" \
    --billing-account="$BILLING_ACCOUNT_ID"
fi

export PROJECT_ID
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
export CLUSTER_NAME="${CLUSTER_NAME:-argo-cluster}"
export REGION="${REGION:-us-central1}"

echo "Running Automation for Project: $PROJECT_ID"

# 2. Enable APIs
gcloud services enable container.googleapis.com \
    artifactregistry.googleapis.com \
    iam.googleapis.com

# 3. Setup Artifact Registry (All projects use this format)
gcloud artifacts repositories create argocd-repo \
    --repository-format=docker --location=$REGION || true

# 4. Setup GKE Workload Identity (The bridge between K8s and GCP)
gcloud iam service-accounts create kaniko-builder --display-name="Kaniko Builder" || true

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:kaniko-builder@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/storage.admin"

# Allow K8s to act as this GCP Service Account
gcloud iam service-accounts add-iam-policy-binding \
    kaniko-builder@$PROJECT_ID.iam.gserviceaccount.com \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:$PROJECT_ID.svc.id.goog[argo/argo-workflow]"

# Annotate the K8s Service Account for Workload Identity
kubectl annotate serviceaccount argo-workflow \
    -n argo \
    iam.gke.io/gcp-service-account=kaniko-builder@$PROJECT_ID.iam.gserviceaccount.com --overwrite

# 6. Create a reusable ClusterWorkflowTemplate for building container images with Kaniko
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ClusterWorkflowTemplate
metadata:
  name: build-docker-image
spec:
  entrypoint: build
  arguments:
    parameters:
      - name: repoUrl
        description: "Git repo URL containing the Dockerfile and app code"
      - name: revision
        description: "Git revision to build from"
        default: "HEAD"
      - name: context
        description: "Build context path inside the repo"
        default: "."
      - name: dockerfile
        description: "Dockerfile path inside the context"
        default: "Dockerfile"
      - name: appName
        description: "Name of the application (used in image tag)"
      - name: tag
        description: "Tag of the application (used in image tag)"
        default: "latest"
      - name: projectId
        description: "Project ID to use for the image"
        default: "$PROJECT_ID"
  templates:
    - name: build
      container:
        image: gcr.io/kaniko-project/executor:latest
        args:
          - "--dockerfile={{workflow.parameters.dockerfile}}"
          - "--context={{workflow.parameters.repoUrl}}#{{workflow.parameters.revision}}"
          - "--context-sub-path={{workflow.parameters.context}}"
          - "--destination=$REGION-docker.pkg.dev/$PROJECT_ID/app-images/{{workflow.parameters.appName}}:latest"
          - "--snapshotMode=redo"
        env:
          # Workload Identity is used; no explicit key file required
          - name: GOOGLE_APPLICATION_CREDENTIALS
            value: ""
EOF

echo "SUCCESS: Project $PROJECT_ID is ready for Argo Workflows + Kaniko + build-docker-image ClusterWorkflowTemplate"