/*
    Creates specified number of IBM Cloud Virtual Server Instance(s).
*/

terraform {
  required_providers {
    ibm = {
      source = "IBM-Cloud/ibm"
    }
  }
}

variable "resource_prefix" {}
variable "region" {}
variable "resource_group_id" {}
variable "resource_tags" {}

resource "ibm_resource_instance" "kms_instance" {
  name              = format("%s-keyprotect", var.resource_prefix)
  service           = "kms"
  plan              = "tiered-pricing"
  location          = var.region
  resource_group_id = var.resource_group_id
  tags              = var.resource_tags
}

resource "ibm_kms_key" "key" {
  instance_id = ibm_resource_instance.kms_instance.guid
  key_name       = "key"
  standard_key   = false
}

resource "ibm_kms_kmip_adapter" "myadapter" {
    instance_id = ibm_resource_instance.kms_instance.guid
    profile = "native_1.0"
    profile_data = {
      "crk_id" = ibm_kms_key.key.key_id
    }
    description = "Key Protect adapter"
    name = format("%s-keyprotect-adapter", var.resource_prefix)
}

# resource "ibm_kms_kmip_client_cert" "mycert" {
#   instance_id = ibm_resource_instance.kms_instance.guid
#   adapter_id = ibm_kms_kmip_adapter.myadapter.adapter_id
#   certificate = file("${path.module}/selfsigned.cert")
#   name = format("%s-keyprotect-adapter-cert", var.resource_prefix)
# }