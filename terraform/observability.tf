# ==============================================================================
# LOGS: grupos creados por Terraform con retención (si los crea Lambda, nunca expiran)
# ==============================================================================
resource "aws_cloudwatch_log_group" "get_upload_url" {
  name              = "/aws/lambda/${local.get_upload_url_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "process_image" {
  name              = "/aws/lambda/${local.process_image_function_name}"
  retention_in_days = var.log_retention_days
}

# ==============================================================================
# ALERTAS: notificación cuando un mensaje agota los reintentos y llega a la DLQ
# ==============================================================================
# Nota: sin cifrado con la clave gestionada aws/sns, porque CloudWatch Alarms no puede
# publicar en temas cifrados con ella (requeriría una CMK con política para
# cloudwatch.amazonaws.com). Las notificaciones no contienen datos sensibles.
resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms-${random_id.suffix.hex}"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == null ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.project_name}-dlq-not-empty-${random_id.suffix.hex}"
  alarm_description   = "Hay imágenes que fallaron tras 3 reintentos y están en la DLQ"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}
