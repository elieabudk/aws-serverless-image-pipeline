# 1. Bucket S3 de Origen (Entrada de imágenes originales)
resource "aws_s3_bucket" "source" {
  bucket        = "${var.project_name}-source-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Denegar cualquier petición sin cifrado HTTPS (TLS) al Bucket Origen
resource "aws_s3_bucket_policy" "source_tls_only" {
  bucket = aws_s3_bucket.source.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLSRequestsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.source.arn,
          "${aws_s3_bucket.source.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# 2. Bucket S3 de Destino (Almacenamiento de miniaturas procesadas)
resource "aws_s3_bucket" "destination" {
  bucket        = "${var.project_name}-dest-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "destination" {
  bucket                  = aws_s3_bucket.destination.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "destination" {
  bucket = aws_s3_bucket.destination.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "destination_tls_only" {
  bucket = aws_s3_bucket.destination.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLSRequestsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.destination.arn,
          "${aws_s3_bucket.destination.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        # Las miniaturas solo pueden escribirse desde la VPC privada (vía Gateway Endpoint)
        Sid       = "DenyThumbnailWritesOutsideVpcEndpoint"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.destination.arn}/thumbnails/*"
        Condition = {
          StringNotEquals = {
            "aws:SourceVpce" = aws_vpc_endpoint.s3.id
          }
        }
      }
    ]
  })
}

# 3. Tabla DynamoDB (Modo On-Demand / Pago por petición + Cifrado en reposo)
resource "aws_dynamodb_table" "images" {
  name         = "${var.project_name}-metadata-${random_id.suffix.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "imageId"

  attribute {
    name = "imageId"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  # TTL: los registros que nunca se completan (subida abandonada, REJECTED o fallo en DLQ)
  # se borran solos. Lambda 1 escribe expiresAt; Lambda 2 lo elimina al pasar a COMPLETED.
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
}

# Ciclo de vida del bucket origen: los originales solo se necesitan para generar la miniatura
resource "aws_s3_bucket_lifecycle_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    id     = "expire-original-uploads"
    status = "Enabled"

    filter {
      prefix = "uploads/"
    }

    expiration {
      days = var.source_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
