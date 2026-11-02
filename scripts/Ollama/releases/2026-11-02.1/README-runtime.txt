Ollama lab runtime — 2026-11-02.1

Run on a NEW, SEPARATE Ubuntu 22.04/24.04 amd64 host, with at least 4 GiB RAM
(8 GiB recommended), 16 GiB free disk and outbound internet access. The small
model runs on the CPU and works behind either CPU or GPU FortiAIGate editions.
This installer does not change the FortiAIGate host or enable gateway scanning.

Install from the extracted package (the AWS launcher invokes this automatically):
  sudo bash releases/2026-11-02.1/prepare_ollama.sh --install --bind-address YOUR_PRIVATE_IPV4 --webui-url http://YOUR_SERVER_PUBLIC_IPV4:3000

Runtime 2026-11-02.1 is published at the immutable GitHub URL:
https://raw.githubusercontent.com/WEEMR/FortiAIGate/ollama-2026-11-02.1/scripts/Ollama/releases/2026-11-02.1/prepare_ollama.sh
The package's top-level prepare_ollama.sh intentionally retains runtime .2 for
older launchers that pin that download's checksum. Use the current versioned file
for automatic Configure, progress and certificate handling, and verify the
package's SHA256SUMS before manual use.

Omit --bind-address for a loopback-only local installation. Never open model
port 11434 to the internet: allow inbound only from FortiAIGate's security
group/private source. The supplied AWS launcher applies this rule. For a manual
Ubuntu installation, establish that firewall restriction BEFORE binding a
private address. Open WebUI publishes port 3000 on loopback and that private
address (AWS maps the instance's public IPv4 to it). Allow inbound TCP3000 only
from your computer's public IPv4 /32 BEFORE using the private bind. The supplied
AWS launcher creates both rules. Browser access uses HTTP for this lab; no TLS
proxy or SSH tunnel is needed. HTTP does not encrypt login or chat traffic.

What is installed:
  ollama/ollama:0.40.13
  ghcr.io/open-webui/open-webui:v0.12.5
  llama3.2:1b (currently about 1.3 GB), copied to model alias llama-lab
  Named volumes ollama-lab-models and ollama-lab-webui, retained on reruns
  /opt/ollama-lab for root-only configuration and runtime
  /var/lib/ollama-lab/status.json for cloud-readiness progress
  /usr/local/bin/ollama-lab for status/configure/verify/logs

The installer checks a REAL local model response before marking the backend
ready. Progress is stage-based; Docker/Ollama report downloads as they happen.
Image/model pulls have 30-minute limits and the initial inference a 5-minute
limit. Rerun to reuse downloaded layers and persistent model/chat volumes.

FortiAIGate configuration:
  1. Create an OpenAI-compatible provider using
       http://OLLAMA_PRIVATE_IPV4:11434/v1
     Ollama ignores provider API keys; use a placeholder such as ollama if the
     gateway provider form requires a key. This is NOT the gateway virtual key.
  2. Publish/map the upstream model llama-lab to gateway model alias llama-lab.
  3. Create a virtual key allowed to use llama-lab and bind your desired policy.
  4. From an interactive SSH terminal on the Ollama host, run:
       sudo ollama-lab configure
     Standard AWS setup selects and displays the gateway HTTPS URL, verified
     certificate and saved browser URL automatically. Enter only your virtual
     key, hidden. The URL uses the linked gateway's saved private IP and API
     port with /ai/openai/v1; the standard lab uses
     https://10.250.20.10/ai/openai/v1. A non-443 port is included explicitly.
     Before asking for the key, Configure checks root-owned deployment metadata
     against the authenticated certificate enrollment: gateway IP, EC2 instance
     ID and API port must agree. It also validates the saved browser URL.
     Missing or conflicting values stop setup instead of guessing.
     The current AWS launcher prepares the gateway public certificate through
     authenticated Systems Manager access and strict TLS validation. For older
     labs or a retry, choose menu 8 (Prepare gateway certificate) in the latest
     CloudShell launcher. It refreshes the metadata needed for automatic setup;
     it does not change security-group rules or upgrade the installed helper.
     Custom endpoints and manual/legacy installations can use:
       sudo ollama-lab configure --manual
     This explicitly asks for the gateway URL, certificate and browser URL.
     Private DNS names and custom paths remain supported. Upload a trusted
     issuing CA bundle for a custom private CA, or type system for the OS trust
     store. Saved trust is offered for the same HTTPS origin. The deployment
     port check still applies when metadata exists; TLS verification stays on.
     A failed gateway test preserves the previously working certificate bundle.
     If an older server's public IP changes, run Connect and use manual mode
     with the current browser URL to update the saved URL and allowed origin.
     On first configuration, choose an Open WebUI administrator email and a
     password of at least 12 characters (maximum 72 UTF-8 bytes).
     Configure prints each setup stage and elapsed waiting updates every ten
     seconds. First setup starts WebUI twice: once to create and verify the admin
     account, then again to remove its temporary password from container settings.
     Existing accounts skip this bootstrap cleanup restart.
     Wait for the success message before opening port 3000. The startup check
     retries temporary connection resets while WebUI initializes, for up to ten
     minutes per startup. It verifies the administrator login and removes bootstrap account
     credentials from the container configuration after successful setup.

Lightweight testing defaults
---------------------------
New installations and installer reruns create llama-lab from a Modelfile with
num_ctx 1024, num_predict 64 and temperature 0.2. Ollama keeps the model resident
for 30 minutes, permits one request at a time and loads one model at a time.
WebUI uses max_tokens 64 and temperature 0.2 by default. Title, tag, follow-up,
autocomplete, search-query, retrieval-query and image-prompt generation are off,
as are web search, image generation, code execution/interpreter and memories.
Authentication, gateway routing, certificate checks and FortiAIGate protections
remain enabled/configured as before. Shorter replies may stop mid-answer, and
the smaller context limits chat history. Existing chat/model settings can
override these defaults; refresh WebUI and use a new chat for testing.

Updating existing installations
------------------------------
Use the pinned installer and checksum command at
https://guides.fortinetpslab.com/ollama#ollama-runtime-update on the Ollama host.
For a direct-browser lab, reuse its saved bind-address and browser-url only
after confirming the current URL with Connect. Missing files stop the command.
Older loopback/tunnel labs need the separate network migration in README-aws.txt.
The installer keeps named model/WebUI volumes, accounts, chats, gateway.env and
trusted certificates. It restarts the model service and writes the new runtime;
then rerun Configure to apply the WebUI settings. Before updating an older AWS
lab, run menu 8 in the latest CloudShell launcher once to refresh its enrollment
and access metadata. Certificate menu 8 alone does not upgrade an installed
runtime. Custom setups can use configure --manual. Do not replace an immutable installer
download or use the legacy stable .2 installer to obtain this update.

Manual upgrade when the saved browser URL is missing or outdated
--------------------------------------------------------------
Use Connect in the CloudShell launcher to get this Ollama server's private IPv4
and current public browser URL. On the Ollama server, replace BOTH uppercase
placeholders below before running the block. Port 3000 must already allow only
your public IPv4 /32; older tunnel-based labs need the README-aws.txt network
upgrade first. This block installs the current helper without reading a saved
browser-url file, preserves accounts/chats, then starts explicit manual setup:

  (
    set -eu
    ollama_installer=$(mktemp /tmp/ollama-runtime.XXXXXX)
    trap 'rm -f "$ollama_installer"' EXIT
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
      https://raw.githubusercontent.com/WEEMR/FortiAIGate/ollama-2026-11-02.1/scripts/Ollama/releases/2026-11-02.1/prepare_ollama.sh \
      -o "$ollama_installer"
    printf '%s  %s\n' '3623fafd5bb1822fb096008fc2f4a5a04c2521f10506e9ee4c2610366a42ab19' "$ollama_installer" | sha256sum -c -
    sudo bash "$ollama_installer" --install \
      --bind-address OLLAMA_PRIVATE_IPV4 \
      --webui-url http://OLLAMA_PUBLIC_IPV4:3000
    sudo ollama-lab configure --manual
  )

Manual prompts are gateway URL, certificate path, browser URL, then hidden
virtual key. Existing WebUI accounts are retained. Automatic mode is available
once the current launcher's menu 8 has prepared matching deployment metadata
and certificate trust for the standard AWS gateway.

What does sudo ollama-lab configure do?
---------------------------------------
ollama-lab is a custom helper supplied by this lab, not an Ollama command.
The installer creates /usr/local/bin/ollama-lab, a small shell wrapper that runs
/opt/ollama-lab/runtime.py. sudo gives it permission to manage Docker and save
root-only configuration; configure selects its interactive setup action.
It selects the saved AWS gateway URL, verified certificate and browser URL,
asks for your hidden virtual key, checks a real model reply through FortiAIGate,
saves those settings, starts Open WebUI,
and waits for readiness. On first setup it also creates and verifies your admin
account, then removes temporary bootstrap credentials and restarts WebUI.
Ollama itself runs the model in a separate container, installed in Step 1.
Configure does not create the FortiAIGate provider, virtual key or policy;
those are configured separately in Step 2. Reruns preserve accounts and chats.

Configure tests a chat completion through FortiAIGate BEFORE starting Open
WebUI. Open WebUI uses only the gateway OpenAI endpoint: native Ollama and
browser direct connections are disabled, environment configuration is enforced
on restarts, and public signup is disabled. Initial admin credentials are
removed from the runtime environment after account bootstrap. The virtual key
remains in a root-only environment file and Docker metadata visible to root.
It is never put in instance user-data, command arguments, or diagnostic output.

From your computer, visit http://SERVER_PUBLIC_IPV4:3000 and sign in using
your administrator EMAIL. SSH can be closed after configuration.
Select llama-lab. The flow is:
  browser -> HTTP port3000 -> Open WebUI -> FortiAIGate -> Ollama

For an older tunnel-based installation, follow the existing-lab upgrade in
README-aws.txt. Adding a security-group rule alone does not change its old
loopback-only Docker binding. The installer retains model/chat volumes and
existing account state on reruns; run Configure afterward.

Useful commands on the Ollama host:
  sudo ollama-lab status
  sudo ollama-lab verify
  sudo ollama-lab logs
  sudo ollama-lab configure       (automatic AWS setup; preserve chats)
  sudo ollama-lab configure --manual  (custom URL/certificate/browser settings)

Readiness JSON states: running, ready, configuring, configured, failed.
ready/100 means the MODEL backend is ready and gateway configuration is pending.
configured/100 means gateway chat and WebUI health checks succeeded.
Neither state proves guardrail enforcement. Find the test request in FortiAIGate
traffic logs, check active live scanning and test a matching blocking policy.
CPU gateways may pass traffic while live scanning remains disabled, as observed
in the original Docker lab. A CPU-powered model backend does not change that.

Verification limits: automated tests use isolated file/network/Docker mocks;
this script has not created an EC2 instance or run a live cloud deployment.

Primary references (checked 2026-11-01):
https://docs.ollama.com/docker
https://docs.ollama.com/openai
https://ollama.com/library/llama3.2:1b
https://github.com/ollama/ollama/releases/tag/v0.40.13
https://github.com/open-webui/open-webui/releases/tag/v0.12.5
https://docs.openwebui.com/reference/env-configuration/
https://docs.docker.com/engine/install/ubuntu/
https://docs.docker.com/engine/network/port-publishing/
