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
variable "vpc_region" {}
variable "resource_group_id" {}
variable "key_protect_path" {}
variable "resource_tags" {}

resource "null_resource" "openssl_commands" {
  provisioner "local-exec" {
    command = <<EOT
      mkdir -p "${var.key_protect_path}"
      openssl s_client -showcerts -connect "${var.vpc_region}.kms.cloud.ibm.com:5696" < /dev/null > "${var.key_protect_path}/Key_Protect_Server.cert"
      awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "${var.key_protect_path}/Key_Protect_Server.cert" > "${var.key_protect_path}/Key_Protect_Server_CA.cert"
      awk '/-----BEGIN CERTIFICATE-----/{x="${var.key_protect_path}/Key_Protect_Server.chain"i".cert"; i++} {print > x}' "${var.key_protect_path}/Key_Protect_Server_CA.cert"
      mv "${var.key_protect_path}/Key_Protect_Server.chain.cert" "${var.key_protect_path}/Key_Protect_Server.chain0.cert"
      openssl genpkey -algorithm RSA -out "${var.key_protect_path}/${var.resource_prefix}.key"
      openssl req -new -key "${var.key_protect_path}/${var.resource_prefix}.key" -out "${var.key_protect_path}/${var.resource_prefix}.csr" -subj "/C=US/ST=New York/L=Armonk/O=International Business Machines Corporation/CN=strgscale.com"
      openssl x509 -req -days 365 -in "${var.key_protect_path}/${var.resource_prefix}.csr" -signkey "${var.key_protect_path}/${var.resource_prefix}.key" -out "${var.key_protect_path}/${var.resource_prefix}.cert"
    EOT
  }
}

data "local_file" "kpclient_cert" {
  depends_on = [null_resource.openssl_commands]
  filename   = "${var.key_protect_path}/KPClient.cert"
}

resource "ibm_resource_instance" "kms_instance" {
  name              = format("%s-keyprotect", var.resource_prefix)
  service           = "kms"
  plan              = "tiered-pricing"
  location          = var.vpc_region
  resource_group_id = var.resource_group_id
  tags              = var.resource_tags
}

resource "ibm_kms_key" "key" {
  instance_id   = ibm_resource_instance.kms_instance.guid
  key_name      = "key"
  standard_key  = false
}

resource "ibm_kms_kmip_adapter" "myadapter" {
  instance_id  = ibm_resource_instance.kms_instance.guid
  profile      = "native_1.0"
  profile_data = {
    "crk_id" = ibm_kms_key.key.key_id
  }
  description = "Key Protect adapter"
  name        = format("%s-keyprotect-adapter", var.resource_prefix)
}

resource "ibm_kms_kmip_client_cert" "mycert" {
  instance_id  = ibm_resource_instance.kms_instance.guid
  adapter_id   = ibm_kms_kmip_adapter.myadapter.adapter_id
  certificate  = data.local_file.kpclient_cert.content
  name         = format("%s-keyprotect-adapter-cert", var.resource_prefix)
  depends_on = [data.local_file.kpclient_cert]
}

# resource "null_resource" "openssl_commands" {
#   provisioner "local-exec" {
#     command = <<EOT
#       # Create SSL directory if it doesn't exist
#       mkdir -p "${var.key_protect_path}"
      
#       # Fetch the server certificate and save it to a file
#       openssl s_client -showcerts -connect "${var.vpc_region}.kms.cloud.ibm.com:5696" < /dev/null > "${var.key_protect_path}/Key_Protect_Server.cert"
      
#       # Extract the end date of the certificate
#       END_DATE=$(openssl x509 -enddate -noout -in "${var.key_protect_path}/Key_Protect_Server.cert" | awk -F'=' '{print $2}')
      
#       # Get the current date in GMT
#       CURRENT_DATE=$(date -u +"%b %d %T %Y %Z")
      
#       # Calculate the number of hours between END_DATE and CURRENT_DATE
#       HOURS=$(( ( $(date -d "$END_DATE" +%s) - $(date -d "$CURRENT_DATE" +%s) ) / 3600 ))

