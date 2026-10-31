# Facts give each host's distribution, which decides where Nagios comes from
# and where its files live.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }

    postcondition {
      condition     = contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "fedora"], self.os_id)
      error_message = "Host ${each.key} is ${self.os_id}. This circuit supports Debian, Ubuntu, Fedora, Rocky Linux, AlmaLinux and RHEL."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }

  # Debian's nagios4 carries the security fixes up to 4.5.14, and Fedora
  # ships 4.5.14 itself. Ubuntu 24.04 and EPEL 10 stop short of fixes for
  # remote code execution, so those hosts build the upstream release.
  kind = { for name, o in local.os : name => lookup({ debian = "debian", fedora = "fedora", ubuntu = "ubuntu" }, o, "el") }

  debian_hosts = { for name, h in var.hosts : name => h if local.kind[name] == "debian" }
  fedora_hosts = { for name, h in var.hosts : name => h if local.kind[name] == "fedora" }
  ubuntu_hosts = { for name, h in var.hosts : name => h if local.kind[name] == "ubuntu" }
  el_hosts     = { for name, h in var.hosts : name => h if local.kind[name] == "el" }
  build_hosts  = merge(local.ubuntu_hosts, local.el_hosts)
  fpm_hosts    = merge(local.fedora_hosts, local.el_hosts)
  epel_hosts   = { for name, h in var.hosts : name => h if contains(["rocky", "almalinux"], local.os[name]) }

  built = {
    etc      = "/usr/local/nagios/etc"
    resource = "/usr/local/nagios/etc/resource.cfg"
    bin      = "/usr/local/nagios/bin/nagios"
    service  = "nagios"
    html     = "/usr/local/nagios/share"
    cgi      = "/usr/local/nagios/sbin"
    path     = "/nagios"
  }
  debian_web = {
    apache   = "apache2"
    web_user = "www-data"
    web_conf = "/etc/apache2/conf-enabled/conn3x-nagios.conf"
    listen   = "/etc/apache2/ports.conf"
  }
  redhat_web = {
    apache   = "httpd"
    web_user = "apache"
    web_conf = "/etc/httpd/conf.d/nagios.conf"
    listen   = "/etc/httpd/conf/httpd.conf"
  }
  layouts = {
    debian = merge(local.debian_web, {
      etc      = "/etc/nagios4"
      resource = "/etc/nagios4/resource.cfg"
      bin      = "/usr/sbin/nagios4"
      service  = "nagios4"
      html     = "/usr/share/nagios4/htdocs"
      cgi      = "/usr/lib/cgi-bin/nagios4"
      path     = "/nagios4"
      plugins  = "/usr/lib/nagios/plugins"
    })
    fedora = merge(local.redhat_web, {
      etc      = "/etc/nagios"
      resource = "/etc/nagios/private/resource.cfg"
      bin      = "/usr/sbin/nagios"
      service  = "nagios"
      html     = "/usr/share/nagios/html"
      cgi      = "/usr/lib64/nagios/cgi-bin"
      path     = "/nagios"
      plugins  = "/usr/lib64/nagios/plugins"
    })
    ubuntu = merge(local.debian_web, local.built, { plugins = "/usr/lib/nagios/plugins" })
    el     = merge(local.redhat_web, local.built, { plugins = "/usr/lib64/nagios/plugins" })
  }
  layout = { for name, k in local.kind : name => local.layouts[k] }

  listen = strcontains(var.web_listen_address, ":") ? "[${var.web_listen_address}]:${var.web_port}" : "${var.web_listen_address}:${var.web_port}"

  web_auth = <<-EOT
    AuthName "Nagios"
        AuthType Basic
        AuthUserFile %HTPASSWD%
        Require valid-user
  EOT

  web_config = { for name, l in local.layout : name => <<-EOT
    # Written by Conn3x. Changes here are overwritten on the next apply.
    %{if local.kind[name] == "debian"}ScriptAlias /cgi-bin/nagios4 ${l.cgi}
    Alias /nagios4/stylesheets /etc/nagios4/stylesheets
    <Directory /etc/nagios4/stylesheets>
        ${replace(local.web_auth, "%HTPASSWD%", "${l.etc}/htpasswd.users")}
    </Directory>
    %{endif}ScriptAlias ${l.path}/cgi-bin ${l.cgi}
    Alias ${l.path} ${l.html}
    <Directory ${l.cgi}>
        Options ExecCGI
        AllowOverride None
        ${replace(local.web_auth, "%HTPASSWD%", "${l.etc}/htpasswd.users")}
    </Directory>
    <Directory ${l.html}>
        Options None
        AllowOverride None
        DirectoryIndex index.php index.html
        ${replace(local.web_auth, "%HTPASSWD%", "${l.etc}/htpasswd.users")}
    </Directory>
  EOT
  }

  objects = join("\n", concat(
    ["# Written by Conn3x. Changes here are overwritten on the next apply.\n"],
    [for name, command in var.commands : <<-EOT
      define command {
          command_name ${name}
          command_line ${command}
      }
    EOT
    ],
    [for name, h in var.monitored_hosts : <<-EOT
      define host {
          use                linux-server
          host_name          ${name}
          alias              ${coalesce(h.alias, name)}
          address            ${h.address}
          check_command      ${h.check_command}
          max_check_attempts ${h.max_check_attempts}
      }
    EOT
    ],
    [for name, s in var.services : <<-EOT
      define service {
          use                 generic-service
          host_name           ${s.host}
          service_description ${coalesce(s.description, name)}
          check_command       ${s.check_command}
          check_interval      ${s.check_interval}
          retry_interval      ${s.retry_interval}
          max_check_attempts  ${s.max_check_attempts}
      }
    EOT
    ],
    [var.extra_objects],
  ))

  # On SELinux hosts, what the web server needs of a build under /usr/local.
  # The CGIs memory-map the status files, which the policy refuses on a
  # read-write label, so only the command pipe gets one. Nagios itself runs
  # unconfined, and writes those files whatever their label.
  selinux_labels = {
    "/usr/local/nagios/sbin(/.*)?"   = "httpd_sys_script_exec_t"
    "/usr/local/nagios/share(/.*)?"  = "httpd_sys_content_t"
    "/usr/local/nagios/etc(/.*)?"    = "httpd_sys_content_t"
    "/usr/local/nagios/var(/.*)?"    = "httpd_sys_content_t"
    "/usr/local/nagios/var/rw(/.*)?" = "httpd_sys_rw_content_t"
  }
}

