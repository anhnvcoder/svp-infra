# Validation rules of the module's variables: one plan per rule with a value that only that rule rejects; then the
# bastion with the values of the prd root, with an assertion per protection. The AWS provider is a mock: nothing
# reaches an account, and the AMI parameter returns the value below.

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }
}

variables {
  name                  = "svp-prd"
  account_id            = "222222222222"
  region                = "ap-southeast-1"
  aws_profile           = "anhnv-prd"
  vpc_id                = "vpc-0123456789abcdef0"
  subnet_id             = "subnet-0aaaaaaaaaaaaaaa1"
  cluster_name          = "svp-prd"
  cluster_endpoint      = "https://0123456789ABCDEF0123456789ABCDEF.gr7.ap-southeast-1.eks.amazonaws.com"
  api_security_group_id = "sg-0123456789abcdef0"
}

run "name_uppercase" {
  command = plan

  variables {
    name = "Svp-prd"
  }

  expect_failures = [var.name]
}

run "account_id_short" {
  command = plan

  variables {
    account_id = "22222222222"
  }

  expect_failures = [var.account_id]
}

run "region_without_number" {
  command = plan

  variables {
    region = "ap-southeast"
  }

  expect_failures = [var.region]
}

run "aws_profile_with_space" {
  command = plan

  variables {
    aws_profile = "anhnv prd"
  }

  expect_failures = [var.aws_profile]
}

run "vpc_id_not_an_id" {
  command = plan

  variables {
    vpc_id = "svp-prd-vpc"
  }

  expect_failures = [var.vpc_id]
}

run "subnet_id_given_a_vpc_id" {
  command = plan

  variables {
    subnet_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [var.subnet_id]
}

run "cluster_endpoint_with_path" {
  command = plan

  variables {
    cluster_endpoint = "https://example.eks.amazonaws.com/api"
  }

  expect_failures = [var.cluster_endpoint]
}

run "local_port_privileged" {
  command = plan

  variables {
    local_port = 443
  }

  expect_failures = [var.local_port]
}

run "api_security_group_not_an_id" {
  command = plan

  variables {
    api_security_group_id = "svp-prd-cluster"
  }

  expect_failures = [var.api_security_group_id]
}

# Values of the prd root.
run "prd_values" {
  command = plan

  assert {
    condition     = data.aws_ssm_parameter.ami.name == "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" && aws_instance.this.ami == "ami-0123456789abcdef0"
    error_message = "The instance must run the latest Amazon Linux 2023 image for arm64 from the public SSM parameter."
  }

  assert {
    condition     = aws_instance.this.instance_type == "t4g.nano" && aws_instance.this.subnet_id == "subnet-0aaaaaaaaaaaaaaa1"
    error_message = "The instance must be a t4g.nano in the given private subnet."
  }

  assert {
    condition     = aws_instance.this.associate_public_ip_address == false
    error_message = "The instance must have no public address."
  }

  assert {
    condition = (aws_instance.this.metadata_options[0].http_endpoint == "enabled" &&
      aws_instance.this.metadata_options[0].http_tokens == "required" &&
    aws_instance.this.metadata_options[0].http_put_response_hop_limit == 1)
    error_message = "The instance must take IMDSv2 only, with a hop limit of 1."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted == true
    error_message = "The root volume must be encrypted."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ssm_core.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "The role must carry AmazonSSMManagedInstanceCore."
  }

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement == [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
    error_message = "Only EC2 may assume the role."
  }

  assert {
    condition = (aws_vpc_security_group_egress_rule.https.ip_protocol == "tcp" &&
      aws_vpc_security_group_egress_rule.https.from_port == 443 &&
    aws_vpc_security_group_egress_rule.https.to_port == 443)
    error_message = "The instance may go out on TCP 443 only."
  }

  assert {
    condition = (aws_vpc_security_group_ingress_rule.api_from_bastion.security_group_id == "sg-0123456789abcdef0" &&
      aws_vpc_security_group_ingress_rule.api_from_bastion.ip_protocol == "tcp" &&
      aws_vpc_security_group_ingress_rule.api_from_bastion.from_port == 443 &&
      aws_vpc_security_group_ingress_rule.api_from_bastion.to_port == 443 &&
    aws_vpc_security_group_ingress_rule.api_from_bastion.cidr_ipv4 == null)
    error_message = "The API's security group must let in TCP 443 from the bastion's security group, not from an address range."
  }

  assert {
    condition     = jsondecode(local.tunnel_parameters) == { host = ["0123456789ABCDEF0123456789ABCDEF.gr7.ap-southeast-1.eks.amazonaws.com"], portNumber = ["443"], localPortNumber = ["6443"] }
    error_message = "The tunnel must forward 127.0.0.1:6443 to the endpoint's host on 443."
  }

  # The test guard refuses any line with the word of the update-kubeconfig flag that names the context, so the command
  # is checked by its start (the cluster and region) and its end (the entry update-kubeconfig wrote, on the tunnel).
  assert {
    condition = (startswith(output.kubeconfig_command, "AWS_PROFILE=anhnv-prd aws eks update-kubeconfig --region ap-southeast-1 --name svp-prd ") &&
    endswith(output.kubeconfig_command, " && kubectl config set-cluster arn:aws:eks:ap-southeast-1:222222222222:cluster/svp-prd --server=https://127.0.0.1:6443 --tls-server-name=0123456789ABCDEF0123456789ABCDEF.gr7.ap-southeast-1.eks.amazonaws.com"))
    error_message = "The kubeconfig entry of cluster svp-prd must point at the tunnel and check the endpoint's host."
  }
}
