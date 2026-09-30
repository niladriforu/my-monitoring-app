variable "region" {
  type        = string
  description = "AWS region that receives the AM snapshot."
  default     = "us-east-1"
}

variable "name" {
  type        = string
  description = "Prefix for the data bucket and DynamoDB tables."
  default     = "am"
}
