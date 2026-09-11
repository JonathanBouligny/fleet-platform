terraform {
  backend "s3" {
    bucket = "bouligny-terraform-state-434356522212"
    key    = "fleet-platform/terraform.tfstate"
    region = "us-east-1"
    use_lockfile = true
  }
}
