# circuit-nagios

[![Conn3x grade](https://conn3x.org/circuits/nagios/grade.svg)](https://conn3x.org/circuits/nagios/grade)

A Conn3x circuit that installs [Nagios Core](https://www.nagios.org/projects/nagios-core/) with its plugins, and writes your hosts and services into its config. You list what to watch in one place, and the file on the box never drifts from it. Every change goes through `nagios -v` first, so a typo fails the apply instead of taking your monitoring down on the next restart.

The web interface listens on loopback, behind a login, and the password never reaches your Conn3x state. If you've ever found a Nagios answering on port 80 with `nagiosadmin`/`nagiosadmin`, that's the part this is for.

## Where Nagios comes from

Distribution packages where they're current, and upstream's source where they aren't:

| Distribution | Nagios Core | Plugins |
| --- | --- | --- |
| Debian 13 | Debian's `nagios4`, 4.4.6 with the security fixes through 4.5.14 backported | `monitoring-plugins` |
| Fedora 45 | Fedora's `nagios`, 4.5.14 | `nagios-plugins-all` |
| Ubuntu 24.04 | Built from upstream's 4.5.14 source, checksum verified | `monitoring-plugins` |
| Rocky Linux, AlmaLinux, RHEL 10 | Built from upstream's 4.5.14 source, checksum verified | EPEL's `nagios-plugins-*` |

Why build at all? Nagios 4.5.12 to 4.5.14 fix authenticated remote code execution and CSRF bypasses (CVE-2026-48548 to CVE-2026-48554). When this circuit was written, Ubuntu 24.04's `nagios4` was still a plain 4.4.6 with those CVEs marked "needs evaluation", and EPEL 10 was on 4.5.9. Installing either would have given you a known hole.

The catch: a built Nagios gets no updates from your package manager. Security fixes reach those hosts when you change `nagios_version` and `nagios_sha256`. Watch [the releases](https://github.com/NagiosEnterprises/nagioscore/releases). It also means a compiler and development headers stay on the host. On Debian and Fedora, updates arrive the usual way, and the two inputs do nothing.

## Usage

```hcl
module "nagios" {
  source = "github.com/conn3xorg/circuit-nagios?ref=v0.1.2"

  hosts                = { monitor = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"
  web_password         = var.nagios_password

  monitored_hosts = {
    web1 = { address = "10.0.0.5" }
    db1  = { address = "10.0.0.6" }
  }

  services = {
    web1_http = { host = "web1", description = "HTTP", check_command = "check_http" }
    web1_ssh  = { host = "web1", description = "SSH", check_command = "check_ssh" }
    db1_pg    = { host = "db1", description = "PostgreSQL port", check_command = "check_tcp!5432" }
  }
}

variable "nagios_password" {
  type      = string
  ephemeral = true
  sensitive = true
}
```

Pass the password at run time, with `-var nagios_password=...` or `TF_VAR_nagios_password`. It's ephemeral, so it never goes into state or a plan.

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

The commands you can use in `check_command` are the ones Nagios's `commands.cfg` defines, or on Debian the ones in `/etc/nagios-plugins/config`, with arguments after `!`. To add your own:

```hcl
commands = {
  check_api = "$USER1$/check_http -H $HOSTADDRESS$ -u /health"
}
```

For hosts created in the same plan, pass host objects with the host key you generated, and the distribution in `os`, since the circuit picks its install by distribution and Conn3x can't ask a host that doesn't exist yet. Set `os` too when you put `depends_on` on this module.

```hcl
hosts = {
  monitor = {
    address  = digitalocean_droplet.monitor.ipv4_address
    host_key = tls_private_key.host.public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Reaching the web interface

It's on `127.0.0.1:8080`, at `/nagios`, or `/nagios4` on Debian. The `web_urls` output says which. The user is `nagiosadmin`. From your desk:

```sh
ssh -L 8080:127.0.0.1:8080 root@203.0.113.10
```

Then open <http://127.0.0.1:8080/nagios/>. For anything longer-lived, put a proxy with TLS in front on the same host, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) or nginx. Setting `web_listen_address` to a public address works, but your password then crosses the network in the clear, because the circuit doesn't set up TLS.

### When a config is wrong

If `nagios -v` doesn't like your config, the apply fails and shows why, and it fails the same way on every apply until you fix it. Nagios keeps running on its last good config, because nothing reloaded it. The bad file is on disk meanwhile, though, so don't restart Nagios by hand until it's fixed: a restart reads that file and won't come back.

## What it does

On each host, in order:

1. Installs Nagios and the plugins, or on Ubuntu and the Red Hat family, the build tools and plugins, then downloads the source, checks its SHA-256, and builds and installs it under `/usr/local/nagios` with upstream's own make targets. On Rocky Linux and AlmaLinux that starts with `epel-release`. RHEL doesn't ship it, so turn EPEL on yourself there first.
2. On a built host with SELinux on, labels `/usr/local/nagios` so the web server can run the CGIs, read the config and write the command pipe.
3. Writes your objects to `conn3x.cfg` in Nagios's config directory, and points `nagios.cfg` at it in place of the sample `localhost.cfg`. The other sample definitions, such as `linux-server` and `generic-service`, stay, since your hosts and services use them.
4. Runs `nagios -v` whenever any of that changes. Then starts Nagios now and at boot, and reloads it.
5. Turns on the login in `cgi.cfg`, which Debian's package leaves off, and hashes your password with bcrypt into `htpasswd.users`. On Debian it also turns off the package's web config, which lets in every private address.
6. Writes the web server's config, requiring a login for the pages and the CGIs alike. Then sets its `Listen` line to `web_listen_address` and `web_port`, and starts it now and at boot.

The password also sits in `/etc/conn3x/nagios/web-password`, mode `0600`, owned by root, outside the directories Nagios's own user owns. That's how a changed password reaches the htpasswd file without Conn3x ever storing it.

Coming from v0.1.0, the next apply moves the file there and removes the old one, `conn3x-web-password` in Nagios's config directory. If a Conn3x newer than v0.6.11 stops with `conn3x-web-password exists but can't be read by nagios`, run `conn3x apply -refresh=false` once, then carry on as usual.

Before the circuit runs, the `conn3x_host` data source reads each host's distribution over SSH.

### What it doesn't do

- It doesn't own the web server. It sets Apache's one `Listen` line, so plan on this host's Apache being for Nagios. Anything else served from it moves to the same address and port.
- It doesn't set up TLS, or mail. Notifications need a working `mail` command on the host, and contacts, which you can add with `extra_objects`.
- It doesn't open firewall ports. Your checks need to reach what they watch, and pings need ICMP.
- It doesn't install NRPE or NCPA, or anything on the hosts you monitor.
- Removing a host or service from the inputs removes it from the file, and the reload stops checking it. Deleting the module leaves Nagios installed and running with the last file.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to run Nagios on, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`. |
| `web_password` | string, ephemeral | Required | Password of the web interface's `nagiosadmin` user, at least 8 characters. |
| `web_listen_address` | string | `"127.0.0.1"` | Address the web server listens on. |
| `web_port` | number | `8080` | Port the web server listens on. |
| `monitored_hosts` | map(object) | `{}` | Hosts Nagios watches, by name. Each takes `address`, and optional `alias`, `check_command` (default `check-host-alive`, a ping) and `max_check_attempts` (default `3`). |
| `services` | map(object) | `{}` | Services Nagios checks, by name. Each takes `host` and `check_command`, and optional `description` (defaults to the name), `check_interval` (default `5` minutes), `retry_interval` (default `1` minute) and `max_check_attempts` (default `3`). |
| `commands` | map(string) | `{}` | Extra check commands, by name. They run on the Nagios host as the `nagios` user. |
| `extra_objects` | string | `""` | More Nagios object definitions, added as they are. |
| `nagios_version` | string | `"4.5.14"` | Release to build on Ubuntu and the Red Hat family. Debian and Fedora use their own package. |
| `nagios_sha256` | string | The 4.5.14 checksum | SHA-256 of that release's source tarball. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |

## Outputs

| Name | Description |
| --- | --- |
| `web_urls` | Web interface on each host, by name, such as `{ monitor = "http://127.0.0.1:8080/nagios/" }`. |
| `objects_files` | Path of the object file the circuit writes on each host, by name. |

## Requirements

Requires Conn3x v0.6.10 or later and systemd on each host, with a package mirror the host can reach. Built hosts also need outbound HTTPS to github.com.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each, checks that the second plan has no changes and that the password stayed out of state, and waits for the example's two checks: the one on an open port must show OK and the one on a closed port CRITICAL, in Nagios's status file and on the web interface's status page. It checks that the web interface refuses no password and a wrong one, and isn't answering on the container's own address. Then it applies a service with a command that doesn't exist, twice, and checks that both fail and Nagios keeps running, and that fixing it leaves the plan clean. Those runs were also done by hand in containers on arm64.

On the same arm64 containers, hosts first applied at v0.1.0 and then moved to this version passed those checks too, with the old password file gone and a clean second plan, on Conn3x v0.6.11. On a newer development build the same held for Debian and Fedora directly, and for Ubuntu and Rocky Linux with `-refresh=false` on the first apply. The move hasn't been run on a droplet.

The same checks passed on Ubuntu 24.04 and Rocky Linux 10 droplets, on amd64, with SELinux enforcing on Rocky. There, a command sent through the web interface's `cmd.cgi` reached Nagios, and the audit log had no denials once the labels above were in place. Changing the password locked out the old one on both. After a reboot, both came back with the same results and a clean plan. A build upgrade to a newer `nagios_version` hasn't been run, since 4.5.14 is the latest release. Debian and Fedora have only run in containers, with SELinux off. Fedora 45 wasn't available as a droplet.

## License

MPL-2.0. See [LICENSE](LICENSE). Nagios Core itself is GPL-2.0.
