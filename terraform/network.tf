# Obtener dinámicamente las Zonas de Disponibilidad disponibles en eu-west-1
data "aws_availability_zones" "available" {
  state = "available"
}

# 1. VPC Personalizada (Sin salida a Internet)
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# 2. Dos Subredes Privadas en distintas Zonas de Disponibilidad (Alta Disponibilidad)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1) # 10.0.1.0/24 y 10.0.2.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
  }
}

# 3. Tabla de Enrutamiento Privada (Sin ruta 0.0.0.0/0 hacia internet)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# 4. VPC Gateway Endpoint para Amazon S3 (Gratuito y privado)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  # Política del endpoint: desde la VPC solo se puede leer del bucket origen y escribir
  # en el bucket destino. Bloquea la exfiltración hacia cualquier otro bucket de S3.
  # (La Lambda 1 no usa S3 por red: el Presigned POST se firma localmente.)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowReadOriginalsFromSourceBucket"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject"]
        Resource  = "${aws_s3_bucket.source.arn}/uploads/*"
      },
      {
        Sid       = "AllowWriteThumbnailsToDestinationBucket"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:PutObject"]
        Resource  = "${aws_s3_bucket.destination.arn}/thumbnails/*"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-s3-gateway-endpoint"
  }
}

# 5. VPC Gateway Endpoint para Amazon DynamoDB (Gratuito y privado)
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  # Política del endpoint: solo las operaciones que usa el pipeline y solo sobre nuestra tabla
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowPipelineTableOperations"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource  = aws_dynamodb_table.images.arn
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-dynamodb-gateway-endpoint"
  }
}

resource "aws_security_group" "lambda_sg" {
  name        = "${var.project_name}-lambda-sg"
  description = "Security Group para Lambdas dentro de subredes privadas"
  vpc_id      = aws_vpc.main.id

  # 1. Resolución DNS interna (AmazonProvidedDNS en VPC+2)
  egress {
    description = "Salida DNS UDP hacia Route 53 Resolver (VPC+2)"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(var.vpc_cidr, 2)}/32"]
  }

  egress {
    description = "Salida DNS TCP hacia Route 53 Resolver (VPC+2)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(var.vpc_cidr, 2)}/32"]
  }

  # 2. Tráfico HTTPS privado hacia S3 y DynamoDB (Gateway Endpoints)
  egress {
    description = "Salida HTTPS privada hacia VPC Gateway Endpoints (S3 y DynamoDB)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    prefix_list_ids = [
      aws_vpc_endpoint.s3.prefix_list_id,
      aws_vpc_endpoint.dynamodb.prefix_list_id
    ]
  }

  tags = {
    Name = "${var.project_name}-lambda-sg"
  }
}

