output "instance_id" {
  description = "ID of the instance, the --target of an SSM session."
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Security group of the instance, which the API's security group lets in on 443."
  value       = aws_security_group.this.id
}

output "tunnel_command" {
  description = "Command that opens the tunnel: 127.0.0.1:<local_port> of the learner's machine to the private endpoint of the Kubernetes API on 443, until it is stopped (Ctrl-C). Needs the Session Manager plugin of the AWS CLI."
  value = join(" ", [
    "AWS_PROFILE=${var.aws_profile} aws ssm start-session --region ${var.region}",
    "--target ${aws_instance.this.id}",
    "--document-name AWS-StartPortForwardingSessionToRemoteHost",
    "--parameters '${local.tunnel_parameters}'",
  ])
}

# update-kubeconfig names the cluster entry after the cluster's ARN and points it at the endpoint; set-cluster then
# points that entry at the tunnel and keeps checking the server certificate against the endpoint's host, which the
# certificate of the API server names.
output "kubeconfig_command" {
  description = "Command that adds the cluster to the kubeconfig under the context <cluster_name>, served through the tunnel on 127.0.0.1:<local_port> with the endpoint's host as TLS server name. Run it with eval; kubectl works while tunnel_command runs."
  value       = local.kubeconfig_command
}
