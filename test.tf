terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_instance" "example" {
  ami           = "ami-0b6d9d3d33ba97d99" # Ubuntu 20.04 LTS // us-east-1
  instance_type = "t3.micro"
  subnet_id = "subnet-02b1eba876800c16b"
}