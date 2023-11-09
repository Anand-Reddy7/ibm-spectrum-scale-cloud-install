terraform {
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "1.56.2"
    }
    github = {
      source  = "integrations/github"
      version = "5.41.0"
    }
  }
}

provider "ibm" {
  region = var.vpc_region
}
