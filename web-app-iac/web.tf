############################################
# Terraform and AWS provider configuration
############################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

# Configure the AWS provider and choose the region
# where Terraform will create all resources.
provider "aws" {
  region = "us-east-1"
}

############################################
# Existing VPC and subnets
############################################

# Look up the existing VPC by its ID.
# Terraform will use this VPC instead of trying
# to rely on a default VPC.
data "aws_vpc" "default_vpc" {
  default = true
}

# Look up all subnets that belong to the VPC above.
# This replaces the older aws_subnet_ids data source.
data "aws_subnets" "default_public_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default_vpc.id]
  }
}

data "aws_subnet_ids" "default_public_subnet" {
    vpc_id = data.aws_vpc.default_vpc.id
}

############################################
# Security group for EC2 instances
############################################

# This security group acts like a firewall for the EC2 instances.
# It allows HTTP traffic in on port 80 and allows all outbound traffic.
resource "aws_security_group" "instances" {
  name        = "instance-security-group"
  description = "Security group for web instances"
  vpc_id      = data.aws_vpc.default_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow the load balancer health checks and traffic to reach
  # the Python web server running on port 8080.
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic from the instances.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# EC2 instances
############################################

# First EC2 instance that serves a simple web page on port 8080.
# subnet_id places the instance into a subnet in the VPC.
# vpc_security_group_ids attaches the security group by ID.
resource "aws_instance" "instance_1" {
  ami                    = "ami-0b6d9d3d33ba97d99"
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnets.default_public_subnets.ids[0]
  vpc_security_group_ids = [aws_security_group.instances.id]

  user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World 1" > index.html
              nohup python3 -m http.server 8080 &
              EOF

  tags = {
    Name = "web-instance-1"
  }
}

# Second EC2 instance serving a different page on port 8080.
resource "aws_instance" "instance_2" {
  ami                    = "ami-0b6d9d3d33ba97d99"
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnets.default_public_subnets.ids[0]
  vpc_security_group_ids = [aws_security_group.instances.id]

  user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World 2" > index.html
              nohup python3 -m http.server 8080 &
              EOF

  tags = {
    Name = "web-instance-2"
  }
}

############################################
# S3 bucket
############################################

# Create an S3 bucket for application data.
# bucket_prefix lets AWS generate a unique bucket name.
resource "aws_s3_bucket" "bucket" {
  bucket_prefix = "devops-directive-web-app-data-"
  force_destroy = true
}

# Enable versioning so old object versions are kept.
resource "aws_s3_bucket_versioning" "bucket_versioning" {
  bucket = aws_s3_bucket.bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable default server-side encryption for the bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_crypto_conf" {
  bucket = aws_s3_bucket.bucket.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

############################################
# Security group for ALB
############################################

# This security group belongs to the Application Load Balancer.
# It allows HTTP traffic from the internet.
resource "aws_security_group" "alb" {
  name        = "alb-security-group"
  description = "Security group for application load balancer"
  vpc_id      = data.aws_vpc.default_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow the ALB to send traffic out to the EC2 instances.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# Application Load Balancer
############################################

# Create the ALB in the VPC subnets and attach the ALB security group.
resource "aws_lb" "load_balancer" {
  name               = "web-app-lb"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default_public_subnets.ids
  security_groups    = [aws_security_group.alb.id]
}

# Create a target group for the EC2 instances.
# The ALB will forward HTTP traffic to this group on port 8080.
resource "aws_lb_target_group" "instances" {
  name     = "example-target-group"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default_vpc.id

  # Health checks tell the ALB whether the instances are healthy.
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Attach instance 1 to the target group.
resource "aws_lb_target_group_attachment" "instance_1" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_1.id
  port             = 8080
}

# Attach instance 2 to the target group.
resource "aws_lb_target_group_attachment" "instance_2" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_2.id
  port             = 8080
}

# Create an HTTP listener on port 80 for the ALB.
# If no rule matches, it returns a simple 404 response.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.load_balancer.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

# Forward all incoming paths to the EC2 target group.
resource "aws_lb_listener_rule" "instances" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instances.arn
  }
}

############################################
# Route 53 DNS
############################################

# Create a hosted zone for the domain.
# This only creates the zone in Route 53; you still need to update
# your registrar nameservers if the domain is registered elsewhere.
resource "aws_route53_zone" "primary" {
  name = "devopsdeployed.com"
}

# Create an alias A record so the root domain points to the ALB.
resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "devopsdeployed.com"
  type    = "A"

  alias {
    name                   = aws_lb.load_balancer.dns_name
    zone_id                = aws_lb.load_balancer.zone_id
    evaluate_target_health = true
  }
}