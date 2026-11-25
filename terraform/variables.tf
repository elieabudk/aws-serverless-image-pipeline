variable "aws_region" {
  description = "Región de AWS en Europa donde se desplegará la infraestructura"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Nombre base del proyecto para etiquetado y nombrado de recursos"
  type        = string
  default     = "img-pipeline"
}

variable "environment" {
  description = "Entorno de despliegue"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "Bloque CIDR para la VPC personalizada aislada"
  type        = string
  default     = "10.0.0.0/16"
}

variable "source_retention_days" {
  description = "Días que se conservan las imágenes originales en el bucket origen antes de expirar"
  type        = number
  default     = 7
}

variable "log_retention_days" {
  description = "Días de retención de los logs de las Lambdas en CloudWatch"
  type        = number
  default     = 14
}

variable "alarm_email" {
  description = "Email que recibe las alarmas (opcional; requiere confirmar la suscripción SNS)"
  type        = string
  default     = null
}
