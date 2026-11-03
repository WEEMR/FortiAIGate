locals {
  Release_Bucket     = "wrady-fortiaigate-lab"
  CPU_Release_Prefix = "FortiAIGate_8.0.2_CPU"
  GPU_Release_Prefix = "FortiAIGate_8.0.2_GPU"
  Preparation = {
    cpu = {
      url    = "https://raw.githubusercontent.com/WEEMR/FortiAIGate/shared-2026-11-02.1/scripts/Home/releases/2026-11-02.1/prepare_fortiaigate_cpu.sh"
      sha256 = "db1cf5ca6d2a0519a2b633e6c3fd9991325d288bd064367891506d64c843ffb6"
    }
    gpu = {
      url    = "https://raw.githubusercontent.com/WEEMR/FortiAIGate/gpu-2026-11-02.1/scripts/AWS/GPU/releases/2026-11-02.1/user_data/prepare_fortiaigate_gpu.sh"
      sha256 = "7bd399ca8982360e58583eec95c3a06e53c5ea215e5649cf24bc6b5417cd9f3f"
    }
    ollama = {
      url    = "https://raw.githubusercontent.com/WEEMR/FortiAIGate/ollama-2026-11-02.1/scripts/Ollama/releases/2026-11-02.1/prepare_ollama.sh"
      sha256 = "3623fafd5bb1822fb096008fc2f4a5a04c2521f10506e9ee4c2610366a42ab19"
    }
  }
  Gateway_Scripts = {
    for name, settings in {
      AWS_CPU   = { cloud = "aws", edition = "cpu", operator = "ubuntu" }
      AWS_GPU   = { cloud = "aws", edition = "gpu", operator = "ubuntu" }
      Azure_CPU = { cloud = "azure", edition = "cpu", operator = "fortiadmin" }
      } : name => templatefile("${path.module}/FortiAIGate_Bootstrap.sh.tftpl", {
        cloud              = settings.cloud
        edition            = settings.edition
        operator           = settings.operator
        preparation_url    = local.Preparation[settings.edition].url
        preparation_sha256 = local.Preparation[settings.edition].sha256
        prep_config_json = jsonencode(merge({
          cloud = settings.cloud, edition = settings.edition, region = "us-east-1"
          }, settings.cloud == "aws" ? {
          release_s3_uri = "s3://${local.Release_Bucket}/${settings.edition == "gpu" ? local.GPU_Release_Prefix : local.CPU_Release_Prefix}/"
          } : {
          release_https_base = "https://${local.Release_Bucket}.s3.us-east-1.amazonaws.com/${local.CPU_Release_Prefix}"
        }))
    })
  }
  Ollama_Scripts = {
    for cloud in ["aws", "azure"] : cloud => templatefile("${path.module}/Ollama_Bootstrap.sh.tftpl", {
      cloud              = cloud
      operator           = cloud == "aws" ? "ubuntu" : "fortiadmin"
      private_ip         = "10.250.20.20"
      gateway_private_ip = "10.250.20.10"
      gateway_api_port   = var.Gateway_API_Port
      preparation_url    = local.Preparation.ollama.url
      preparation_sha256 = local.Preparation.ollama.sha256
    })
  }
  // Cloud-init installs the exact pinned helper; all progress stays in its normal status files/logs.
  Gateway_User_Data = { for name, script in local.Gateway_Scripts : name => "#cloud-config\n${yamlencode({
    write_files = [{ path = "/usr/local/sbin/fortiaigate-bootstrap", permissions = "0700", content = script }]
    runcmd      = [["bash", "/usr/local/sbin/fortiaigate-bootstrap"]]
  })}" }
  Ollama_User_Data = { for cloud, script in local.Ollama_Scripts : cloud => "#cloud-config\n${yamlencode({
    write_files = [{ path = "/usr/local/sbin/ollama-bootstrap", permissions = "0700", content = script }]
    runcmd      = [["bash", "/usr/local/sbin/ollama-bootstrap"]]
  })}" }
  CPU_Readiness_Command    = "bash -c '${replace(file("${path.module}/Wait_For_Preparation.sh"), "'", "'\\''")}' -- cpu"
  Ollama_Readiness_Command = "bash -c '${replace(file("${path.module}/Wait_For_Preparation.sh"), "'", "'\\''")}' -- ollama"
  GPU_Readiness_Command    = "bash -c '${replace(file("${path.module}/Wait_For_Preparation.sh"), "'", "'\\''")}' -- gpu"
}
