data "aws_availability_zones""available"{
    state = "available"
}

data "aws_ami" "amzn_linux_2023_latest" {
  most_recent = true
  owners      = ["amazon"] 

  filter {
    name   = "name"
    values = ["al2023-ami-2023*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"] 
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc""main"{
    cidr_block          = "192.168.0.0/16"
    enable_dns_support = true
    enable_dns_hostnames = true

    tags = {
        Name = "my-awesome-project-vpc"
    }
}



resource "aws_subnet""public"{
    count               = 2
    vpc_id              = aws_vpc.main.id
    cidr_block          = cidrsubnet ("192.168.0.0/16",8,count.index)
    availability_zone   = data.aws_availability_zones.available.names[count.index]
    map_public_ip_on_launch = true
}

resource "aws_subnet""private"{
    count               = 2
    vpc_id              = aws_vpc.main.id
    cidr_block          = cidrsubnet ("192.168.0.0/16",8,count.index)
    availability_zone   = data.aws_availability_zones.available.names[count.index]
}


resource "aws_internet_gateway""igw"{

    vpc_id = aws_vpc.main.id
}

resource "aws_eip""nat"{
    domain = "vpc"
}


resource "aws_nat_gateway""nat"{
    allocation_id= aws_eip.nat.id
    subnet_id = aws_subnet.public[0].id

    tags = {
        Name = "nat-gateway"
    }

    depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table""public"{
    vpc_id = aws_vpc.main.id

    route{
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.igw.id
    }
}

resource "aws_route_table""private"{
    vpc_id = aws_vpc.main.id

    route{
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_nat_gateway.nat.id
    }
}

resource "aws_route_table_association""public_assoc" {
    count       = 2
    subnet_id   = aws_subnet.public[count.index].id
    route_table_id  =  aws_route_table.public.id
}

resource "aws_route_table_association""private_assoc" {
    count       = 2
    subnet_id   = aws_subnet.private[count.index].id
    route_table_id  =   aws_route_table.private.id

}

resource "aws_security_group""rds_sg"{
    vpc_id = aws_vpc.main.id

    ingress {
        from_port       = 5432
        to_port         = 5432
        protocol        = "tcp"
        cidr_blocks      = ["192.168.0.0/16"]
    }
}

resource "aws_db_subnet_group""rds" {
    subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance""postgres" {
    engine                  = "postgres"
    instance_class          = "db3.t3.micro"
    db_subnet_group_name    = aws_db_subnet_group.rds.name
    vpc_security_group_ids  = [aws_security_group.rds_sg.id]
    publicly_accessible     =  false
}

resource "aws_security_group""alb_sg"{
    vpc_id = aws_vpc.main.id

    ingress {
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        cidr_blocks      = ["0.0.0.0/16"]
    }
    egress {
        from_port       = 80
        to_port         = 80
        protocol        = "-1"
        cidr_blocks      = ["0.0.0.0/16"]
    }
}

resource "aws_security_group""app_sg"{
    vpc_id = aws_vpc.main.id

    ingress {
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        security_groups      = [aws_security_group.alb_sg.id]
    }
    egress {
        from_port       = 0
        to_port         = 0
        protocol        = "-1"
        cidr_blocks      = ["0.0.0.0/16"]
    }
}

locals {
    nginx_user_data = <<-EOF
        #!/bin/bash
        set-eux
        dnf update -y
        dhf install -y nginx
        systemctl enable --now nginx
        echo "Welcome to Trubit" > /usr/share/nginx/html/index.html
        echo "Welcome to Trubit" > /var/www/html/index.html
    EOF
}

resource "aws_launch_template" "web" {
  name_prefix   = "web-lt-"
  image_id      = data.aws_ami.amzn_linux_2023_latest.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data = base64encode(local.nginx_user_data)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "web-asg"
    }
  }
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name    = "web-alb"
  vpc_id  = aws_vpc.main.id
  subnets = aws_subnet.public[*].id

  security_groups = [aws_security_group.alb_sg.id]

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "web"
      }
    }
  }

  target_groups = {
    web = {
      name_prefix      = "web-"
      protocol         = "HTTP"
      port             = 80
      target_type      = "instance"
      create_attachment = false

      health_check = {
        path    = "/"
        matcher = "200"
      }
    }
  }
}

resource "aws_autoscaling_group" "web" {
  name                = "web-asg"
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1
  vpc_zone_identifier = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  target_group_arns = [module.alb.target_groups["web"].arn]

  health_check_type         = "ELB"
  health_check_grace_period = 60

  tag {
    key                 = "Name"
    value               = "web-asg-instance"
    propagate_at_launch = true
  }
}
