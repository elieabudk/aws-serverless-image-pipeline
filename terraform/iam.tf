# Política de confianza común para que el servicio AWS Lambda asuma los roles
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ==============================================================================
# IAM PARA LAMBDA 1: get-upload-url (Solo firma subida en S3 Origen y crea item en DynamoDB)
# ==============================================================================
resource "aws_iam_role" "lambda_get_url" {
  name               = "${var.project_name}-get-url-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Permiso para operar dentro de la VPC (ENIs) y escribir en CloudWatch Logs
resource "aws_iam_role_policy_attachment" "lambda_get_url_vpc" {
  role       = aws_iam_role.lambda_get_url.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_get_url_least_privilege" {
  name = "${var.project_name}-get-url-policy"
  role = aws_iam_role.lambda_get_url.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowPutObjectOnlyInUploadsPrefix"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.source.arn}/uploads/*"
      },
      {
        Sid      = "AllowPutItemInDynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.images.arn
      }
    ]
  })
}

# ==============================================================================
# IAM PARA LAMBDA 2: process-image (Lee SQS, lee S3 Origen, escribe S3 Destino y actualiza DynamoDB)
# ==============================================================================
resource "aws_iam_role" "lambda_process_image" {
  name               = "${var.project_name}-process-img-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_process_image_vpc" {
  role       = aws_iam_role.lambda_process_image.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_process_image_least_privilege" {
  name = "${var.project_name}-process-img-policy"
  role = aws_iam_role.lambda_process_image.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.main.arn
      },
      {
        Sid      = "AllowReadFromSourceBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.source.arn}/uploads/*"
      },
      {
        Sid      = "AllowWriteToDestinationBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.destination.arn}/thumbnails/*"
      },
      {
        Sid      = "AllowUpdateItemInDynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.images.arn
      }
    ]
  })
}
