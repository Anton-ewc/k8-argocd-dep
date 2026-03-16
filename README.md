### Overview

## Download Install:
```sh
curl -L -o arg.tar.gz https://github.com/Anton-ewc/k8-argocd-dep/archive/refs/tags/arg.tar.gz &&
tar -xzf arg.tar.gz --strip-components=1 &&
chmod +x cloud-shell.sh &&
./cloud-shell.sh
```



This repo provides a Dockerized automation tool (`k8_builder`) that:

- **Creates or reuses GCP projects** automatically.
- **Enables required APIs and Artifact Registry**.
- **Configures Workload Identity + Kaniko** for Argo Workflows.
- Is designed to be called from **Argo CD + Argo Workflows** so that
  **adding a project in the Argo CD UI automatically bootstraps its GCP project and Kubernetes resources.**

You can run it:

- **Fully automated in Cloud Shell** using `cloud-shell.sh` (recommended).
- Manually from a local terminal or Cloud Shell.
- Indirectly from Argo Workflows (triggered by Argo CD).

---

### 0. Installation steps (high level)

1. **Set prerequisites**  
   - Have at least one GCP project and a billing account linked to it.  
   - In Cloud Shell you already have `gcloud` and `kubectl` installed.
2. **(Recommended) Run `cloud-shell.sh` in Cloud Shell**  
   - It will automatically detect project, billing account, region, cluster name, build the image with Cloud Build, create or reuse a GKE Autopilot cluster, install Argo CD + Argo Workflows, and apply the `project-bootstrap` `WorkflowTemplate`.
3. **(Optional) Build and push the automation image manually**  
   - From the `k8_builder` directory, build and push  
     `k8-builder:latest` to Artifact Registry (section **2** below).
4. **(Optional) Test automation locally**  
   - Run the image with Docker to confirm it can create or configure a project (section **3**).
5. **Create the GKE Autopilot cluster**  
   - Create a cluster in the platform project and get credentials (section **4**).
6. **Install Argo CD and Argo Workflows**  
   - Apply the official manifests into namespaces `argocd` and `argo` (section **5**).
7. **Create the shared WorkflowTemplate**  
   - Apply `project-bootstrap-workflowtemplate.yaml` so the cluster knows how to run `k8_builder` (section **6**).
8. **Create a `platform-config` Git repo**  
   - For each project, add an `app.yaml` (Argo CD Application) and `bootstrap-workflow.yaml` (Sync hook) (section **7**).
9. **Connect the config repo in Argo CD and sync**  
   - Add the repo in the Argo CD UI, create a config Application per project, and hit **Sync** (section **8**).  
   - When you add a new project folder and sync, Argo CD + Argo Workflows automatically call `k8_builder`, which creates/configures the GCP project and Kubernetes resources.

---

### 1. Prerequisites

- **Tools**:
  - In **Cloud Shell**: `gcloud` and `kubectl` are pre-installed. `docker` is optional; `cloud-shell.sh` uses **Cloud Build** if Docker is not available.
  - On **local** machines: install `gcloud`, `kubectl`, and (for manual image builds) `docker`.
- **GCP**:
  - A **platform project** (where the GKE cluster and Argo live), call it `PLATFORM_PROJECT_ID`.
  - A **billing account ID**, e.g. `XXXXXX-XXXXXX-XXXXXX`.
  - Optional: `ORG_ID` or `FOLDER_ID` where new projects should be created.

---

### 2. Run the automated setup in Cloud Shell (recommended)

From Google Cloud Shell:

```bash
git clone https://github.com/YOUR_USER/k8_builder.git   # or open your existing repo
cd k8_builder
chmod +x cloud-shell.sh
./cloud-shell.sh
```

The script will:

- Auto-detect a **platform project** ID (preferring non-test projects) and ask you to confirm it.
- Auto-detect a **billing account ID** (from billing accounts or the project’s current billing) and ask you to confirm it.
- Suggest a **region** and **cluster name** based on your config/metadata.
- Build and push the `k8_builder` image (using **Cloud Build** by default).
- Create or reuse a **GKE Autopilot cluster**.
- Install / update **Argo CD** and **Argo Workflows**.
- Apply the **`project-bootstrap` WorkflowTemplate** wired to the built image and billing info.

After this, you can skip sections **4–6** unless you want to do them manually.

---

### 3. Build and push the automation Docker image manually

If you prefer to build the image yourself (e.g. from a local machine):

```bash
cd /path/to/k8_builder

export PLATFORM_PROJECT_ID="YOUR_PLATFORM_PROJECT_ID"
export REGION="us-central1"

gcloud config set project "$PLATFORM_PROJECT_ID"
gcloud services enable artifactregistry.googleapis.com

gcloud artifacts repositories create k8-builder-images \
  --repository-format=docker \
  --location="$REGION" || true

gcloud auth configure-docker "$REGION-docker.pkg.dev"

docker build -t "$REGION-docker.pkg.dev/$PLATFORM_PROJECT_ID/k8-builder-images/k8-builder:latest" .
docker push "$REGION-docker.pkg.dev/$PLATFORM_PROJECT_ID/k8-builder-images/k8-builder:latest"
```

This image runs `setup.sh` as its entrypoint.

---

### 4. Manually run the automation (optional test)

To test end-to-end automation for a **specific existing project**:

