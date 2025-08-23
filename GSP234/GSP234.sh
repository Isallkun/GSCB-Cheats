# 1) Minta region sekali di awal
read -rp "Masukkan region (contoh: us-west1): " REGION

# (opsional) otomatis pakai project aktif di gcloud untuk variable 'project'
PROJECT=$(gcloud config get-value project 2>/dev/null)
echo "Project terdeteksi: ${PROJECT:-<kosong>}"

# Terraform baca env TF_VAR_* sebagai input variable
export TF_VAR_region="$REGION"
export TF_VAR_project="$PROJECT"

# 2) Lanjut langkah lab
mkdir -p sql-with-terraform && cd $_
gsutil cp -r gs://spls/gsp234/gsp234.zip .
unzip -o gsp234.zip

terraform init
terraform plan -out=tfplan
terraform apply "tfplan"
