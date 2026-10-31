output "web_urls" {
  description = "Web interface on each host, by name, as the host itself reaches it."
  value       = { for name, l in local.layout : name => "http://${local.listen}${l.path}/" }
}

output "objects_files" {
  description = "Path of the object file the circuit writes on each host, by name."
  value       = { for name, l in local.layout : name => "${l.etc}/conn3x.cfg" }
}
