terraform {
  backend "s3" {
    bucket       = "pineapple.dev"
    key          = "terraform/epm-lab.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
