// Detection is the runner's address. CloudShell users supply their browser IPv4
// for HTTPS/WebUI; Azure SSH separately defaults to the CloudShell runner IPv4.
data "http" "User_Public_IP" {
  count              = (local.Any_Cloud && var.Management_Source_CIDR == null) || (var.create_Azure_FortiAIGate_CPU == "yes" && var.SSH_Source_CIDR == null) ? 1 : 0
  url                = "https://checkip.amazonaws.com"
  request_headers    = { Accept = "text/plain" }
  request_timeout_ms = 10000
  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(cidrnetmask("${trimspace(self.response_body)}/32")) && !contains(["0.0.0.0", "255.255.255.255"], trimspace(self.response_body))
      error_message = "Public IPv4 detection failed. Set Management_Source_CIDR to your browser's trusted IPv4 /32 and SSH_Source_CIDR to your SSH client's IPv4 /32, then retry."
    }
  }
}
locals {
  Management_Source_CIDR = var.Management_Source_CIDR != null ? var.Management_Source_CIDR : try("${trimspace(data.http.User_Public_IP[0].response_body)}/32", null)
  SSH_Source_CIDR        = var.SSH_Source_CIDR != null ? var.SSH_Source_CIDR : try("${trimspace(data.http.User_Public_IP[0].response_body)}/32", local.Management_Source_CIDR)
}
