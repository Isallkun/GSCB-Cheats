#!/bin/bash
set -euo pipefail

# ===== Colors =====
COLOR_RED=$'\033[0;31m'; COLOR_GREEN=$'\033[0;32m'; COLOR_YELLOW=$'\033[0;33m'
COLOR_BLUE=$'\033[0;34m'; COLOR_CYAN=$'\033[0;36m'; COLOR_RESET=$'\033[0m'
BOLD=$'\033[1m'; UNDERLINE=$'\033[4m'

clear
echo "${COLOR_BLUE}${BOLD}=======================================${COLOR_RESET}"
echo "${COLOR_BLUE}${BOLD}         INITIATING EXECUTION...       ${COLOR_RESET}"
echo "${COLOR_BLUE}${BOLD}=======================================${COLOR_RESET}"
echo

# ===== Enable APIs =====
echo "${COLOR_BLUE}${BOLD}Enabling Required GCP Services...${COLOR_RESET}"
gcloud services enable \
  artifactregistry.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  eventarc.googleapis.com \
  run.googleapis.com \
  logging.googleapis.com \
  osconfig.googleapis.com \
  pubsub.googleapis.com

# ===== Project Vars =====
export PROJECT_ID="$(gcloud config get-value project)"
PROJECT_NUMBER="$(gcloud projects list --filter="project_id:${PROJECT_ID}" --format='value(project_number)')"

# REGION/ZONE from metadata or fallback
export ZONE="$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])")"
export REGION="$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-region])")"
if [[ -z "${REGION}" || -z "${ZONE}" ]]; then
  ZONE="${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || true)}"
  REGION="${REGION:-$(gcloud config get-value compute/region 2>/dev/null || true)}"
  if [[ -z "${REGION}" && -n "${ZONE}" ]]; then REGION="${ZONE%-*}"; fi
  REGION="${REGION:-us-central1}"
  ZONE="${ZONE:-${REGION}-a}"
fi
gcloud config set compute/region "$REGION" >/dev/null
gcloud config set compute/zone "$ZONE" >/dev/null

COMPUTE_DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# ===== IAM Fixes (Build/Logs/AR) =====
echo "${COLOR_BLUE}${BOLD}Configuring IAM for build & logging...${COLOR_RESET}"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${COMPUTE_DEFAULT_SA}" \
  --role roles/cloudbuild.builds.builder || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${COMPUTE_DEFAULT_SA}" \
  --role roles/artifactregistry.writer || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${COMPUTE_DEFAULT_SA}" \
  --role roles/logging.logWriter || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${COMPUTE_DEFAULT_SA}" \
  --role roles/eventarc.eventReceiver || true

# (Opsional) Pub/Sub publisher untuk KMS SA—hanya jika tersedia
SERVICE_ACCOUNT_KMS="$(gsutil kms serviceaccount -p "${PROJECT_NUMBER}" 2>/dev/null || true)"
if [[ -n "${SERVICE_ACCOUNT_KMS}" ]]; then
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${SERVICE_ACCOUNT_KMS}" \
    --role roles/pubsub.publisher || true
fi

# Verifikasi cepat
echo
echo "${COLOR_CYAN}${BOLD}Verifying IAM bindings...${COLOR_RESET}"
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.role:(roles/cloudbuild.builds.builder roles/artifactregistry.writer roles/logging.logWriter) AND bindings.members:serviceAccount:${COMPUTE_DEFAULT_SA}" \
  --format="table(bindings.role,bindings.members)"

# ===== Helper Deploy (tanpa --build-service-account) =====
deploy_with_retry() {
  local function_name="$1"; shift
  local attempts=0; local max_attempts=5
  while (( attempts < max_attempts )); do
    echo "${COLOR_YELLOW}${BOLD}Attempt $((attempts+1)): Deploying ${function_name}...${COLOR_RESET}"
    if gcloud functions deploy "${function_name}" --quiet "$@"; then
      echo "${COLOR_GREEN}${BOLD}${function_name} deployed successfully!${COLOR_RESET}"
      return 0
    fi
    attempts=$((attempts+1))
    echo "${COLOR_RED}${BOLD}Deployment failed. Retrying in 30 seconds...${COLOR_RESET}"
    sleep 30
  done
  echo "${COLOR_RED}${BOLD}Failed to deploy ${function_name} after ${max_attempts} attempts${COLOR_RESET}"
  return 1
}

# ===== HTTP Function (Gen2) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying HTTP Trigger Function...${COLOR_RESET}"
mkdir -p ~/hello-http && cd ~/hello-http
cat > index.js <<'EOF'
const functions = require('@google-cloud/functions-framework');
functions.http('helloWorld', (req, res) => {
  res.status(200).send('HTTP with Node.js in GCF 2nd gen!');
});
EOF
cat > package.json <<'EOF'
{
  "name": "nodejs-http-function",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "@google-cloud/functions-framework": "^3.0.0"
  }
}
EOF

# Generate package-lock.json to speed up build & remove warning
npm install --no-audit --no-fund

RUNTIME_NODE="nodejs20"   # ganti ke nodejs22 jika region mendukung / lab mewajibkan

