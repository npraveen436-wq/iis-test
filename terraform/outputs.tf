output "server_details" {
  description = "Details for each server"
  value = {
    for name, inst in aws_instance.test_server :
    name => {
      instance_id  = inst.id
      public_ip    = inst.public_ip
      public_dns   = inst.public_dns
      private_ip   = inst.private_ip
      az           = inst.availability_zone
      browser_url  = "http://${inst.public_ip}"
      rdp_address  = "${inst.public_ip}:3389"
      ssm_command  = "aws ssm start-session --target ${inst.id} --region us-east-1"
    }
  }
}

output "test_urls" {
  description = "Open these in your browser to verify"
  value = [
    for name, inst in aws_instance.test_server :
    "http://${inst.public_ip}  -->  ${name}"
  ]
}
