/*
     Creates specified number of AWS EC2 instance(s).
*/

variable "ami_id" {}
variable "disks" {}
variable "ebs_optimized" {}
variable "forward_dns_zone" {}
variable "iam_instance_profile" {}
variable "instance_type" {}
variable "is_nitro_instance" {}
variable "meta_private_key" {}
variable "meta_public_key" {}
variable "name_prefix" {}
variable "placement_group" {}
variable "reverse_dns_domain" {}
variable "reverse_dns_zone" {}
variable "root_device_encrypted" {}
variable "root_device_kms_key_id" {}
variable "root_volume_type" {}
variable "security_groups" {}
variable "subnet_id" {}
variable "tags" {}
variable "user_public_key" {}
variable "volume_tags" {}
variable "zone" {}
variable "dns_domain" {}

data "template_file" "user_data" {
  template = <<EOF
#!/usr/bin/env bash
echo "${var.meta_private_key}" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
echo "${var.meta_public_key}" >> ~/.ssh/authorized_keys
echo "StrictHostKeyChecking no" >> ~/.ssh/config
# Hostname settings
hostnamectl set-hostname --static "${var.name_prefix}.${var.dns_domain}"
echo 'preserve_hostname: True' > /etc/cloud/cloud.cfg.d/10_hostname.cfg
echo "${var.name_prefix}.${var.dns_domain}" > /etc/hostname
EOF
}

data "template_cloudinit_config" "user_data64" {
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/x-shellscript"
    content      = data.template_file.user_data.rendered
  }
}

data "template_file" "nvme_alias" {
  count    = tobool(var.is_nitro_instance) == true ? 1 : 0
  template = <<EOF
#!/usr/bin/env bash
if [ ! -d "/var/mmfs/etc" ]; then
   mkdir -p "/var/mmfs/etc"
fi
echo "#!/bin/ksh" > "/var/mmfs/etc/nsddevices"
echo "# Generated by IBM Storage Scale deployment." >> "/var/mmfs/etc/nsddevices"
%{for i in range(1, 17)~}
echo "echo \"/dev/nvme${i}n1 generic\"" >> "/var/mmfs/etc/nsddevices"
%{endfor~}
echo "# Bypass the NSD device discovery" >> "/var/mmfs/etc/nsddevices"
echo "return 0" >> "/var/mmfs/etc/nsddevices"
chmod u+x "/var/mmfs/etc/nsddevices"
EOF
}

data "template_cloudinit_config" "nvme_user_data64" {
  count         = tobool(var.is_nitro_instance) == true ? 1 : 0
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/x-shellscript"
    content      = data.template_file.user_data.rendered
  }
  part {
    content_type = "text/x-shellscript"
    content      = data.template_file.nvme_alias[0].rendered
  }
}

data "aws_kms_key" "itself" {
  count  = var.root_device_kms_key_id != null ? 1 : 0
  key_id = var.root_device_kms_key_id
}

# Create the EC2 instance
resource "aws_instance" "itself" {
  ami             = var.ami_id
  instance_type   = var.instance_type
  key_name        = var.user_public_key
  security_groups = var.security_groups
  subnet_id       = var.subnet_id

  # Only include iam_instance_profile if var.iam_instance_profile is a non-empty string
  # otherwise, skip the parameter entirely
  iam_instance_profile = var.iam_instance_profile != "" ? var.iam_instance_profile : null

  placement_group = var.placement_group
  ebs_optimized   = tobool(var.ebs_optimized)

  root_block_device {
    encrypted             = var.root_device_encrypted ? true : null
    kms_key_id            = try(data.aws_kms_key.itself[0].key_id, null)
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  user_data_base64 = tobool(var.is_nitro_instance) == true ? data.template_cloudinit_config.nvme_user_data64[0].rendered : data.template_cloudinit_config.user_data64.rendered
  tags             = merge({ "Name" = var.name_prefix }, var.tags)

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  lifecycle {
    ignore_changes = all
  }
}

data "aws_kms_key" "data_device_kms_key" {
  for_each = { for disk_key, disk_config in var.disks : disk_key => disk_config["kms_key"] if disk_config["kms_key"] != null }
  key_id   = each.value
}

# Create the specified volumes with the corresponding types and size
resource "aws_ebs_volume" "itself" {
  for_each          = var.disks
  availability_zone = var.zone
  size              = each.value["size"]
  type              = each.value["type"]
  iops              = each.value["iops"] == "" ? null : each.value["iops"]
  throughput        = each.value["throughput"] == "" ? null : each.value["throughput"]
  encrypted         = each.value["encrypted"]
  kms_key_id        = each.value["encrypted"] ? try(data.aws_kms_key.data_device_kms_key[each.key].arn, null) : null
  tags = merge(
    {
      "Name" = format("%s-%s", var.name_prefix, each.key)
    },
    var.volume_tags,
  )
}

# Create "A" (IPv4 Address) record to map IPv4 address as hostname along with domain
resource "aws_route53_record" "a_itself" {
  zone_id = var.forward_dns_zone
  type    = "A"
  name    = var.name_prefix
  records = [aws_instance.itself.private_ip]
  ttl     = 360
}

# Create "PTR" (Pointer) to enables reverse DNS lookup, from an IP address to a hostname
resource "aws_route53_record" "ptr_itself" {
  zone_id = var.reverse_dns_zone
  type    = "PTR"
  name    = format("%s.%s.%s.%s", split(".", aws_instance.itself.private_ip)[3], split(".", aws_instance.itself.private_ip)[2], split(".", aws_instance.itself.private_ip)[1], var.reverse_dns_domain)
  records = [format("%s.%s", var.name_prefix, var.dns_domain)]
  ttl     = 360
}

# Attach the volumes to provisioned instance
resource "aws_volume_attachment" "itself" {
  for_each     = aws_ebs_volume.itself
  device_name  = var.disks[each.key]["device_name"]
  volume_id    = aws_ebs_volume.itself[each.key].id
  instance_id  = aws_instance.itself.id
  skip_destroy = var.disks[each.key]["termination"]
}

output "instance_private_ips" {
  value = aws_instance.itself.private_ip
}

output "instance_ids" {
  value = aws_instance.itself.id
}

output "instance_private_dns_name" {
  value = aws_instance.itself.private_dns
}
