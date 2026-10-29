# circuit-jenkins

A Conn3x circuit that runs a [Jenkins](https://www.jenkins.io) LTS controller on your own hosts, configured from code from its first start. No setup wizard, no unlock key copied out of a log, no clicking through "Install suggested plugins" and hoping you get the same set next time.

It installs Jenkins from the project's own LTS repository at `pkg.jenkins.io`, on OpenJDK from your distribution, then sets it up the way the Jenkins docs describe for automated installs: plugins at the versions you list, installed by Jenkins' [plugin installation manager tool](https://github.com/jenkinsci/plugin-installation-manager-tool), and everything else through [Jenkins Configuration as Code](https://www.jenkins.io/projects/jcasc/) (JCasC). The circuit writes `/etc/jenkins/casc.yaml` with an admin user and whatever else you pass in `casc`. The admin's password sits in a file of its own, so it never shows up in the plan, the state or `casc.yaml`.

Out of the box Jenkins listens on `127.0.0.1:8080`, for a reverse proxy in front.

## Usage

```hcl
variable "jenkins_admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "jenkins" {
  source = "github.com/conn3xorg/circuit-jenkins?ref=v0.1.0"

  hosts                = { ci1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin_password = var.jenkins_admin_password
  url            = "https://ci.example.com/"

  plugins = {
    "workflow-aggregator" = "608.v67378e9d3db_1"
    "git"                 = "5.11.0"
    "timestamper"         = "1.30"
  }

  casc = {
    jenkins = { numExecutors = 0 }
  }
}
```

Then run `conn3x init` and `conn3x apply`, with the password in `TF_VAR_jenkins_admin_password`. The apply waits for Jenkins to answer, which takes under a minute on a small host. A second `conn3x plan` says `No changes.`

Jenkins speaks plain HTTP here, for a TLS proxy on the same host such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) with a reverse proxy to `127.0.0.1:8080`. Set `url` to the address people type: Jenkins builds the links in its emails, build statuses and webhooks from it. To reach Jenkins straight from other machines instead, set `listen_address = "0.0.0.0"` and put a firewall in front.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its repository and Java package by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.ci : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Plugins

List plugins by ID with a version each, as the [plugins site](https://plugins.jenkins.io) shows them. `"latest"` works too, but then the plugin moves whenever the list is reinstalled. If you already keep a `plugins.txt` in the format Jenkins' Docker image uses, one `ID:VERSION` per line, point `plugins_file` at it; its lines are added to `plugins`. Don't list one plugin in both.

`configuration-as-code` is always installed, at `2143.vc78d4eb_d4174` unless you list it with another version, since without it nothing reads `casc.yaml`.

The tool fetches the dependencies of what you list from the update center for the Jenkins release on the host, at the newest versions that release supports at install time. To pin a dependency too, list it.

The list is reinstalled when it changes, when Jenkins is upgraded, or when the tool is. Each time, the tool downloads the whole set into a fresh directory, which replaces `/var/lib/jenkins/plugins` only when every download worked. A plugin taken off the list goes, and so does one installed by hand from the plugin manager. A failed download leaves Jenkins as it was.

### Configuration as code

`casc` is written to `casc.yaml` as YAML, so anything [JCasC](https://github.com/jenkinsci/configuration-as-code-plugin/tree/master/demos) understands goes in it, for the plugins you install. The circuit sets `jenkins.securityRealm` to Jenkins' own user database with signup off and one user, `admin_username`, and `jenkins.authorizationStrategy` to "logged-in users can do anything", with no anonymous read. `casc` can't set those two. To use LDAP, OIDC or matrix authorization, run your own JCasC files instead.

JCasC substitutes `${...}` in `casc.yaml` when Jenkins starts, from environment variables and the [secret sources](https://github.com/jenkinsci/configuration-as-code-plugin/blob/master/docs/features/secrets.adoc) it supports, such as `${readFile:/path}`. The admin password comes in that way, from `/etc/jenkins/admin-password`. Write `^${` for a literal `${`.

JCasC applies `casc.yaml` on every start, and the circuit restarts Jenkins when it changes, so a new `admin_password` takes effect on the next apply. Settings you change in the web UI that `casc.yaml` also sets go back on the next restart. Settings it doesn't mention stay as you left them.

### Memory

Jenkins' [hardware guide](https://www.jenkins.io/doc/book/scaling/hardware-recommendations/) asks for 256 MB and a gigabyte of disk at least, and suggests 4 GB and 50 GB for a small team. With `workflow-aggregator`, the Pipeline plugins, which come to 58 with their dependencies, a freshly started controller used 610 to 710 MB on a 2 GB droplet. Expect that to grow with jobs and build history, and plan on 1 to 2 GB for Jenkins alone. Without `heap_size`, Java takes a quarter of the host's memory for its heap. On a 2 GB host, `heap_size = "1g"` is a fair start. Run builds on agents rather than on the controller, which is why the example sets `numExecutors = 0`.

## What it does

On each host, in order:

1. Adds the Jenkins LTS repository with its signing key: `https://pkg.jenkins.io/debian-stable`, suite `binary/`, on Debian and Ubuntu, and `https://pkg.jenkins.io/rpm-stable` on the Red Hat family. The key, `5E386EADB55F01504CAE8BCF7198F4B714ABFC68` in `files/jenkins.asc`, expires on 21 December 2028. Then installs `curl`, `fontconfig` and OpenJDK `java_version` from the distribution: `openjdk-25-jre-headless` on Debian and Ubuntu, `java-25-openjdk-headless` on the Red Hat family.
2. Writes a systemd drop-in, `/etc/systemd/system/jenkins.service.d/conn3x.conf`, that sets `JAVA_HOME`, `JAVA_OPTS` with `-Djenkins.install.runSetupWizard=false` and `heap_size`, `JENKINS_LISTEN_ADDRESS`, `JENKINS_PORT` and `CASC_JENKINS_CONFIG`. It goes in before the package, because on Debian and Ubuntu the package starts Jenkins straight away, and that first start should already listen where you asked.
3. Installs `jenkins` at `jenkins_version`. A different version upgrades or downgrades it in place.
4. Writes `admin_password` to `/etc/jenkins/admin-password`, then `casc.yaml` and `plugins.txt` beside it, all mode `0640`, owner `root`, group `jenkins`.
5. Downloads `jenkins-plugin-manager-VERSION.jar` from GitHub into `/opt/jenkins-plugin-manager`, checks its SHA-256, and runs it as `jenkins` to install the plugins, as described above.
6. Restarts Jenkins when the package, the drop-in, `casc.yaml`, the password or the plugins changed, and starts it at boot. Then waits, up to five minutes, for `/login` to answer.

### What it doesn't do

- It doesn't set up TLS, a proxy, or a firewall port. Use [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) and [circuit-firewall](https://github.com/conn3xorg/circuit-firewall).
- It doesn't set up agents, credentials or jobs. Add them through `casc` with the plugins that provide them, such as `job-dsl` for jobs, or use the [Jenkins provider](https://registry.terraform.io/providers/taiidani/jenkins/latest) against the running controller.
- It doesn't take backups. Back up `/var/lib/jenkins`, which holds jobs, build history and the secrets Jenkins encrypts credentials with.
- It doesn't delete users. Renaming `admin_username` adds a new user and leaves the old one.
- It doesn't hold the package. A plain `apt upgrade` or `dnf upgrade` moves Jenkins to the newest LTS, and the next plan shows it.
- It doesn't install weekly releases. Those live in another repository with the same key.
- It doesn't build or install Java for your builds. That's a separate matter from the Java Jenkins runs on; Jenkins can install tools for builds itself.
- Deleting the module leaves Jenkins installed and running, with its data.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan or behind `depends_on` needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `admin_password` | string | Required | Password of `admin_username`. Ephemeral and sensitive: pass it with `-var` or `TF_VAR_`. At least 8 characters, on one line. Changing it restarts Jenkins with the new one. |
| `admin_username` | string | `"admin"` | ID of the Jenkins user JCasC creates. |
| `jenkins_version` | string | `"2.580.2"` | Jenkins LTS release to install. |
| `java_version` | number | `25` | OpenJDK release to run Jenkins on: `21` or `25`, the two that Jenkins 2.580 supports. Fedora 45 packages only 25. |
| `plugins` | map(string) | `{}` | Plugins to install, by ID, with a version each, such as `{ timestamper = "1.30" }`. `configuration-as-code` is always added. |
| `plugins_file` | string | `null` | Local path of a `plugins.txt`, one `ID:VERSION` per line, installed as well as `plugins`. |
| `casc` | any | `{}` | More JCasC configuration, as an object written to `casc.yaml`, such as `{ jenkins = { numExecutors = 0 } }`. Can't set `jenkins.securityRealm` or `jenkins.authorizationStrategy`. |
| `url` | string | `null` | Address people reach Jenkins by, ending in `/`, such as `"https://ci.example.com/"`. Sets `unclassified.location.url`. |
| `listen_address` | string | `"127.0.0.1"` | IP address Jenkins listens on. `"0.0.0.0"` listens on every address. |
| `port` | number | `8080` | Port Jenkins serves HTTP on. |
| `heap_size` | string | `null` | JVM heap, set as both `-Xms` and `-Xmx`, such as `"1g"`. When null, a quarter of the host's memory. |
| `plugin_manager_version` | string | `"2.15.0"` | Release of the plugin installation manager tool. Change `plugin_manager_sha256` with it. |
| `plugin_manager_sha256` | string | `"a86853ec..."` | SHA-256 of `jenkins-plugin-manager-VERSION.jar`, as GitHub lists it on the release. |

## Outputs

| Name | Description |
| --- | --- |
| `casc_file` | Path of the JCasC file on each host, `/etc/jenkins/casc.yaml`. |
| `url` | URL the circuit reaches Jenkins on, from each host itself, such as `http://127.0.0.1:8080`. |

## Requirements

Requires Conn3x v0.6.5 or later, systemd on each host, and outbound HTTPS to `pkg.jenkins.io`, `updates.jenkins.io`, GitHub and your distribution's mirrors. 2 GB of memory is comfortable for a small controller; see [Memory](#memory). Jenkins is a Java web app, so the same packages run on amd64 and arm64, but only amd64 was tested.

When the key in `files/jenkins.asc` nears its expiry on 21 December 2028, Jenkins will publish a new one at `https://pkg.jenkins.io/debian-stable/`. A release of this circuit with the new key then replaces it on the next apply.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13, with Jenkins 2.580.2 on OpenJDK 25. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes. It then checks that `/login` answers, that anonymous requests to the API and a wrong password are refused, that `admin` can get a crumb and use it with the same session for a `POST` to `/whoAmI/api/json`, that `timestamper` 1.30 is installed and active, that `numExecutors` from `casc` took, and that Jenkins listens on `127.0.0.1` only. Then it restarts Jenkins, checks the same again and plans again with no changes.

By hand, in a Fedora 45 container: a changed `admin_password`, after which the new one logged in and the old one didn't, with neither in the state; swapping `timestamper` for `build-timeout` at `latest`, which removed the one and installed the other; `url`, which reached Jenkins' location settings; a downgrade to 2.580.1 and an upgrade back to 2.580.2; and six applies in a row that each restarted Jenkins.

On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, each with 1 vCPU and 2 GB of memory, `heap_size = "1g"` and `workflow-aggregator` in `plugins`, the same checks passed. The first apply to both took under two and a half minutes. On Rocky Linux Jenkins ran as `unconfined_service_t`, and the audit log had no denials. After a reboot both came back on their own, in under 30 seconds, and the plan had no changes.
