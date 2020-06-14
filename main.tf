// ----------------------------------------------------------------------------
// Enforce Terraform version
//
// Using pessemistic version locking for all versions 
// ----------------------------------------------------------------------------
terraform {
  required_version = "~> 0.12.0"
}

// ----------------------------------------------------------------------------
// Configure providers
// ----------------------------------------------------------------------------
provider "google" {
  project = var.gcp_project
  version = ">= 2.12.0"
  region  = var.region
  zone    = var.zone
}

provider "google-beta" {
  project = var.gcp_project
  version = ">= 2.12.0"
  region  = var.region
  zone    = var.zone
}

provider "random" {
  version = ">= 2.2.0"
}

provider "local" {
  version = ">= 1.2.0"
}

provider "null" {
  version = ">= 2.1.0"
}

provider "template" {
  version = ">= 2.1.0"
}

data "google_client_config" "default" {
}

provider "kubernetes" {
  version          = ">= 1.11.0"
  load_config_file = false

  host  = "https://${module.cluster.cluster_endpoint}"
  token = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(
    module.cluster.cluster_ca_certificate,
  )
}

resource "random_id" "random" {
  byte_length = 6
}

resource "random_pet" "current" {
  prefix    = "tf-jx"
  separator = "-"
  keepers = {
    # Keep the name consistent on executions
    cluster_name = var.cluster_name
  }
}

locals {
  cluster_name = "${var.cluster_name != "" ? var.cluster_name : random_pet.current.id}"
  # provide backwards compatabilty with the depreacted zone variable
  location       = "${var.zone != "" ? var.zone : var.cluster_location}"
  external_vault = var.vault_url != "" ? true : false
}

// ----------------------------------------------------------------------------
// Enable all required GCloud APIs
//
// https://www.terraform.io/docs/providers/google/r/google_project_service.html
// ----------------------------------------------------------------------------
resource "google_project_service" "cloudresourcemanager_api" {
  provider           = google
  project            = var.gcp_project
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute_api" {
  provider           = google
  project            = var.gcp_project
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam_api" {
  provider           = google
  project            = var.gcp_project
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild_api" {
  provider           = google
  project            = var.gcp_project
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "containerregistry_api" {
  provider           = google
  project            = var.gcp_project
  service            = "containerregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "containeranalysis_api" {
  provider           = google
  project            = var.gcp_project
  service            = "containeranalysis.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "serviceusage_api" {
  provider           = google
  project            = var.gcp_project
  service            = "serviceusage.googleapis.com"
  disable_on_destroy = false
}

// ----------------------------------------------------------------------------
// Create Kubernetes cluster
// ----------------------------------------------------------------------------
module "cluster" {
  source = "./modules/cluster"

  gcp_project         = var.gcp_project
  cluster_name        = local.cluster_name
  cluster_location    = local.location
  cluster_id          = random_id.random.hex
  bucket_location     = var.bucket_location
  jenkins_x_namespace = var.jenkins_x_namespace
  force_destroy       = var.force_destroy

  node_machine_type = var.node_machine_type
  node_disk_size    = var.node_disk_size
  node_disk_type    = var.node_disk_type
  min_node_count    = var.min_node_count
  max_node_count    = var.max_node_count
  release_channel   = var.release_channel
  resource_labels   = var.resource_labels
}

// ----------------------------------------------------------------------------
// Setup all required resources for using the  bank-vaults operator
// See https://github.com/banzaicloud/bank-vaults
// ----------------------------------------------------------------------------
module "vault" {
  source = "./modules/vault"

  gcp_project         = var.gcp_project
  cluster_name        = local.cluster_name
  cluster_id          = random_id.random.hex
  bucket_location     = var.bucket_location
  jenkins_x_namespace = module.cluster.jenkins_x_namespace
  force_destroy       = var.force_destroy
  external_vault      = local.external_vault
}

// ----------------------------------------------------------------------------
// Setup all required resources for using Velero for cluster backups
// ----------------------------------------------------------------------------
module "backup" {
  source = "./modules/backup"

  enable_backup       = var.enable_backup
  gcp_project         = var.gcp_project
  cluster_name        = local.cluster_name
  cluster_id          = random_id.random.hex
  bucket_location     = var.bucket_location
  jenkins_x_namespace = module.cluster.jenkins_x_namespace
  force_destroy       = var.force_destroy
}

// ----------------------------------------------------------------------------
// Setup DNS and static ip
// ----------------------------------------------------------------------------
module "dns" {
  source = "./modules/dns2"

  gcp_project         = var.gcp_project
  zone                = var.zone
  region              = var.region
  cluster_name        = local.cluster_name
  parent_domain       = var.parent_domain
  managed_zone_name   = var.managed_zone_name

}

// ----------------------------------------------------------------------------
// Let's generate jx-requirements.yml 
// ----------------------------------------------------------------------------
locals {
  core_env_content = templatefile("${path.module}/modules/core-env.yaml.tpl", {
    domain                      = module.dns.fqdn
    ipAddress                   = module.dns.static_ip
    adminEmail                  = var.tls_email
  })

  content2        = join("\n", compact(split("\n", local.core_env_content)))
}

resource "local_file" "core-env" {
  content  = "${local.content2}\n"
  filename = "${path.cwd}/core-env.yaml"
}
// ----------------------------------------------------------------------------
// Let's make sure `jx boot` can connect to the cluster for local booting 
// ----------------------------------------------------------------------------
resource "null_resource" "kubeconfig" {
  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${local.cluster_name} --zone=${module.cluster.cluster_location} --project=${var.gcp_project}"
  }
}
