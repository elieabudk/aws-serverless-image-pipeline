output "api_upload_endpoint" {
  description = "URL completa para hacer POST desde Postman (Paso 3)"
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/upload"
}

output "source_bucket_name" {
  description = "Nombre del bucket S3 de origen"
  value       = aws_s3_bucket.source.id
}

output "destination_bucket_name" {
  description = "Nombre del bucket S3 de destino (miniaturas)"
  value       = aws_s3_bucket.destination.id
}

output "dynamodb_table_name" {
  description = "Nombre de la tabla DynamoDB"
  value       = aws_dynamodb_table.images.name
}

output "sqs_dlq_url" {
  description = "URL de la Dead Letter Queue (DLQ) para auditoría de errores"
  value       = aws_sqs_queue.dlq.id
}

output "alarms_sns_topic_arn" {
  description = "Tema SNS que recibe las alarmas (DLQ con mensajes)"
  value       = aws_sns_topic.alarms.arn
}

output "cognito_user_pool_id" {
  description = "ID del User Pool de Cognito"
  value       = aws_cognito_user_pool.users.id
}

output "cognito_client_id" {
  description = "ID del App Client de Cognito"
  value       = aws_cognito_user_pool_client.app_client.id
}