#       echo $HOURS > "${var.key_protect_path}/cert_validation_hours.txt"
      
#       # Extract the certificate part from the file and save it
#       awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "${var.key_protect_path}/Key_Protect_Server.cert" > "${var.key_protect_path}/Key_Protect_Server_CA.cert"
#       awk '/-----BEGIN CERTIFICATE-----/{x="${var.key_protect_path}/Key_Protect_Server.chain"i".cert";i++} {print > x}' "${var.key_protect_path}/Key_Protect_Server_CA.cert"
      
#       # Rename the file
#       mv "${var.key_protect_path}/Key_Protect_Server.chain.cert" "${var.key_protect_path}/Key_Protect_Server.chain0.cert"
#     EOT
#   }
# }

# # External data source to read the hours.txt file
# data "local_file" "hours" {
#   filename = "${var.key_protect_path}/cert_validation_hours.txt"
#   depends_on = [ null_resource.openssl_commands ]
# }

# resource "tls_private_key" "example" {
#   algorithm = "RSA"
#   rsa_bits  = 2048
# }

# resource "tls_cert_request" "example" {
#   private_key_pem = tls_private_key.example.private_key_pem

#   subject {
#     common_name           = "strgscale.com"
#     organization          = "International Business Machines Corporation"
#     organizational_unit   = "WES"
#     country               = "US"
#     province              = "New York"
#     locality              = "Armonk"
#   }
# }

# # Generate a self-signed certificate
# resource "tls_self_signed_cert" "example" {
#   allowed_uses = [
#     "key_encipherment",
#     "digital_signature",
#     "server_auth",
#   ]

#   private_key_pem = tls_private_key.example.private_key_pem
#   subject {
#     common_name           = "strgscale.com"
#     organization          = "International Business Machines Corporation"
#     organizational_unit   = "WES"
#     country               = "US"
#     province              = "New York"
#     locality              = "Armonk"
#   }

#   validity_period_hours = tonumber(trimspace(data.local_file.hours.content))
#   depends_on = [ data.local_file.hours ]
# }

# # Save the private key to a file
# resource "local_file" "private_key" {
#   content  = tls_private_key.example.private_key_pem
#   filename = "${var.key_protect_path}/${var.resource_prefix}.key"
# }

# # Save the certificate to a file
# resource "local_file" "certificate" {
#   content  = tls_self_signed_cert.example.cert_pem
#   filename = "${var.key_protect_path}/${var.resource_prefix}.cert"
# }

# # Save the CSR to a file
# resource "local_file" "csr" {
#   content  = tls_cert_request.example.cert_request_pem
#   filename = "${var.key_protect_path}/${var.resource_prefix}.csr"
# }

# ## Key Protect
# resource "ibm_resource_instance" "kms_instance" {
#   name              = format("%s-keyprotect", var.resource_prefix)
#   service           = "kms"
#   plan              = "tiered-pricing"
#   location          = var.vpc_region
#   resource_group_id = var.resource_group_id
#   tags              = var.resource_tags
# }

# resource "ibm_kms_key" "key" {
#   instance_id = ibm_resource_instance.kms_instance.guid
#   key_name       = "key"
#   standard_key   = false
# }

# resource "ibm_kms_kmip_adapter" "myadapter" {
#     instance_id = ibm_resource_instance.kms_instance.guid
#     profile = "native_1.0"
#     profile_data = {
#       "crk_id" = ibm_kms_key.key.key_id
#     }
#     description = "Key Protect adapter"
#     name = format("%s-keyprotect-adapter", var.resource_prefix)
# }

# resource "ibm_kms_kmip_client_cert" "mycert" {
#   instance_id = ibm_resource_instance.kms_instance.guid
#   adapter_id = ibm_kms_kmip_adapter.myadapter.adapter_id
#   certificate = tls_self_signed_cert.example.cert_pem
#   name = format("%s-keyprotect-adapter-cert", var.resource_prefix)
# }