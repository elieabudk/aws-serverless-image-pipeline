# 1. Instalar dependencias de Lambda 1 automáticamente antes de empaquetar
resource "null_resource" "install_get_upload_url_deps" {
  triggers = {
    package_json = filesha256("${path.module}/../src/get-upload-url/package.json")
  }

  provisioner "local-exec" {
    command     = "npm install --omit=dev"
    working_dir = "${path.module}/../src/get-upload-url"
  }
}

# 2. Instalar dependencias de Lambda 2 (incluyendo Jimp) automáticamente antes de empaquetar
resource "null_resource" "install_process_image_deps" {
  triggers = {
    package_json = filesha256("${path.module}/../src/process-image/package.json")
  }

  provisioner "local-exec" {
    command     = "npm install --omit=dev"
    working_dir = "${path.module}/../src/process-image"
  }
}

# 3. Empaquetado automático de Lambda 1 (espera a que termine npm install)
data "archive_file" "get_upload_url_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/get-upload-url"
  output_path = "${path.module}/get-upload-url.zip"

  depends_on = [null_resource.install_get_upload_url_deps]
}

# 4. Empaquetado automático de Lambda 2 con node_modules (espera a que termine npm install)
data "archive_file" "process_image_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/process-image"
  output_path = "${path.module}/process-image.zip"

  depends_on = [null_resource.install_process_image_deps]
}


# ==============================================================================
# LAMBDA 1: get-upload-url
# ==============================================================================
locals {
  get_upload_url_function_name = "${var.project_name}-get-upload-url-${random_id.suffix.hex}"
  process_image_function_name  = "${var.project_name}-process-image-${random_id.suffix.hex}"
}

resource "aws_lambda_function" "get_upload_url" {
  function_name    = local.get_upload_url_function_name
  role             = aws_iam_role.lambda_get_url.arn
  handler          = "index.handler"
  runtime          = "nodejs24.x"
  filename         = data.archive_file.get_upload_url_zip.output_path
  source_code_hash = data.archive_file.get_upload_url_zip.output_base64sha256
  timeout          = 10
  memory_size      = 256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      SOURCE_BUCKET = aws_s3_bucket.source.id
      TABLE_NAME    = aws_dynamodb_table.images.name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_get_url_vpc,
    aws_cloudwatch_log_group.get_upload_url,
  ]
}

# ==============================================================================
# LAMBDA 2: process-image
# ==============================================================================
resource "aws_lambda_function" "process_image" {
  function_name    = local.process_image_function_name
  role             = aws_iam_role.lambda_process_image.arn
  handler          = "index.handler"
  runtime          = "nodejs24.x"
  filename         = data.archive_file.process_image_zip.output_path
  source_code_hash = data.archive_file.process_image_zip.output_base64sha256
  timeout          = 30  # visibility_timeout_seconds de SQS debe ser >= 6x este valor (180s)
  memory_size      = 512 # Más memoria = más CPU para procesar imágenes rápido con Jimp

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      DESTINATION_BUCKET = aws_s3_bucket.destination.id
      TABLE_NAME         = aws_dynamodb_table.images.name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_process_image_vpc,
    aws_cloudwatch_log_group.process_image,
  ]
}

# Disparador SQS -> Lambda 2 (Paso 9 del diagrama)
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.main.arn
  function_name    = aws_lambda_function.process_image.arn
  batch_size       = 1
  enabled          = true
}
