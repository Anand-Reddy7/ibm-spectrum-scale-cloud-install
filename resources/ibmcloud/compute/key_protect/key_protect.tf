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

# Get the Key Protect Server certificate
resource "null_resource" "openssl_commands" {
  provisioner "local-exec" {
    command = <<EOT
      openssl s_client -showcerts -connect ${region}.kms.cloud.ibm.com:5696 < /dev/null >> KeyProtect_Server.cert
      END_DATE=$(openssl x509 -enddate -noout -in KeyProtect_Server.cert | awk -F'=' '{print $2}')
      CURRENT_DATE=$(date -u +"%b %d %T %Y GMT")
      HOURS=$(( ( $(date -d "$END_DATE" +%s) - $(date -d "$CURRENT_DATE" +%s) ) / 3600 ))
      echo $HOURS > hours.txt
      awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' KeyProtect_Server.cert >> KeyProtect_Server_CA.cert
      awk '/-----BEGIN CERTIFICATE-----/{x="KeyProtect_Server.chain"i".cert";i++} {print > x}' KeyProtect_Server_CA.cert
      mv KeyProtect_Server.chain.cert KeyProtect_Server.chain0.cert
    EOT
  }
}

# Read the HOURS value from the file
data "local_file" "hours" {
  filename = "${path.module}/hours.txt"
}

## Create a Self Signed Certificate
resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "example" {
  private_key_pem = tls_private_key.example.private_key_pem

  subject {
    common_name           = "strgscale.com"
    organization          = "International Business Machines Corporation"
    organizational_unit   = "WES"
    country               = "US"
    province              = "New York"
    locality              = "Armonk"
  }
}

# Generate a self-signed certificate
resource "tls_self_signed_cert" "example" {
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  private_key_pem = tls_private_key.example.private_key_pem
  subject {
    common_name           = "strgscale.com"
    organization          = "International Business Machines Corporation"
    organizational_unit   = "WES"
    country               = "US"
    province              = "New York"
    locality              = "Armonk"
  }

  validity_period_hours = tonumber(trimspace(data.local_file.hours.content))
}

# Save the private key to a file
resource "local_file" "private_key" {
  content  = tls_private_key.example.private_key_pem
  filename = "${path.module}/SSL/KPClient.key"
}

# Save the certificate to a file
resource "local_file" "certificate" {
  content  = tls_self_signed_cert.example.cert_pem
  filename = "${path.module}/SSL/KPClient.cert"
}

# Save the CSR to a file
resource "local_file" "csr" {
  content  = tls_cert_request.example.cert_request_pem
  filename = "${path.module}/SSL/KPClient.csr"
}

## Key Protect
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

resource "ibm_kms_kmip_client_cert" "mycert" {
  instance_id = ibm_resource_instance.kms_instance.guid
  adapter_id = ibm_kms_kmip_adapter.myadapter.adapter_id
  certificate = tls_self_signed_cert.example.cert_pem
  name = format("%s-keyprotect-adapter-cert", var.resource_prefix)
}