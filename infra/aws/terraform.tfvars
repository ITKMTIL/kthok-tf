# Copy to terraform.tfvars and replace these example values.
region             = "us-east-1"
availability_zones = ["us-east-1a", "us-east-1b"]
root_domain        = "k-thok.space"
# Leave hosted_zone_id unset so Terraform creates the public Route 53 zone.
# If you already have a public zone, set hosted_zone_id = "Z..." instead.
site_domain      = "k-thok.space"
api_domain       = "api.k-thok.space"
google_client_id = "1084948782609-m0akdb1espujfeedl484trj5iplcdijv.apps.googleusercontent.com"

# Keep false for the first apply. Set true after images, secrets and migration.
enable_services   = true
client_image_tag  = "45d5f7d5a814-google"
core_image_tag    = "2117b9d7dbbb"
migrate_image_tag = "2117b9d7dbbb-migrate"

existing_lab_role_arn = "arn:aws:iam::490721063071:role/LabRole"
