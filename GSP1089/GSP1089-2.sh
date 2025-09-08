#!/bin/bash
set -euo pipefail

# ===== Colors & Text Styles =====
COLOR_BLACK=$'\033[0;30m'; COLOR_RED=$'\033[0;31m'; COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[0;33m'; COLOR_BLUE=$'\033[0;34m'; COLOR_MAGENTA=$'\033[0;35m'
COLOR_CYAN=$'\033[0;36m'; COLOR_WHITE=$'\033[0;37m'; COLOR_RESET=$'\033[0m'
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
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

# Try to detect defaults; if empty, fall back to first available region/zone
export ZONE="$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])")"
export REGION="$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-region])")"

if [[ -z "${REGION}" ]]; then
  REGION="$(gcloud compute regions list --format='value(name)' | head -n1)"
fi
if [[ -z "${ZONE}" ]]; then
  ZONE="$(gcloud compute zones list --filter="region:( ${REGION} )" --format='value(name)' | head -n1)"
fi

gcloud config set compute/region "$REGION" >/dev/null

echo "${COLOR_GREEN}Project: ${PROJECT_ID} (${PROJECT_NUMBER})${COLOR_RESET}"
echo "${COLOR_GREEN}Region : ${REGION}${COLOR_RESET}"
echo "${COLOR_GREEN}Zone   : ${ZONE}${COLOR_RESET}"

# ===== IAM Fixes (critical for your error) =====
echo
echo "${COLOR_BLUE}${BOLD}Configuring IAM roles...${COLOR_RESET}"

# GCS KMS service account (valid command for gsutil)
GCS_SA="$(gsutil kms serviceaccount -p "$PROJECT_NUMBER")"

# Pub/Sub publisher to GCS service account
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${GCS_SA}" \
  --role roles/pubsub.publisher

# Eventarc receiver to Compute default SA (used by trigger delivery)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role roles/eventarc.eventReceiver

# ====== IMPORTANT: Logs Writer (fixes original logging error) ======
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role roles/logging.logWriter

# Cloud Build SA also gets Logs Writer
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role roles/logging.logWriter

# ===== Build SA & source buckets permissions (fixes build failure) =====
echo
echo "${COLOR_BLUE}${BOLD}Granting build permissions for Cloud Functions Gen2...${COLOR_RESET}"

# Allow Cloud Build SA to push images to Artifact Registry
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role roles/artifactregistry.writer

# Grant objectViewer on ALL gcf-v2-sources buckets (any region you've used)
# to BOTH the Compute default SA and the Cloud Build SA.
echo "${COLOR_BLUE}Scanning gcf-v2-sources buckets and granting objectViewer...${COLOR_RESET}"
for b in $(gsutil ls -p "$PROJECT_ID" 2>/dev/null | grep "gs://gcf-v2-sources-${PROJECT_NUMBER}-" || true); do
  echo " - $b"
  gsutil iam ch \
    serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com:objectViewer \
    "$b" || true
  gsutil iam ch \
    serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com:objectViewer \
    "$b" || true
done

# If you know the deploy region is different from $REGION (e.g. us-east1 from logs),
# also grant explicitly just in case bucket list is delayed.
for extra_region in "$REGION" "us-east1"; do
  b="gs://gcf-v2-sources-${PROJECT_NUMBER}-${extra_region}"
  if gsutil ls "$b" >/dev/null 2>&1; then
    echo "Ensuring objectViewer on $b"
    gsutil iam ch \
      serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com:objectViewer \
      "$b" || true
    gsutil iam ch \
      serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com:objectViewer \
      "$b" || true
  fi
done

# ===== Audit logs for compute (append safely, using jq) =====
echo
echo "${COLOR_BLUE}${BOLD}Updating audit logging for Compute (via jq)...${COLOR_RESET}"
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT
gcloud projects get-iam-policy "$PROJECT_ID" --format=json > "$TMP_DIR/policy.json"

jq '
  .auditConfigs = (.auditConfigs // []) |
  ( if any(.auditConfigs[]?; .service == "compute.googleapis.com")
    then .
    else .auditConfigs += [
      {
        "service": "compute.googleapis.com",
        "auditLogConfigs": [
          {"logType":"ADMIN_READ"},
          {"logType":"DATA_READ"},
          {"logType":"DATA_WRITE"}
        ]
      }
    ] end
  )
' "$TMP_DIR/policy.json" > "$TMP_DIR/policy_new.json"

gcloud projects set-iam-policy "$PROJECT_ID" "$TMP_DIR/policy_new.json" >/dev/null

# ===== Helper: robust deploy with retries =====
deploy_with_retry() {
  local function_name=$1; shift
  local attempts=0; local max_attempts=5
  while (( attempts < max_attempts )); do
    echo "${COLOR_YELLOW}${BOLD}Attempt $((attempts+1)): Deploying ${function_name}...${COLOR_RESET}"
    if gcloud functions deploy "${function_name}" "$@" --quiet; then
      echo "${COLOR_GREEN}${BOLD}${function_name} deployed successfully!${COLOR_RESET}"
      return 0
    fi
    attempts=$((attempts+1))
    echo "${COLOR_RED}${BOLD}Deployment failed. Retrying in 30s...${COLOR_RESET}"
    sleep 30
  done
  echo "${COLOR_RED}${BOLD}Failed to deploy ${function_name} after ${max_attempts} attempts.${COLOR_RESET}"
  return 1
}

# ===== HTTP Function (Node 22, Gen2) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying HTTP Trigger Function...${COLOR_RESET}"
mkdir -p ~/hello-http && cd ~/hello-http
cat > index.js <<'EOF'
const functions = require('@google-cloud/functions-framework');
functions.http('helloWorld', (req, res) => {
  res.status(200).send('HTTP with Node.js 22 in GCF 2nd gen!');
});
EOF
cat > package.json <<'EOF'
{
  "name": "nodejs-http-function",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "@google-cloud/functions-framework": "^3.4.0"
  }
}
EOF

deploy_with_retry nodejs-http-function \
  --gen2 \
  --runtime nodejs22 \
  --entry-point helloWorld \
  --source . \
  --region "$REGION" \
  --trigger-http \
  --timeout 600s \
  --max-instances 1 \
  --allow-unauthenticated

# Test (Gen2 doesn't support `gcloud functions call`)
HTTP_URL="$(gcloud functions describe nodejs-http-function --gen2 --region "$REGION" --format='value(serviceConfig.uri)')"
echo "${COLOR_CYAN}Calling: ${HTTP_URL}${COLOR_RESET}"
curl -sS "$HTTP_URL" || true

# ===== Storage-triggered Function (Node 22, Gen2) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying Storage Trigger Function...${COLOR_RESET}"
mkdir -p ~/hello-storage && cd ~/hello-storage
cat > index.js <<'EOF'
const functions = require('@google-cloud/functions-framework');
functions.cloudEvent('helloStorage', (cloudevent) => {
  console.log('Cloud Storage event with Node.js 22 in GCF 2nd gen!');
  console.log(JSON.stringify(cloudevent));
});
EOF
cat > package.json <<'EOF'
{
  "name": "nodejs-storage-function",
  "version": "1.0.0",
  "main": "index.js",
  "dependencies": {
    "@google-cloud/functions-framework": "^3.4.0"
  }
}
EOF

BUCKET="gs://gcf-gen2-storage-$PROJECT_ID"
gsutil mb -l "$REGION" "$BUCKET" || true

deploy_with_retry nodejs-storage-function \
  --gen2 \
  --runtime nodejs22 \
  --entry-point helloStorage \
  --source . \
  --region "$REGION" \
  --trigger-bucket "$BUCKET" \
  --trigger-location "$REGION" \
  --max-instances 1

# Trigger an event & read logs
echo "Hello World" > random.txt
gsutil cp random.txt "$BUCKET/random.txt"
echo
echo "${COLOR_BLUE}${BOLD}Checking Storage Function Logs...${COLOR_RESET}"
gcloud functions logs read nodejs-storage-function --region "$REGION" --gen2 --limit=50 || true

# ===== VM Labeler Function (Eventarc audit log trigger) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying VM Labeler Function...${COLOR_RESET}"
cd ~
[[ -d eventarc-samples ]] || git clone https://github.com/GoogleCloudPlatform/eventarc-samples.git
cd ~/eventarc-samples/gce-vm-labeler/gcf/nodejs

# NOTE: pass separate --trigger-event-filters flags (not comma-joined)
deploy_with_retry gce-vm-labeler \
  --gen2 \
  --runtime nodejs22 \
  --entry-point labelVmCreation \
  --source . \
  --region "$REGION" \
  --trigger-event-filters="type=google.cloud.audit.log.v1.written" \
  --trigger-event-filters="serviceName=compute.googleapis.com" \
  --trigger-event-filters="methodName=v1.compute.instances.insert" \
  --trigger-location "$REGION" \
  --max-instances 1

# ===== Create Test VM =====
echo
echo "${COLOR_BLUE}${BOLD}Creating Test VM Instance...${COLOR_RESET}"
gcloud compute instances create instance-1 \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type=e2-medium \
  --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
  --metadata=enable-osconfig=TRUE,enable-oslogin=true \
  --maintenance-policy=MIGRATE \
  --provisioning-model=STANDARD \
  --service-account="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append \
  --create-disk=auto-delete=yes,boot=yes,device-name=instance-1,image-family=debian-12,image-project=debian-cloud,mode=rw,size=10,type=pd-balanced \
  --no-shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --labels=goog-ops-agent-policy=v2-x86-template-1-4-0,goog-ec-src=vm_add-gcloud

# Optional ops agents policy & snapshot schedule (ignore if fail on perms)
printf 'agentsRule:\n  packageState: installed\n  version: latest\ninstanceFilter:\n  inclusionLabels:\n  - labels:\n      goog-ops-agent-policy: v2-x86-template-1-4-0\n' > ~/config.yaml || true
gcloud compute instances ops-agents policies create "goog-ops-agent-v2-x86-template-1-4-0-$ZONE" --zone="$ZONE" --file=~/config.yaml || true
gcloud compute resource-policies create snapshot-schedule default-schedule-1 --region="$REGION" --max-retention-days=14 --on-source-disk-delete=keep-auto-snapshots --daily-schedule --start-time=08:00 || true
gcloud compute disks add-resource-policies instance-1 --zone="$ZONE" --resource-policies="projects/$PROJECT_ID/regions/$REGION/resourcePolicies/default-schedule-1" || true

echo
echo "${COLOR_BLUE}${BOLD}Checking VM Details...${COLOR_RESET}"
gcloud compute instances describe instance-1 --zone "$ZONE" --format='text(name,status,tags,labels)'

# ===== Colored Hello World (Python, Gen2) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying Colored Hello World Function...${COLOR_RESET}"
mkdir -p ~/hello-world-colored && cd ~/hello-world-colored
echo > requirements.txt
cat > main.py <<'EOF'
import os
def hello_world(request):
    color = os.environ.get('COLOR', 'yellow')
    return f'<body style="background-color:{color}"><h1>Hello World!</h1></body>'
EOF

deploy_with_retry hello-world-colored \
  --gen2 \
  --runtime python311 \
  --entry-point hello_world \
  --source . \
  --region "$REGION" \
  --trigger-http \
  --allow-unauthenticated \
  --update-env-vars COLOR=yellow \
  --max-instances 1

COLOR_URL="$(gcloud functions describe hello-world-colored --gen2 --region "$REGION" --format='value(serviceConfig.uri)')"
echo "${COLOR_CYAN}Calling: ${COLOR_URL}${COLOR_RESET}"
curl -sS "$COLOR_URL" || true

# ===== Slow Go Function (Gen2) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying Slow Go Function...${COLOR_RESET}"
mkdir -p ~/min-instances && cd ~/min-instances
cat > main.go <<'EOF'
package p
import (
  "fmt"
  "net/http"
  "time"
)
func init() { time.Sleep(10 * time.Second) }
func HelloWorld(w http.ResponseWriter, r *http.Request) {
  fmt.Fprint(w, "Slow HTTP Go in GCF 2nd gen!")
}
EOF
echo "module example.com/mod" > go.mod

deploy_with_retry slow-function \
  --gen2 \
  --runtime go123 \
  --entry-point HelloWorld \
  --source . \
  --region "$REGION" \
  --trigger-http \
  --allow-unauthenticated \
  --max-instances 4

SLOW_URL="$(gcloud functions describe slow-function --gen2 --region "$REGION" --format='value(serviceConfig.uri)')"
echo "${COLOR_CYAN}Calling: ${SLOW_URL}${COLOR_RESET}"
curl -sS "$SLOW_URL" || true

# ===== Manual step checkpoint =====
echo
echo "${COLOR_CYAN}${BOLD}------ PLEASE COMPLETE MANUAL STEP AND VERIFY YOUR PROGRESS UP TO TASK 6 ------${COLOR_RESET}"
read -rp "Have you completed Task 6? (Y/N): " user_input
[[ "${user_input,,}" == "y" ]] || { echo "${COLOR_RED}Please complete Task 6 first${COLOR_RESET}"; exit 0; }

# ===== Clean up potential Cloud Run with same name (ignore errors) =====
gcloud run services delete slow-function --region "$REGION" --quiet || true

# ===== Concurrent Function (min instances) =====
echo
echo "${COLOR_BLUE}${BOLD}Deploying Concurrent Function...${COLOR_RESET}"
deploy_with_retry slow-concurrent-function \
  --gen2 \
  --runtime go123 \
  --entry-point HelloWorld \
  --source . \
  --region "$REGION" \
  --trigger-http \
  --allow-unauthenticated \
  --min-instances 1 \
  --max-instances 4

CONC_URL="$(gcloud functions describe slow-concurrent-function --gen2 --region "$REGION" --format='value(serviceConfig.uri)')"
echo "${COLOR_CYAN}Calling: ${CONC_URL}${COLOR_RESET}"
curl -sS "$CONC_URL" || true

# ===== Final =====
echo
echo "${COLOR_GREEN}${BOLD}=======================================================${COLOR_RESET}"
echo "${COLOR_GREEN}${BOLD}              LAB COMPLETED SUCCESSFULLY!              ${COLOR_RESET}"
echo "${COLOR_GREEN}${BOLD}=======================================================${COLOR_RESET}"
echo
echo "${COLOR_RED}${UNDERLINE}https://www.youtube.com/@TechCode9${COLOR_RESET}"