circuit "epel" {
  hosts = local.epel_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The plugins come from EPEL.
  step "release" {
    package {
      name = "epel-release"
    }
  }
}

circuit "debian" {
  hosts = local.debian_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "packages" {
    for_each = toset(["apache2", "apache2-utils", "php", "libapache2-mod-php", "nagios4-core", "nagios4-cgi", "monitoring-plugins"])
    package {
      name = item.value
    }
  }

  # The package's own web config leaves Nagios open to every private address,
  # with its login turned off.
  step "package_web_config" {
    command {
      command = "a2disconf -q nagios4-cgi"
      unless  = "test ! -e /etc/apache2/conf-enabled/nagios4-cgi.conf"
    }
  }
}

circuit "fedora" {
  hosts = local.fedora_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "packages" {
    for_each = toset(["httpd", "httpd-tools", "php", "php-fpm", "nagios", "nagios-selinux", "nagios-plugins-all"])
    package {
      name = item.value
    }
  }
}

circuit "ubuntu" {
  hosts = local.ubuntu_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "packages" {
    for_each = toset(["curl", "unzip", "gcc", "make", "libgd-dev", "libssl-dev", "apache2", "apache2-utils", "php", "libapache2-mod-php", "monitoring-plugins"])
    package {
      name = item.value
    }
  }
}

