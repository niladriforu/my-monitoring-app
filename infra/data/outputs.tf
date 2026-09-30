output "bucket" {
  description = "Private bucket holding the JSON snapshot."
  value       = aws_s3_bucket.data.id
}

output "events_table" {
  value = aws_dynamodb_table.events.name
}

output "alerts_table" {
  value = aws_dynamodb_table.alerts.name
}

output "aggregates_table" {
  value = aws_dynamodb_table.aggregates.name
}

output "region" {
  value = data.aws_region.current.name
}
