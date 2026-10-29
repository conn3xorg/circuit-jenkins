output "casc_file" {
  description = "Path of the JCasC file the circuit writes on each host."
  value       = "/etc/jenkins/casc.yaml"
}

output "url" {
  description = "URL the circuit reaches Jenkins on, from each host itself."
  value       = local.url
}
