terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
  /* profile = "cw-training" */
}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {
  name = "us-east-1"
}
locals {
  github-repo     = "https://github.com/kapazan/204-docker-swarm-deployment-of-phonebook-app-on-python-flask-mysql-Terraform.git"
  github-file-url = "https://raw.githubusercontent.com/kapazan/204-docker-swarm-deployment-of-phonebook-app-on-python-flask-mysql-Terraform/main/"
}
data "template_file" "leader-master" {
  template = <<-EOF
    #! /bin/bash
    dnf update -y
    hostnamectl set-hostname Leader-Manager
    dnf install docker -y
    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ec2-user
    curl -SL https://github.com/docker/compose/releases/download/v2.17.3/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    docker swarm init
    aws ecr get-login-password --region ${data.aws_region.current.name} | docker login --username AWS --password-stdin ${aws_ecr_repository.ecr-repo.repository_url}
    docker service create \
      --name=viz \
      --publish=8080:8080/tcp \
      --constraint=node.role==manager \
      --mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
      dockersamples/visualizer
    dnf install git -y
    docker build --force-rm -t "${aws_ecr_repository.ecr-repo.repository_url}:latest" ${local.github-repo}#main
    docker push "${aws_ecr_repository.ecr-repo.repository_url}:latest"
    mkdir -p /home/ec2-user/phonebook && cd /home/ec2-user/phonebook
    curl -o "docker-compose.yml" -L ${local.github-file-url}docker-compose.yaml
    curl -o "init.sql" -L ${local.github-file-url}init.sql
    sed -i "s|phonebook_image|${aws_ecr_repository.ecr-repo.repository_url}|" /home/ec2-user/phonebook/docker-compose.yml
    docker stack deploy --with-registry-auth -c docker-compose.yml phonebook
  EOF
}
data "template_file" "manager" {
  template = <<-EOF
    #! /bin/bash
    dnf update -y
    hostnamectl set-hostname Manager
    dnf install docker -y
    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ec2-user
    curl -SL https://github.com/docker/compose/releases/download/v2.17.3/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    aws ec2 wait instance-status-ok --instance-ids ${aws_instance.docker-machine-leader-manager.id}
    ssh-keygen -t rsa -f /home/ec2-user/clarus_key -q -N ""
    aws ec2-instance-connect send-ssh-public-key --region ${data.aws_region.current.name} --instance-id ${aws_instance.docker-machine-leader-manager.id} --instance-os-user ec2-user --ssh-public-key file:///home/ec2-user/clarus_key.pub \
    && eval "$(ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  \
    -i /home/ec2-user/clarus_key ec2-user@${aws_instance.docker-machine-leader-manager.private_ip} docker swarm join-token manager | grep -i 'docker')"
  EOF
}
data "template_file" "worker" {
  template = <<-EOF
    #! /bin/bash
    dnf update -y
    hostnamectl set-hostname Worker
    dnf install docker -y
    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ec2-user
    curl -SL https://github.com/docker/compose/releases/download/v2.17.3/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    aws ec2 wait instance-status-ok --instance-ids ${aws_instance.docker-machine-leader-manager.id}
    ssh-keygen -t rsa -f /home/ec2-user/clarus_key -q -N ""
    aws ec2-instance-connect send-ssh-public-key --region ${data.aws_region.current.name} --instance-id ${aws_instance.docker-machine-leader-manager.id} --instance-os-user ec2-user --ssh-public-key file:///home/ec2-user/clarus_key.pub \
    && eval "$(ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  \
    -i /home/ec2-user/clarus_key ec2-user@${aws_instance.docker-machine-leader-manager.private_ip} docker swarm join-token worker | grep -i 'docker')"
  EOF
}
resource "aws_ecr_repository" "ecr-repo" {
  name                 = "clarusway-repo/phonebook-app"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = false
  }
  force_delete = true
}
variable "myami" {
  default = "ami-06b09bfacae1453cb"
}
variable "instancetype" {
  default = "t2.micro"
}
variable "mykey" {
  default = "mykey"
}
resource "aws_instance" "docker-machine-leader-manager" {
  ami           = var.myami
  instance_type = var.instancetype
  key_name      = var.mykey
  root_block_device {
    volume_size = 16
  }
  vpc_security_group_ids = [aws_security_group.tf-docker-sec-gr.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2ecr-profile.name
  user_data              = data.template_file.leader-master.rendered
  tags = {
    Name = "Docker-Swarm-Leader-Manager"
  }
}
resource "aws_instance" "docker-machine-managers" {
  ami                    = var.myami
  instance_type          = var.instancetype
  key_name               = var.mykey
  vpc_security_group_ids = [aws_security_group.tf-docker-sec-gr.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2ecr-profile.name
  count                  = 2
  user_data              = data.template_file.manager.rendered
  tags = {
    Name = "Docker-Swarm-Manager-${count.index + 1}"
  }
  depends_on = [aws_instance.docker-machine-leader-manager]
}
resource "aws_instance" "docker-machine-workers" {
  ami                    = var.myami
  instance_type          = var.instancetype
  key_name               = var.mykey
  vpc_security_group_ids = [aws_security_group.tf-docker-sec-gr.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2ecr-profile.name
  count                  = 2
  user_data              = data.template_file.worker.rendered
  tags = {
    Name = "Docker-Swarm-Worker-${count.index + 1}"
  }
  depends_on = [aws_instance.docker-machine-leader-manager]
}
variable "sg-ports" {
  default = [80, 22, 2377, 7946, 8080]
}
resource "aws_security_group" "tf-docker-sec-gr" {
  name = "docker-swarm-sec-gr-204"
  tags = {
    Name = "swarm-sec-gr"
  }
  dynamic "ingress" {
    for_each = var.sg-ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  ingress {
    from_port   = 7946
    protocol    = "udp"
    to_port     = 7946
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 4789
    protocol    = "udp"
    to_port     = 4789
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    protocol    = "-1"
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_iam_instance_profile" "ec2ecr-profile" {
  name = "swarmprofile204"
  role = aws_iam_role.ec2fulltoecr.name
}
resource "aws_iam_role" "ec2fulltoecr" {
  name = "ec2roletoecrproject"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
  inline_policy {
    name = "my_inline_policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          "Effect" : "Allow",
          "Action" : "ec2-instance-connect:SendSSHPublicKey",
          "Resource" : "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
          "Condition" : {
            "StringEquals" : {
              "ec2:osuser" : "ec2-user"
            }
          }
        },
        {
          "Effect" : "Allow",
          "Action" : "ec2:DescribeInstances",
          "Resource" : "*"
        },
        {
          "Effect" : "Allow",
          "Action" : "ec2:DescribeInstanceStatus",
          "Resource" : "*"
        }
      ]
    })
  }
  managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"]
}
output "leader-manager-public-ip" {
  value = aws_instance.docker-machine-leader-manager.public_ip
}
output "website-url" {
  value = "http://${aws_instance.docker-machine-leader-manager.public_ip}"
}
output "viz-url" {
  value = "http://${aws_instance.docker-machine-leader-manager.public_ip}:8080"
}
output "manager-public-ip" {
  value = aws_instance.docker-machine-managers.*.public_ip
}
output "worker-public-ip" {
  value = aws_instance.docker-machine-workers.*.public_ip
}
output "ecr-repo-url" {
  value = aws_ecr_repository.ecr-repo.repository_url
}