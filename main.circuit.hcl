# Facts give each host's distribution, which picks Jenkins' apt or yum
# repository and the Java package, and its architecture, which Debian and
# Ubuntu put in the Java directory's name.
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
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  java_package = {
    debian = "openjdk-${var.java_version}-jre-headless"
    redhat = "java-${var.java_version}-openjdk-headless"
  }
  debian_arch = { x86_64 = "amd64", aarch64 = "arm64" }
  java_home = { for name, f in local.family : name => f == "debian" ?
    "/usr/lib/jvm/java-${var.java_version}-openjdk-${lookup(local.debian_arch, data.conn3x_host.facts[name].arch, data.conn3x_host.facts[name].arch)}" :
    "/usr/lib/jvm/jre-${var.java_version}"
  }

  home          = "/var/lib/jenkins"
  etc           = "/etc/jenkins"
  casc_file     = "${local.etc}/casc.yaml"
  plugins_file  = "${local.etc}/plugins.txt"
  password_file = "${local.etc}/admin-password"
  manager       = "/opt/jenkins-plugin-manager/jenkins-plugin-manager-${var.plugin_manager_version}.jar"

  # JCasC needs its own plugin, so it's always on the list. Listing it in
  # plugins picks another version.
  plugins = merge({ "configuration-as-code" = "2143.vc78d4eb_d4174" }, var.plugins)
  plugins_txt = join("", concat(
    ["# Written by Conn3x. Changes here are overwritten on the next apply.\n"],
    [for name, version in local.plugins : "${name}:${version}\n"],
    var.plugins_file == null ? [] : [file(var.plugins_file)],
  ))

  # JCasC reads the password from its file on every start, so it stays out
  # of casc.yaml, the plan and state. $${ is HCL for a literal ${.
  own_jenkins = {
    securityRealm = {
      local = {
        allowsSignup = false
        users        = [{ id = var.admin_username, password = "$${readFile:${local.password_file}}" }]
      }
    }
    authorizationStrategy = {
      loggedInUsersCanDoAnything = { allowAnonymousRead = false }
    }
  }
  casc = merge(
    var.casc,
    { jenkins = merge(lookup(var.casc, "jenkins", {}), local.own_jenkins) },
    var.url == null ? {} : { unclassified = merge(lookup(var.casc, "unclassified", {}), { location = { url = var.url } }) },
  )
  casc_yaml = "# Written by Conn3x. Changes here are overwritten on the next apply.\n${yamlencode(local.casc)}"

  # Where the circuit itself talks to Jenkins. 0.0.0.0 and :: listen on
  # loopback too.
  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.listen_address, strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address)
  url        = "http://${local.local_host}:${var.port}"

  java_opts = join(" ", compact([
    "-Djava.awt.headless=true",
    "-Djenkins.install.runSetupWizard=false",
    var.heap_size == null ? "" : "-Xms${var.heap_size} -Xmx${var.heap_size}",
  ]))
}

