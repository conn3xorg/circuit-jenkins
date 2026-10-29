variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
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

variable "jenkins_version" {
  type        = string
  default     = "2.580.2"
  description = "Jenkins LTS release to install, such as \"2.580.2\". Raising it upgrades Jenkins in place."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.jenkins_version))
    error_message = "jenkins_version must be an LTS release number such as \"2.580.2\"."
  }
}

variable "java_version" {
  type        = number
  default     = 25
  description = "OpenJDK release to run Jenkins on, from the distribution's packages: 21 or 25, the two Jenkins supports. Fedora 45 packages only 25."

  validation {
    condition     = contains([21, 25], var.java_version)
    error_message = "java_version must be 21 or 25, the releases Jenkins LTS supports."
  }
}

variable "plugin_manager_version" {
  type        = string
  default     = "2.15.0"
  description = "Release of Jenkins' plugin installation manager tool, which installs the plugins. Change plugin_manager_sha256 with it."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.plugin_manager_version))
    error_message = "plugin_manager_version must be a release number such as \"2.15.0\"."
  }
}

variable "plugin_manager_sha256" {
  type        = string
  default     = "a86853ec2e2933f37a4b471ba65099b61e03c87a80c2ef8fe2315eb135672d43"
  description = "SHA-256 of jenkins-plugin-manager-VERSION.jar. Change it with plugin_manager_version."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.plugin_manager_sha256))
    error_message = "plugin_manager_sha256 must be a SHA-256 in lowercase hex."
  }
}

variable "plugins" {
  type        = map(string)
  default     = {}
  description = "Plugins to install, by ID, with the version of each, such as { timestamper = \"1.30\", git = \"latest\" }. configuration-as-code is always installed; list it to pick its version."

  validation {
    condition     = alltrue([for id, v in var.plugins : can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", id)) && can(regex("^[A-Za-z0-9][A-Za-z0-9_.+-]*$", v))])
    error_message = "Each plugin is an ID such as \"timestamper\" with a version such as \"1.30\" or \"latest\"."
  }
}

variable "plugins_file" {
  type        = string
  default     = null
  description = "Local path of a plugins.txt, one ID:VERSION per line, installed as well as plugins. When null, none."
}

variable "admin_username" {
  type        = string
  default     = "admin"
  description = "ID of the Jenkins user JCasC creates with admin_password."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.@-]*$", var.admin_username))
    error_message = "admin_username may use letters, digits, _, ., @ and -, and must start with a letter or digit."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password of admin_username, set by JCasC on every start of Jenkins. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  validation {
    condition     = length(var.admin_password) >= 8 && !strcontains(var.admin_password, "\n")
    error_message = "admin_password must be at least 8 characters, on one line."
  }
}

variable "casc" {
  type        = any
  default     = {}
  description = "More Jenkins Configuration as Code, as an object written to casc.yaml, such as { jenkins = { numExecutors = 0 } }. The circuit sets jenkins.securityRealm and jenkins.authorizationStrategy itself, and unclassified.location.url when url is set."

  validation {
    condition     = !can(var.casc.jenkins.securityRealm) && !can(var.casc.jenkins.authorizationStrategy)
    error_message = "casc can't set jenkins.securityRealm or jenkins.authorizationStrategy. The circuit sets them."
  }
}

variable "url" {
  type        = string
  default     = null
  description = "Address people reach Jenkins by, such as \"https://ci.example.com/\". Jenkins builds the links in its emails and build statuses from it. When null, Jenkins leaves it empty and warns about it."

  validation {
    condition     = var.url == null || can(regex("^https?://[^\\s]+/$", coalesce(var.url, "-")))
    error_message = "url must be an http or https URL ending in /, such as \"https://ci.example.com/\"."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address Jenkins listens on. The default keeps it to the host itself, for a proxy in front; \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IP address, such as \"127.0.0.1\" or \"0.0.0.0\"."
  }
}

variable "port" {
  type        = number
  default     = 8080
  description = "Port Jenkins serves HTTP on."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a port number from 1 to 65535."
  }
}

variable "heap_size" {
  type        = string
  default     = null
  description = "JVM heap, set as both -Xms and -Xmx, such as \"1g\". When null, Java sizes it at a quarter of the host's memory."

  validation {
    condition     = var.heap_size == null || can(regex("^[1-9][0-9]*[mg]$", coalesce(var.heap_size, "-")))
    error_message = "heap_size must be a whole number of megabytes or gigabytes, such as \"512m\" or \"1g\"."
  }
}
