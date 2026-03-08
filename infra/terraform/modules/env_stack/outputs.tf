# --- env_stack/outputs.tf

output "n8n_url" {
  description = "The public URL for this n8n environment"
  value       = "https://${var.subdomain}.${var.domain_name}"
}

output "instance_id" {
  description = "EC2 instance ID of the n8n server"
  value       = module.ec2_n8n.instance_id
}

output "pipeline_name" {
  description = "Name of the CodePipeline for this environment"
  value       = module.codepipeline.pipeline_name
}