circuit "el" {
  hosts = local.el_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The plugins one at a time, since nagios-plugins-all on EPEL 10 needs Perl
  # modules that only exist with the CRB repository on.
  step "packages" {
    depends_on = [conn3x_package.epel__release]
    for_each   = toset(["curl", "unzip", "tar", "perl-interpreter", "gcc", "make", "gd-devel", "openssl-devel", "httpd", "httpd-tools", "php", "php-fpm", "policycoreutils-python-utils", "nagios-plugins-ping", "nagios-plugins-tcp", "nagios-plugins-http", "nagios-plugins-ssh", "nagios-plugins-dns", "nagios-plugins-smtp", "nagios-plugins-disk", "nagios-plugins-load", "nagios-plugins-procs", "nagios-plugins-swap", "nagios-plugins-users", "nagios-plugins-ntp"])
    package {
      name = item.value
    }
  }
}

circuit "build" {
  hosts = local.build_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "group" {
    depends_on = [conn3x_package.ubuntu__packages, conn3x_package.el__packages]
    group {
      name   = "nagios"
      system = true
    }
  }

  step "user" {
    user {
      name   = "nagios"
      group  = "nagios"
      system = true
      shell  = "/usr/sbin/nologin"
    }
  }

  step "source" {
    download {
      url    = "https://github.com/NagiosEnterprises/nagioscore/releases/download/nagios-${var.nagios_version}/nagios-${var.nagios_version}.tar.gz"
      sha256 = var.nagios_sha256
      dest   = "/var/lib/nagios-${var.nagios_version}.tar.gz"
    }
  }

  # An upgrade reinstalls the program and keeps the config already there.
  step "install" {
    command {
      command = <<-EOT
        set -e
        dir=$(mktemp -d /var/tmp/nagios-build.XXXXXX)
        trap 'rm -rf "$dir"' EXIT
        tar -xzf /var/lib/nagios-${var.nagios_version}.tar.gz -C "$dir" --strip-components=1
        cd "$dir"
        ./configure >build.log 2>&1 || { tail -20 build.log; exit 1; }
        make all >>build.log 2>&1 || { tail -20 build.log; exit 1; }
        make install install-daemoninit install-commandmode >>build.log 2>&1 || { tail -20 build.log; exit 1; }
        [ -e /usr/local/nagios/etc/nagios.cfg ] || make install-config >>build.log 2>&1
      EOT
      unless  = "/usr/local/nagios/bin/nagios --version | grep -q 'Nagios Core ${var.nagios_version}$'"
    }
  }
}

circuit "el_selinux" {
  hosts = local.el_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Runs through a command because the selinux_fcontext step fails on a host
  # with SELinux off, and this has nothing to do there. The htpasswd file
  # and the CGIs are under /usr/local, which the policy doesn't expect.
  step "labels" {
    command {
      command = <<-EOT
        selinuxenabled || exit 0
        ${join("\n", [for target, type in local.selinux_labels : "semanage fcontext -a -t ${type} '${target}' 2>/dev/null || semanage fcontext -m -t ${type} '${target}'"])}
        restorecon -R /usr/local/nagios
      EOT
      triggers = {
        install = conn3x_command.build__install[each.key].revision
        labels  = jsonencode(local.selinux_labels)
      }
    }
  }
}

circuit "php" {
  hosts = local.fpm_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Nagios's front page is PHP, which the Red Hat family's httpd runs here.
  step "fpm" {
    depends_on = [conn3x_package.fedora__packages, conn3x_package.el__packages]
    service {
      name    = "php-fpm"
      state   = "started"
      enabled = true
    }
  }
}

