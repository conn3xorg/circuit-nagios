# Local example

Applies circuit-nagios to a throwaway Rocky Linux 10 container with systemd, which watches itself: one check that passes and one that fails on purpose. You need Conn3x and Podman.

The container runs privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` Rocky Linux builds Nagios from source, so the first apply takes a few minutes. To look at the result, which can take a minute or two to fill in after Nagios starts:

```sh
podman cp ../../test/check-status.sh circuit-nagios:/tmp/check-status.sh
podman exec circuit-nagios sh /tmp/check-status.sh /nagios example-password-change-me
```

It prints `ssh_open state: 0 (0 is OK), closed_port state: 2 (2 is CRITICAL)`, then tries the web interface. On a Debian image the path is `/nagios4`. To see it in a browser:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 8080:127.0.0.1:8080 root@127.0.0.1
```

Then open <http://127.0.0.1:8080/nagios/> and log in as `nagiosadmin`, with the password in `main.tf`.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` stops the container, which removes it and its volumes, and removes the key and the state.
