variable "port" {
  type    = number
  default = 2222
}

variable "web_password" {
  type      = string
  ephemeral = true
  sensitive = true
  # For this throwaway container only.
  default = "example-password-change-me"
}

variable "extra_objects" {
  type    = string
  default = ""
}

module "nagios" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  web_password  = var.web_password
  extra_objects = var.extra_objects

  # Up when its SSH port answers, since a container may not be allowed to ping.
  monitored_hosts = {
    self = { address = "127.0.0.1", check_command = "check_tcp!22", max_check_attempts = 1 }
  }

  # sshd answers on port 22, and nothing listens on port 1.
  services = {
    ssh_open = {
      host               = "self"
      check_command      = "check_tcp!22"
      check_interval     = 1
      max_check_attempts = 1
    }
    closed_port = {
      host               = "self"
      check_command      = "check_tcp!1"
      check_interval     = 1
      max_check_attempts = 1
    }
  }
}