circuit "nagios" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "objects" {
    depends_on = [conn3x_command.debian__package_web_config, conn3x_package.fedora__packages, conn3x_command.build__install, conn3x_command.el_selinux__labels]
    file {
      path    = "${local.layout[each.key].etc}/conn3x.cfg"
      content = local.objects
      mode    = "0644"
    }
  }

  # The sample localhost config would clash with a monitored host of that
  # name and fill the web interface with services nobody asked for, so this
  # file takes its place.
  step "include" {
    line {
      path   = "${local.layout[each.key].etc}/nagios.cfg"
      regexp = "^cfg_file=.*/(localhost|conn3x)\\.cfg$"
      line   = "cfg_file=${local.layout[each.key].etc}/conn3x.cfg"
    }
  }

  step "plugin_path" {
    line {
      path   = local.layout[each.key].resource
      regexp = "^\\$USER1\\$="
      line   = "$USER1$=${local.layout[each.key].plugins}"
    }
  }

  # Nothing reloads Nagios until it has read the whole config and agreed
  # with it. A failure here fails the apply, and fails it again next time,
  # with the running Nagios still on its last good config.
  step "validate" {
    command {
      command = "${local.layout[each.key].bin} -v ${local.layout[each.key].etc}/nagios.cfg"
      triggers = {
        objects = sha256(local.objects)
        include = conn3x_line.nagios__include[each.key].revision
        plugins = conn3x_line.nagios__plugin_path[each.key].revision
      }
    }
    notify = [handler.reload]
  }

  step "running" {
    service {
      name    = local.layout[each.key].service
      state   = "started"
      enabled = true
    }
  }

  # Debian's own cgi.cfg turns the login off.
  step "authentication" {
    line {
      path   = "${local.layout[each.key].etc}/cgi.cfg"
      regexp = "^use_authentication="
      line   = "use_authentication=1"
    }
  }

  # The web server hashes this into the htpasswd file below. It stays on the
  # host so a changed password shows up in the next plan, and only root can
  # read it.
  step "password_file" {
    file {
      path       = "${local.layout[each.key].etc}/conn3x-web-password"
      content_wo = var.web_password
      owner      = "root"
      group      = "root"
      mode       = "0600"
    }
  }

  step "htpasswd" {
    command {
      command  = <<-EOT
        set -e
        htpasswd -ciB ${local.layout[each.key].etc}/htpasswd.users nagiosadmin < ${local.layout[each.key].etc}/conn3x-web-password
        chown root:${local.layout[each.key].web_user} ${local.layout[each.key].etc}/htpasswd.users
        chmod 0640 ${local.layout[each.key].etc}/htpasswd.users
      EOT
      triggers = conn3x_file.nagios__password_file[each.key].revision
    }
  }

  step "web_user" {
    command {
      command = "usermod -aG nagios ${local.layout[each.key].web_user}"
      unless  = "id -nG ${local.layout[each.key].web_user} | grep -qw nagios"
    }
    notify = [handler.apache]
  }

  step "web_modules" {
    for_each = toset(["cgi", "auth_basic", "authn_file", "authz_user", "alias"])
    command {
      command = "if command -v a2enmod >/dev/null; then a2enmod -q ${item.value}; fi"
      unless  = "! command -v a2enmod >/dev/null || test -e /etc/apache2/mods-enabled/${item.value}.load"
    }
    notify = [handler.apache]
  }

  step "web_config" {
    file {
      path    = local.layout[each.key].web_conf
      content = local.web_config[each.key]
    }
    notify = [handler.apache]
  }

  # Only this address and port. The distribution's default of port 80 on
  # every address would put the web server, and anything else it serves, on
  # the network.
  step "web_listen" {
    line {
      path   = local.layout[each.key].listen
      regexp = "^Listen "
      line   = "Listen ${local.listen}"
    }
    notify = [handler.apache]
  }

  step "web" {
    service {
      name    = local.layout[each.key].apache
      state   = "started"
      enabled = true
    }
  }

  handler "reload" {
    service {
      name   = local.layout[each.key].service
      action = "reload"
    }
  }

  handler "apache" {
    service {
      name = local.layout[each.key].apache
    }
  }
}
