resource "aws_cognito_user_pool" "users" {
  name = "${var.project_name}-user-pool-${random_id.suffix.hex}"

  # Bloquea el registro público (SignUp); solo administradores IAM pueden crear cuentas
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  auto_verified_attributes = ["email"]
}

# 2. App Client para obtener tokens JWT desde AWS CLI o Postman
resource "aws_cognito_user_pool_client" "app_client" {
  name         = "${var.project_name}-client"
  user_pool_id = aws_cognito_user_pool.users.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  generate_secret = false
}