deploy_with_retry nodejs-http-function \
  --gen2 \
  --runtime "${RUNTIME_NODE}" \
  --entry-point helloWorld \
  --source . \
  --region "$REGION" \
  --trigger-http \
  --timeout 600s \
  --max-instances 1 \
  --allow-unauthenticated

# Test via URL untuk HTTP Gen2
HTTP_URL="$(gcloud functions describe nodejs-http-function --gen2 --region "$REGION" --format='value(serviceConfig.uri)')"
echo "${COLOR_CYAN}${BOLD}HTTP URL:${COLOR_RESET} ${HTTP_URL}"
echo "${COLOR_CYAN}${BOLD}Curling the function...${COLOR_RESET}"
curl -sS "${HTTP_URL}" || true
echo

# ===== Storage Trigger Function (idempotent & no unauth log spam) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying Storage Trigger Function...${COLOR_RESET}"
mkdir -p ~/hello-storage && cd ~/hello-storage
cat > index.js <<'EOF'
const functions = require('@google-cloud/functions-framework');
functions.cloudEvent('helloStorage', (cloudevent) => {
  console.log('Cloud Storage event received in GCF 2nd gen!');
  console.log(cloudevent);
});
EOF
cat > package.json <<'EOF'
{
  "name": "nodejs-storage-function",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "@google-cloud/functions-framework": "^3.0.0"
  }
}
EOF

# Generate package-lock.json
npm install --no-audit --no-fund

# Bucket unik & idempotent
BUCKET_NAME="gcf-gen2-storage-${PROJECT_ID}-$(date +%s)"
BUCKET_URI="gs://${BUCKET_NAME}"
if ! gsutil ls -b "${BUCKET_URI}" >/dev/null 2>&1; then
  gsutil mb -p "$PROJECT_ID" -l "$REGION" "${BUCKET_URI}"
fi

deploy_with_retry nodejs-storage-function \
  --gen2 \
  --runtime "${RUNTIME_NODE}" \
  --entry-point helloStorage \
  --source . \
  --region "$REGION" \
  --trigger-bucket "${BUCKET_NAME}" \
  --trigger-location "$REGION" \
  --max-instances 1

# Trigger test (tidak mengakses URL service secara langsung)
echo "Hello World" > random.txt
gsutil cp random.txt "${BUCKET_URI}/random.txt"
echo "${COLOR_BLUE}${BOLD}Reading recent logs for storage function...${COLOR_RESET}"
gcloud functions logs read nodejs-storage-function --region "$REGION" --gen2 --limit=50 --format "value(log)" || true

# ===== VM Labeler via Eventarc (idempotent VM) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying VM Labeler Function (Eventarc)...${COLOR_RESET}"
cd ~
if [[ ! -d eventarc-samples ]]; then
  git clone https://github.com/GoogleCloudPlatform/eventarc-samples.git
fi
cd ~/eventarc-samples/gce-vm-labeler/gcf/nodejs
# pastikan dependencies (kalau repo ini butuh)
npm install --no-audit --no-fund || true

deploy_with_retry gce-vm-labeler \
  --gen2 \
  --runtime "${RUNTIME_NODE}" \
  --entry-point labelVmCreation \
  --source . \
  --region "$REGION" \
  --trigger-event-filters="type=google.cloud.audit.log.v1.written,serviceName=compute.googleapis.com,methodName=beta.compute.instances.insert" \
  --trigger-location "$REGION" \
  --max-instances 1

# Buat VM idempotent: hapus jika sudah ada, lalu buat ulang
echo
echo "${COLOR_BLUE}${BOLD}Creating Test VM Instance (idempotent)...${COLOR_RESET}"
VM_NAME="instance-1"
if gcloud compute instances describe "${VM_NAME}" --zone "${ZONE}" >/dev/null 2>&1; then
  echo "${COLOR_YELLOW}${BOLD}${VM_NAME} exists. Deleting first...${COLOR_RESET}"
  gcloud compute instances delete "${VM_NAME}" --zone "${ZONE}" --quiet
fi

gcloud compute instances create "${VM_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --machine-type=e2-medium \
  --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
  --metadata=enable-osconfig=TRUE,enable-oslogin=true \
  --maintenance-policy=MIGRATE \
  --provisioning-model=STANDARD \
  --service-account="${COMPUTE_DEFAULT_SA}" \
  --scopes="https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append" \
  --create-disk=auto-delete=yes,boot=yes,device-name="${VM_NAME}",image=projects/debian-cloud/global/images/debian-12-bookworm-v20250311,mode=rw,size=10,type=pd-balanced \
  --no-shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --labels=goog-ops-agent-policy=v2-x86-template-1-4-0,goog-ec-src=vm_add-gcloud \
  --reservation-affinity=any

echo
echo "${COLOR_CYAN}${BOLD}Done. HTTP function URL:${COLOR_RESET} ${HTTP_URL}"
echo "${COLOR_GREEN}${BOLD}Deployments completed (HTTP, Storage trigger, VM labeler).${COLOR_RESET}"
