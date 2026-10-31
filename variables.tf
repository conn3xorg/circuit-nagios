variable "hosts" {
  type        = any
  description = "Hosts to run Nagios on: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel or fedora."
  }
}

variable "web_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password of the web interface's nagiosadmin user. Pass it at run time with -var or TF_VAR_web_password; it never reaches state or the plan."

  validation {
    condition     = length(var.web_password) >= 8 && !strcontains(var.web_password, "\n")
    error_message = "web_password must be at least 8 characters, on one line."
  }
}

variable "web_listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address the web server listens on. The default keeps Nagios on the host, for a proxy or an SSH tunnel. Anything else sends the login in the clear, since the circuit doesn't set up TLS."

  validation {
    condition     = can(cidrhost("${var.web_listen_address}/${strcontains(var.web_listen_address, ":") ? 128 : 32}", 0))
    error_message = "web_listen_address must be an IP address."
  }
}

variable "web_port" {
  type        = number
  default     = 8080
  description = "Port the web server listens on."

  validation {
    condition     = var.web_port >= 1 && var.web_port <= 65535 && floor(var.web_port) == var.web_port
    error_message = "web_port must be a port number from 1 to 65535."
  }
}

variable "monitored_hosts" {
  type = map(object({
    address            = string
    alias              = optional(string)
    check_command      = optional(string, "check-host-alive")
    max_check_attempts = optional(number, 3)
  }))
  default     = {}
  description = "Hosts Nagios watches, by name, such as { web1 = { address = \"10.0.0.5\" } }. check_command is how Nagios decides the host is up, by default a ping."

  validation {
    condition     = alltrue([for name in keys(var.monitored_hosts) : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", name))])
    error_message = "Monitored host names may use letters, digits, ., - and _."
  }

  validation {
    condition     = alltrue([for h in values(var.monitored_hosts) : !anytrue([for v in [h.address, coalesce(h.alias, "-"), h.check_command] : strcontains(v, "\n")])])
    error_message = "A monitored host's address, alias and check_command must each be on one line."
  }
}

variable "services" {
  type = map(object({
    host               = string
    check_command      = string
    description        = optional(string)
    check_interval     = optional(number, 5)
    retry_interval     = optional(number, 1)
    max_check_attempts = optional(number, 3)
  }))
  default     = {}
  description = "Services Nagios checks, by name, such as { web1_http = { host = \"web1\", description = \"HTTP\", check_command = \"check_http\" } }. description defaults to the name, and intervals are in minutes."

  validation {
    condition     = alltrue([for s in values(var.services) : !strcontains(s.check_command, "\n") && can(regex("^[A-Za-z0-9 ._:@/+-]*$", coalesce(s.description, "-")))])
    error_message = "A service's check_command must be on one line, and its description may use letters, digits, spaces and . _ : @ / + -."
  }

  validation {
    condition     = alltrue([for name in keys(var.services) : can(regex("^[A-Za-z0-9 ._:@/+-]+$", name))])
    error_message = "Service names may use letters, digits, spaces and . _ : @ / + -."
  }
}

variable "commands" {
  type        = map(string)
  default     = {}
  description = "Extra check commands, by name, such as { check_api = \"$USER1$/check_http -H $HOSTADDRESS$ -u /health\" }. They run on the Nagios host as the nagios user."

  validation {
    condition     = alltrue([for name, c in var.commands : can(regex("^[A-Za-z0-9_-]+$", name)) && !strcontains(c, "\n")])
    error_message = "Command names may use letters, digits, - and _, and each command must be on one line."
  }
}

variable "extra_objects" {
  type        = string
  default     = ""
  description = "More Nagios object definitions, added to the file as they are, such as contacts or host groups. nagios -v checks them before any reload."
}

variable "nagios_version" {
  type        = string
  default     = "4.5.14"
  description = "Nagios Core release to build on Ubuntu, Rocky Linux, AlmaLinux and RHEL. Debian and Fedora use their own package, whatever its version. Change it together with nagios_sha256."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.nagios_version))
    error_message = "nagios_version must look like 4.5.14."
  }
}

variable "nagios_sha256" {
  type        = string
  default     = "dce59f306577789c56d2748471d4c3856ecba8572d6b0811cf79f9de2f9afabb"
  description = "SHA-256 of the nagios_version source tarball."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}