```bash
export PROJECT_ID="EXISTING_GCP_PROJECT_ID"

docker run --rm \
  -v ~/.config/gcloud:/root/.config/gcloud \
  -v ~/.kube:/root/.kube \
  -e PROJECT_ID="$PROJECT_ID" \
  -e REGION="$REGION" \
  "$REGION-docker.pkg.dev/$PLATFORM_PROJECT_ID/k8-builder-images/k8-builder:latest"
```

To **auto-create a new GCP project**:

```bash
docker run --rm \
  -v ~/.config/gcloud:/root/.config/gcloud \
  -v ~/.kube:/root/.kube \
  -e BILLING_ACCOUNT_ID="$BILLING_ACCOUNT_ID" \
  -e ORG_ID="YOUR_ORG_ID" \        # or set FOLDER_ID instead
  -e PROJECT_PREFIX="app-" \
  -e REGION="$REGION" \
  "$REGION-docker.pkg.dev/$PLATFORM_PROJECT_ID/k8-builder-images/k8-builder:latest"
```

If `PROJECT_ID` is not provided, `setup.sh` auto-creates a project with ID like `app-xxxxxx`,
links billing, enables APIs, creates Artifact Registry, configures IAM, and installs Argo Workflows.

---

### 5. Create the GKE Autopilot cluster (one-time)

```bash
gcloud config set project "$PLATFORM_PROJECT_ID"
gcloud services enable container.googleapis.com

gcloud container clusters create-auto "$CLUSTER_NAME" \
  --region "$REGION" \
  --workload-pool="$PLATFORM_PROJECT_ID.svc.id.goog"

gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" \
  --project "$PLATFORM_PROJECT_ID"
```

---

### 6. Install Argo CD and Argo Workflows (one-time)

```bash
# Argo CD
kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Argo Workflows
kubectl create namespace argo || true
kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/latest/download/install.yaml
```

You should see pods in namespaces `argocd` and `argo`.

---

### 7. Create the shared WorkflowTemplate in the cluster

Create a file (in any repo you sync, or just locally) called `project-bootstrap-workflowtemplate.yaml`:

```yaml
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
        image: REGION-docker.pkg.dev/PLATFORM_PROJECT_ID/k8-builder-images/k8-builder:latest
        env:
          - name: BILLING_ACCOUNT_ID
            value: "YOUR_BILLING_ACCOUNT_ID"
          - name: ORG_ID
            value: "YOUR_ORG_ID"        # or leave empty and use FOLDER_ID
          - name: FOLDER_ID
            value: ""                   # optional
          - name: REGION
            value: "us-central1"
          - name: PROJECT_ID
            value: "{{workflow.parameters.projectId}}"
          - name: PROJECT_PREFIX
            value: "{{workflow.parameters.projectPrefix}}"
```

Apply it:

```bash
kubectl apply -n argo -f project-bootstrap-workflowtemplate.yaml
```

Replace `REGION` and `PLATFORM_PROJECT_ID` with your actual values in the YAML.

---

### 8. Wiring projects for full automation with Argo CD

Use a separate **config repo** for project definitions, for example:

```text
platform-config/
  basic-test/
    app.yaml
    bootstrap-workflow.yaml
  another-project/
    app.yaml
    bootstrap-workflow.yaml
```

#### 7.1 Example `app.yaml` for `basic-test`

`platform-config/basic-test/app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: basic-test
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "https://github.com/YOUR_USER/YOUR_APP_REPO.git"
    path: "AZURE_MIG/basic-test/manifests"
    targetRevision: HEAD
  destination:
    server: "https://kubernetes.default.svc"
    namespace: basic-test
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

#### 7.2 Example `bootstrap-workflow.yaml` (auto-create project)

`platform-config/basic-test/bootstrap-workflow.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: basic-test-bootstrap
  namespace: argo
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  workflowTemplateRef:
    name: project-bootstrap
  arguments:
    parameters:
      - name: projectId
        value: ""               # empty → auto-create new project
      - name: projectPrefix
        value: "basic-test-"
```

Commit and push `platform-config` to your Git server.

---

### 9. Configure Argo CD to use the config repo

1. Open the **Argo CD Web-UI**.
2. Go to **Settings → Repositories → CONNECT REPO**.
3. Add your `platform-config` Git URL.
4. Click **NEW APP**:
   - **Name**: `basic-test-config`
   - **Project**: `default`
   - **Repository URL**: your `platform-config` repo
   - **Path**: `basic-test`
   - **Destination**: your cluster, namespace `argocd` (or another of your choice)
5. Click **Create** and then **Sync** the `basic-test-config` app.

On sync:

- Argo CD creates the `basic-test` `Application` and the `basic-test-bootstrap` `Workflow`.
- When the `basic-test` app syncs:
  - It deploys your app manifests.
  - It triggers the bootstrap workflow, which runs the `k8_builder` Docker image and:
    - Creates or reuses a GCP project.
    - Configures APIs, Artifact Registry, IAM, and Argo Workflows.

From now on, to onboard a **new project**:

1. Add a new folder in `platform-config` (`project-x/` with `app.yaml` + `bootstrap-workflow.yaml`).
2. Add the app’s K8s manifests to its own app repo.
3. In Argo CD UI, create a new config app pointing at `project-x/` and sync.

All GCP + Kubernetes bootstrapping runs automatically via this `k8_builder` automation. 