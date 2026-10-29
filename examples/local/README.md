# Local example

Applies circuit-jenkins to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman, and about 1 GB of memory free for Jenkins.

```sh
./up.sh
export TF_VAR_admin_password=$(openssl rand -hex 12)
conn3x init
conn3x apply
conn3x plan
```

The apply waits for Jenkins to answer, which takes under a minute. The second plan says `No changes.` Jenkins listens on `127.0.0.1:8080` inside the container, with `timestamper` installed, no executors on the controller, and a system message from `casc`. To ask it who you are:

```sh
ssh -p 2283 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  curl -s -u admin:"$TF_VAR_admin_password" 127.0.0.1:8080/whoAmI/api/json
```

To use the web UI from your browser, forward the port over SSH and open `http://localhost:8080`, then sign in as `admin`:

```sh
ssh -p 2283 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 8080:127.0.0.1:8080 -N root@127.0.0.1
```

`up.sh` listens on `127.0.0.1:2283`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
