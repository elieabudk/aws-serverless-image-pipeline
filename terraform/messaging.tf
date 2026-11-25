# 1. Dead Letter Queue (DLQ) para mensajes que fallen tras 3 intentos
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-dlq-${random_id.suffix.hex}"
  message_retention_seconds = 1209600 # 14 días de retención para auditoría
  sqs_managed_sse_enabled   = true
}

# 2. Cola Principal SQS conectada a la DLQ
resource "aws_sqs_queue" "main" {
  name                       = "${var.project_name}-queue-${random_id.suffix.hex}"
  visibility_timeout_seconds = 180 # AWS recomienda >= 6x el timeout de Lambda 2 (6 x 30s)
  message_retention_seconds  = 86400
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# 3. Política de SQS que autoriza únicamente a nuestro Bucket Origen a enviar mensajes
resource "aws_sqs_queue_policy" "allow_s3_publish" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3SourceBucketToSendMessage"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.main.arn
        # SourceArn + SourceAccount: los nombres de bucket son globales, así que se fija
        # también la cuenta propietaria (protección "confused deputy" recomendada por AWS)
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.source.arn
          }
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# 4. Notificación de Evento de S3 -> SQS (Paso 8 del diagrama)
resource "aws_s3_bucket_notification" "source_to_sqs" {
  bucket = aws_s3_bucket.source.id

  queue {
    queue_arn     = aws_sqs_queue.main.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
  }

  depends_on = [aws_sqs_queue_policy.allow_s3_publish]
}
