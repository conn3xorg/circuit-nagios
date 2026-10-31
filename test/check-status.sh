#!/usr/bin/env sh
# Run on the host, with the path of the web interface and its password as
# arguments. Checks the example's passing check shows OK and its failing check
# CRITICAL, in Nagios's status file and in the web interface, and that the
# web interface wants a login and isn't listening beyond loopback.
set -eu
path=$1
password=$2

# A host image may not have curl, which Debian's Nagios doesn't need.
command -v curl >/dev/null || apt-get install -y -qq curl >/dev/null

status=$(find /var/lib/nagios4 /var/spool/nagios /usr/local/nagios/var -name status.dat 2>/dev/null | head -1)

# Prints the current_state of a service once Nagios has checked it.
state() {
  awk -v want="$1" '
    /^servicestatus/ { desc = ""; state = ""; checked = "" }
    /service_description=/ { sub(/.*=/, ""); desc = $0 }
    /has_been_checked=/ { sub(/.*=/, ""); checked = $0 }
    /current_state=/ { sub(/.*=/, ""); state = $0 }
    /^\t*}/ { if (desc == want && checked == "1") print state; desc = "" }
  ' "$status"
}

for _ in $(seq 150); do
  ok=$(state ssh_open)
  critical=$(state closed_port)
  [ -n "$ok" ] && [ -n "$critical" ] && break
  sleep 2
done
echo "ssh_open state: $ok (0 is OK), closed_port state: $critical (2 is CRITICAL)"
[ "$ok" = 0 ] && [ "$critical" = 2 ]

base="http://127.0.0.1:8080$path"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/")" = 401 ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -u nagiosadmin:wrong-password "$base/")" = 401 ]
[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/cgi-bin/status.cgi?host=all")" = 401 ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -u "nagiosadmin:$password" "$base/")" = 200 ]
page=$(curl -s -u "nagiosadmin:$password" "$base/cgi-bin/status.cgi?host=all")
echo "$page" | grep -q 'closed_port'
echo "$page" | grep -q 'CRITICAL'
echo "$page" | grep -q 'OK'

address=$(hostname -I | awk '{print $1}')
if curl -s -m 3 -o /dev/null "http://$address:8080/"; then
  echo "The web interface answered on $address." >&2
  exit 1
fi
echo "All checks passed."
