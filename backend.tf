terraform {
  backend "s3" {
    bucket       = "REPLACE_ME-tfstate"
    key          = "epm-pineapple-lab/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
