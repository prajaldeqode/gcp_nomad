variable "instanceName" {
    default = "nomad"
  description = "vm instance name"
}

provider "google" {
  project = "alfred-rc1-a2df"
  region  = "europe-west1"
  zone    = "europe-west1-b"
}


provider "google-beta" {
  project = "alfred-rc1-a2df"
  region  = "europe-west1"
  zone    = "europe-west1-b"
}

# VPC network
resource "google_compute_network" "ilb_network" {
  name                    = "${var.instanceName}l7-ilb-network"
  provider                = google-beta
  auto_create_subnetworks = false
}

# proxy-only subnet
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "${var.instanceName}l7-ilb-proxy-subnet"
  provider      = google-beta
  ip_cidr_range = "10.128.0.0/24"
  region        = "europe-west1"
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
  network       = google_compute_network.ilb_network.id
}

# backend subnet
resource "google_compute_subnetwork" "ilb_subnet" {
  name          = "${var.instanceName}l7-ilb-subnet"
  provider      = google-beta
  ip_cidr_range = "10.0.1.0/24"
  region        = "europe-west1"
  network       = google_compute_network.ilb_network.id
}

# forwarding rule
resource "google_compute_forwarding_rule" "google_compute_forwarding_rule" {
  name                  = "${var.instanceName}l7-ilb-forwarding-rule"
  provider              = google-beta
  region                = "europe-west1"
  depends_on            = [google_compute_subnetwork.proxy_subnet]
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.default.id
  network               = google_compute_network.ilb_network.id
  subnetwork            = google_compute_subnetwork.ilb_subnet.id
  network_tier          = "PREMIUM"
}

# HTTP target proxy
resource "google_compute_region_target_http_proxy" "default" {
  name     = "${var.instanceName}l7-ilb-target-http-proxy"
  provider = google-beta
  region   = "europe-west1"
  url_map  = google_compute_region_url_map.default.id
}

# URL map
resource "google_compute_region_url_map" "default" {
  name            = "${var.instanceName}l7-ilb-regional-url-map"
  provider        = google-beta
  region          = "europe-west1"
  default_service = google_compute_region_backend_service.default.id
}

# backend service
resource "google_compute_region_backend_service" "default" {
  name                  = "${var.instanceName}l7-ilb-backend-subnet"
  provider              = google-beta
  region                = "europe-west1"
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  timeout_sec           = 10
  health_checks         = [google_compute_region_health_check.default.id]
  backend {
    group           = google_compute_region_instance_group_manager.mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance template
resource "google_compute_instance_template" "instance_template" {
  name         = "${var.instanceName}l7-ilb-mig-template"
  provider     = google-beta
  machine_type = "e2-small"
  tags         = ["http-server"]

  network_interface {
    network    = google_compute_network.ilb_network.id
    subnetwork = google_compute_subnetwork.ilb_subnet.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = <<-EOF
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y nginx-light jq

    NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
    IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
    METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')

    cat <<EOF1 > /var/www/html/index.html
    <pre>
    Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
    EOF1
    # Install Git
    apt-get update
    apt-get install -y git ansible wget gpg coreutils
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    apt-get update
    apt-get install -y nomad
    git clone https://github.com/prajaldeqode/ansible_playbook /home/prapatidar/playbook
    sudo ansible-playbook /home/prapatidar/playbook/playbook.yml
    sudo su
    consul agent -config-file /home/prapatidar/playbook/consul.hcl
    nomad agent -config /home/prapatidar/playbook/client.hcl
  EOF
  }
  lifecycle {
    create_before_destroy = true
  }
}

# health check
resource "google_compute_region_health_check" "default" {
  name     = "${var.instanceName}l7-ilb-hc"
  provider = google-beta
  region   = "europe-west1"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

resource "google_compute_health_check" "autohealing" {
  name                = "${var.instanceName}autohealing-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10 # 50 seconds

  http_health_check {
    request_path = "/"
    port         = "80"
  }
}
resource "google_compute_region_autoscaler" "autoscaler" {
  name               = "${var.instanceName}-autoscaler"
  region             = "europe-west1"  # Update with your desired region
  target             = google_compute_region_instance_group_manager.mig.self_link  # Reference to the MIG
  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.7
    }
  }
}

# MIG
resource "google_compute_region_instance_group_manager" "mig" {
  name     = "${var.instanceName}l7-ilb-mig1"
  provider = google-beta
  region   = "europe-west1"
  version {
    instance_template = google_compute_instance_template.instance_template.id
    name              = "primary"
  }
  base_instance_name = "${var.instanceName}vm"
  target_size        = 1
   named_port {
    name = "customhttp"
    port = "8081"
  }
  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.id
    initial_delay_sec = 300
  }
}

# allow all access from IAP and health check ranges
resource "google_compute_firewall" "fw_iap" {
  name          = "${var.instanceName}l7-ilb-fw-allow-iap-hc"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.ilb_network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

# allow http from proxy subnet to backends
resource "google_compute_firewall" "fw_ilb_to_backends" {
  name          = "${var.instanceName}l7-ilb-fw-allow-ilb-to-backends"
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.ilb_network.id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]
  allow {
    protocol = "tcp"
    ports    = ["80","22", "443", "8081", "9090", "4646", "4647", "4648", "8500", "8300-8302"]
  }
}