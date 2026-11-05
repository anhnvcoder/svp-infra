# A small instance in a private subnet through which the learner's machine reaches the private endpoint of the
# Kubernetes API: AWS Systems Manager Session Manager forwards a local port to the endpoint's host on 443
# (document AWS-StartPortForwardingSessionToRemoteHost). The SSM agent of the instance opens the session outward, to
# the public endpoints of Systems Manager through the NAT gateway, so the instance takes no inbound connection, holds no
# SSH key and has no public address; who may start a session is decided by IAM, and every session start is in
# CloudTrail.
locals {
  # Graviton, the smallest size: the instance only relays the bytes of one tunnel.
  instance_type = "t4g.nano"
  # Latest Amazon Linux 2023 for arm64, as AWS publishes it in a public SSM parameter; the image ships the SSM agent.
  ami_parameter = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
  # Host of the API server: the TLS name the tunnel's client checks, and the remote host of the session.
  api_host = trimprefix(var.cluster_endpoint, "https://")
  # Parameters of the port forwarding session and the kubeconfig command, kept apart from the instance's ID so the
  # tests can read them at plan time.
  tunnel_parameters = jsonencode({
    host            = [local.api_host]
    portNumber      = ["443"]
    localPortNumber = [tostring(var.local_port)]
  })
  kubeconfig_command = join(" ", [
    "AWS_PROFILE=${var.aws_profile} aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name} --alias ${var.cluster_name}",
    "&& kubectl config set-cluster arn:aws:eks:${var.region}:${var.account_id}:cluster/${var.cluster_name}",
    "--server=https://127.0.0.1:${var.local_port} --tls-server-name=${local.api_host}",
  ])
}

data "aws_ssm_parameter" "ami" {
  name = local.ami_parameter
}

################################################################################
# Identity: only what the SSM agent needs
################################################################################

resource "aws_iam_role" "this" {
  name        = "${var.name}-ssm-bastion"
  description = "SSM agent of the bastion of ${var.name}, the tunnel to the private endpoint of the Kubernetes API"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# The managed policy AWS publishes for the SSM agent (register, receive commands, open sessions) and nothing else: the
# instance calls no other AWS API, and Kubernetes never sees this role (the tunnel carries the learner's own token).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-ssm-bastion"
  role = aws_iam_role.this.name
}

################################################################################
# Network: no inbound rule, out on 443 only; the API lets the instance in on 443
################################################################################

# Without an egress block Terraform removes the allow-all egress rule AWS adds to a new security group, so the rule
# below is the only way out. DNS (the VPC resolver), the instance metadata service and time sync go to link-local
# addresses that security groups do not filter.
resource "aws_security_group" "this" {
  name        = "${var.name}-ssm-bastion"
  description = "Bastion of ${var.name}: no inbound, HTTPS out to Systems Manager and the Kubernetes API"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-ssm-bastion"
  }
}

# AWS-0104: HTTPS to any address. The agent reaches the public endpoints of Systems Manager (ssm, ssmmessages,
# ec2messages) through the NAT gateway, and AWS publishes no prefix list for them; interface endpoints of those three
# services would keep the traffic inside the VPC, at an hourly fee per service and per zone. 443 is the only port open
# either way, and the tunnel's target is the API's private endpoint inside the VPC.
# Scope: every environment.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS to Systems Manager (through the NAT gateway) and to the Kubernetes API"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "api_from_bastion" {
  security_group_id            = var.api_security_group_id
  description                  = "Kubernetes API from the SSM bastion (tunnel from the learner machine)"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.this.id
}

################################################################################
# Instance
################################################################################

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = local.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  # IMDSv2 only, one hop: a process on the instance gets the role's credentials only with a session token, and nothing
  # behind it (a container) reaches the metadata service.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.name}-ssm-bastion"
  }
}
