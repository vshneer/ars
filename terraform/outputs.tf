output "instance_id" {
  value = aws_instance.this.id
}

output "public_ip" {
  value = aws_instance.this.public_ip
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "ssh_command" {
  value = "ssh -i <your-private-key> ubuntu@${aws_instance.this.public_ip}"
}