circuit "jenkins" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # One repository serves every LTS release, a flat apt repository for
  # Debian and Ubuntu and one yum repository for the whole Red Hat family.
  # Its signing key expires on 21 December 2028.
  step "repo" {
    repository {
      name   = "jenkins"
      url    = local.family[each.key] == "debian" ? "https://pkg.jenkins.io/debian-stable" : "https://pkg.jenkins.io/rpm-stable"
      key    = file("${path.module}/files/jenkins.asc")
      suites = local.family[each.key] == "debian" ? ["binary/"] : null
    }
  }

  # Jenkins' packages leave Java to you. fontconfig is the other thing its
  # install guide asks for, for the fonts in its graphs. curl waits for
  # Jenkins to come up.
  step "tools" {
    for_each = toset(["curl", "fontconfig"])
    package {
      name = item.value
    }
  }

  step "java" {
    package {
      name = local.java_package[local.family[each.key]]
    }
  }

  # Written before the package, since on Debian and Ubuntu the package
  # starts Jenkins straight away. With the drop-in there already, that
  # first start listens where you asked and skips the setup wizard.
  step "dropin_dir" {
    directory {
      path = "/etc/systemd/system/jenkins.service.d"
    }
  }

  step "dropin" {
    file {
      path    = "/etc/systemd/system/jenkins.service.d/conn3x.conf"
      content = <<-EOT
        # Written by Conn3x. Changes here are overwritten on the next apply.
        [Service]
        Environment="JAVA_HOME=${local.java_home[each.key]}"
        Environment="JAVA_OPTS=${local.java_opts}"
        Environment="JENKINS_LISTEN_ADDRESS=${var.listen_address}"
        Environment="JENKINS_PORT=${var.port}"
        Environment="CASC_JENKINS_CONFIG=${local.casc_file}"
        TimeoutStartSec=600
      EOT
    }
  }

  step "package" {
    package {
      name    = "jenkins"
      version = var.jenkins_version
    }
  }

  # casc.yaml and plugins.txt hold nothing secret. The password file belongs
  # to root, and jenkins can only read it.
  step "config_dir" {
    directory {
      path  = local.etc
      owner = "root"
      group = "jenkins"
      mode  = "0750"
    }
  }

  # Write-only: the plan and state record only an HMAC of the content.
  step "admin_password" {
    file {
      path       = local.password_file
      content_wo = var.admin_password
      owner      = "root"
      group      = "jenkins"
      mode       = "0640"
    }
  }

  step "casc" {
    file {
      path    = local.casc_file
      content = local.casc_yaml
      owner   = "root"
      group   = "jenkins"
      mode    = "0640"
    }
  }

  step "plugins_txt" {
    file {
      path    = local.plugins_file
      content = local.plugins_txt
      owner   = "root"
      group   = "jenkins"
      mode    = "0640"
    }
  }

  step "manager_dir" {
    directory {
      path = dirname(local.manager)
    }
  }

  step "manager" {
    download {
      url    = "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${var.plugin_manager_version}/jenkins-plugin-manager-${var.plugin_manager_version}.jar"
      sha256 = var.plugin_manager_sha256
      dest   = local.manager
    }
  }

  # The tool resolves dependencies against the update center for the
  # installed Jenkins version. It downloads into a fresh directory that
  # replaces the old one only when every download worked, so a plugin taken
  # off the list goes and a failed download leaves Jenkins as it was. A new
  # Jenkins release resolves the dependencies again.
  step "plugins" {
    command {
      command = "cd ${local.home} && rm -rf plugins.new && runuser -u jenkins -- ${local.java_home[each.key]}/bin/java -jar ${local.manager} --war /usr/share/java/jenkins.war --plugin-download-directory plugins.new --plugin-file ${local.plugins_file} && rm -rf plugins && mv plugins.new plugins"
      triggers = {
        list    = conn3x_file.jenkins__plugins_txt[each.key].revision
        jenkins = conn3x_package.jenkins__package[each.key].revision
        manager = conn3x_download.jenkins__manager[each.key].revision
      }
    }
  }

  # A step rather than a handler, so the check below waits for the Jenkins
  # that runs the new release, plugins and settings. Handlers run at the end
  # of the circuit, and a plan straight after the apply would find it still
  # starting. JCasC applies casc.yaml and the password on each start.
  # Jenkins' unit allows five starts in five minutes, and an upgrade on the
  # Red Hat family restarts it once already, so a few applies in a row would
  # hit the limit without reset-failed.
  step "restart" {
    command {
      command = "systemctl daemon-reload && { systemctl reset-failed jenkins || true; } && systemctl restart jenkins"
      triggers = {
        package  = conn3x_package.jenkins__package[each.key].revision
        dropin   = conn3x_file.jenkins__dropin[each.key].revision
        casc     = conn3x_file.jenkins__casc[each.key].revision
        password = conn3x_file.jenkins__admin_password[each.key].revision
        plugins  = conn3x_command.jenkins__plugins[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "jenkins"
      state   = "started"
      enabled = true
    }
  }

  # Jenkins answers 503 on /login while it loads its plugins. unless is
  # checked at plan time, before the restart, so the restart's revision
  # makes the apply check again.
  step "ready" {
    command {
      command  = "for _ in $(seq 300); do curl -sf -o /dev/null ${local.url}/login && exit 0; sleep 1; done; echo 'Jenkins did not answer on ${local.url}/login in 5 minutes. See journalctl -u jenkins.' >&2; exit 1"
      unless   = "curl -sf -o /dev/null ${local.url}/login"
      triggers = { restart = conn3x_command.jenkins__restart[each.key].revision }
    }
  }
}
