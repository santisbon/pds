# PDS

A Helm chart for deploying a self-hosted [AT Protocol](https://atproto.com/guides/understanding-atproto) PDS (Personal Data Server) to Kubernetes, giving you full ownership of your [account](https://overreacted.io/a-social-filesystem/). A PDS provides the identity and data services in the protocol's [architecture](https://atproto.com/articles/atproto-for-distsys-engineers).

- Designed for both homelab environments and cloud deployments. For users looking to host their PDS with **container orchestration** and **distributed block & object storage**. It also provides easy-to-use scripts for managing the PDS
- Tested with [MicroK8s](https://canonical.com/microk8s) + [MicroCeph](https://canonical.com/microk8s/docs/how-to-ceph) on a 3-node cluster of [Raspberry Pi 4](https://www.raspberrypi.com/products/) devices running Ubuntu Server 26.04. It should work with little to no modifications for any Kubernetes distribution, StorageClass, and S3-compatible endpoint
- Blobs (media, avatars, video) are stored in MicroCeph's S3-compatible RGW object store. Account data and per-user repos use SQLite on a Ceph RBD PVC
- Access from the Internet is provided by a [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/) so no open inbound ports or router configuration needed. This has additional benefits like a WAF and DDoS protection

## Table of contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [TL;DR](#tldr)
- [Install](#install)
  - [RGW endpoint inside the cluster](#rgw-endpoint-inside-the-cluster)
  - [Email (Resend)](#email-resend)
- [Key config values](#key-config-values)
- [Publishing the chart](#publishing-the-chart)
  - [OCI registry (recommended)](#oci-registry-recommended)
    - [MicroK8s built-in registry](#microk8s-built-in-registry)
    - [GitHub Container Registry (GHCR)](#github-container-registry-ghcr)
  - [Versioning](#versioning)
- [The `goat` CLI](#the-goat-cli)
- [Custom handles](#custom-handles)
- [Adding a personal rotation key](#adding-a-personal-rotation-key)
  - [When does key loss become permanent?](#when-does-key-loss-become-permanent)
- [Backing up your repo](#backing-up-your-repo)
- [Creating accounts](#creating-accounts)
- [Listing accounts](#listing-accounts)
  - [Checking a single account](#checking-a-single-account)
  - [Listing invite codes](#listing-invite-codes)
- [Requesting an email confirmation](#requesting-an-email-confirmation)
- [Deactivating an account](#deactivating-an-account)
- [Deleting a user](#deleting-a-user)
  - [Tombstoning the DID](#tombstoning-the-did)
- [Production notes](#production-notes)
- [Rotating secrets](#rotating-secrets)
  - [Rotating the PLC rotation key](#rotating-the-plc-rotation-key)
- [Uninstall](#uninstall)
  - [Cloudflare Tunnel cleanup](#cloudflare-tunnel-cleanup)
- [Glossary](#glossary)

## Architecture

![Architecture](pds-architecture.drawio.svg)

The [PDS](https://github.com/bluesky-social/pds) image (`ghcr.io/bluesky-social/pds`) runs on port 3000. Caddy from the upstream compose file is replaced by the Cloudflare Tunnel. TLS terminates at the Cloudflare edge, the tunnel carries plain HTTP to the ClusterIP service inside the cluster, and WebSockets are supported natively by the tunnel.

If you want to set up your own low-cost, quiet, energy-efficient, tiny, cloud-native homelab as a Raspberry Pi cluster make sure each node:
- Has at least 8GB memory (for control plane nodes) or 4GB (for worker nodes) so you have room to grow and host other projects. The PDS pod uses about 135 Mi + 20-40 Mi for each of the two cloudflared replica pods
- Is flashed with the USB Boot utility. You can use the [Raspberry Pi Imager](https://www.raspberrypi.com/software/) for this
- Boots from an SSD. If using a SATA drive connected to a Pi USB port, use a cable/adapter that has an **ASMedia** chipset
- Has [`cgroups`](https://canonical.com/microk8s/docs/install-raspberry-pi) enabled

## Prerequisites

- MicroCeph cluster
- S3-compatible storage e.g. MicroCeph RGW enabled on at least one node (`sudo microceph enable rgw --port 7480`)
- MicroK8s cluster with:
  - `rook-ceph` addon enabled and connected to MicroCeph (`microk8s connect-external-ceph`)
  - `ceph-rbd` StorageClass available and set as default
  - `ingress` addon enabled (provides `traefik-gateway` in the `ingress` namespace). Only needed if you want local LAN access via the Gateway API HTTPRoute (`httpRoute.enabled=true`, the default); not required for the Cloudflare Tunnel
- [Helm](https://helm.sh/docs/intro/install/) installed on **your workstation only**. It's a client that talks to the cluster's API server remotely via your kubeconfig; nothing needs installing on the nodes
- A kubeconfig, present on **your workstation only**. Every `helm`/`kubectl` command in this README is meant to run from there, not on a cluster node. MicroK8s bundles its own [`microk8s kubectl`](https://canonical.com/microk8s/docs/working-with-kubectl), which would let you run these commands directly on a node instead. But this README sets up a workstation-side kubeconfig specifically to avoid having to SSH into a node for every command that can just as easily run locally. From a MicroK8s control-plane node:
  ```bash
  microk8s config > kubeconfig.yaml
  ```
  Copy it to your workstation with `scp`, into `~/.kube/`:
  ```bash
  scp ubuntu@<node-ip-or-hostname>:~/kubeconfig.yaml ~/.kube/pds-cluster.yaml
  ```
  (Use a distinct filename like `pds-cluster.yaml` rather than overwriting `~/.kube/config` directly, unless this is the only cluster you use.) Its `server:` field defaults to `127.0.0.1:16443`, which only works on the node itself so replace it with a real, reachable address:
  ```bash
  sed -i 's/127.0.0.1/<node-ip-or-hostname>/' ~/.kube/pds-cluster.yaml
  ```
  Then either point `KUBECONFIG` at it directly, or merge it into `~/.kube/config`:
  ```bash
  export KUBECONFIG=~/.kube/pds-cluster.yaml
  # or, to merge into your existing config:
  KUBECONFIG=~/.kube/config:~/.kube/pds-cluster.yaml kubectl config view --flatten > /tmp/merged.yaml \
    && mv /tmp/merged.yaml ~/.kube/config
  ```
  Verify with `kubectl get nodes`
- A public domain name managed in [Cloudflare](https://www.cloudflare.com). This chart uses the domain's apex (e.g. `yourdomain.com`) as `config.hostname`, so default user handles are one level down (`you.yourdomain.com`); covered by Cloudflare's free Universal SSL wildcard (`*.yourdomain.com`) with no extra setup. If you'd rather run the PDS under its own subdomain (e.g. `pds.yourdomain.com`), user handles become second-level (`you.pds.yourdomain.com`), which that free wildcard does not cover; you'd then need either Cloudflare's Total TLS (requires the paid Advanced Certificate Manager) or to delegate that subdomain as its own Cloudflare zone so it gets its own Universal SSL wildcard
- [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/) installed on **your workstation only** (or wherever you run the one-time setup commands from: `tunnel login`/`create`/`route dns`/`list`; `login` needs a browser). Not needed on the cluster/nodes: the tunnel that actually runs continuously is a separate, containerized `cloudflared` this chart deploys in-cluster (image `cloudflare/cloudflared`), unrelated to anything installed locally
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html) installed on **your workstation only**. It just needs network access to RGW's endpoint (the node's LAN IP:7480) to create the blob bucket; nothing runs in-cluster
- [Node.js](https://nodejs.org/en/download) and npm, `jq`, and `curl` installed on **your workstation only**, used by the scripts in `scripts/` (account management, backups, PLC operations). They talk to the PDS's public HTTPS endpoint from wherever you run them, nothing needs installing in-cluster. `scripts/add-rotation-key.sh`, `scripts/generate-plc-rotation-key.sh`, and `scripts/tombstone-did.sh` additionally install [`@atproto/crypto`](https://www.npmjs.com/package/@atproto/crypto)/[`@did-plc/lib`](https://www.npmjs.com/package/@did-plc/lib) into a scratch directory on demand; no persistent install needed

## TL;DR

```bash
# 0. Generate `my-secrets.yaml` with random credentials.
bash scripts/gen-secrets.sh

# 1. SSH into a node in the MicroCeph cluster and create RGW user.
# Paste the access_key / secret_key from output into `my-secrets.yaml`
sudo radosgw-admin user create --uid=pds --display-name=pds

# 2. Create the blob bucket. 
# Your AWS CLI must be configured. Credentials and endpoint are read from the named profile in ~/.aws/config and ~/.aws/credentials
aws s3 mb s3://pds-blobs --profile <profile>

# 3. Create a Cloudflare Tunnel
cloudflared tunnel login

# Replace with your domain
APP_DOMAIN=yourdomain.com

TUNNEL_ID=$(cloudflared tunnel create -o json pds | jq -r '.id')
# PDS requires two DNS records. 
# The wildcard record is required so that other ATProto services can verify user handles of the form `you.yourdomain.com`.
# 1. The PDS itself
cloudflared tunnel route dns pds $APP_DOMAIN
# 2. Wildcard for user handles
cloudflared tunnel route dns pds "*.$APP_DOMAIN"

kubectl create namespace pds

kubectl create secret generic cloudflared-credentials \
  --from-file=credentials.json=$HOME/.cloudflared/$TUNNEL_ID.json \
  --namespace pds

# 4. Edit my-secrets.yaml and fill in 
# blobstoreAccessKeyId / blobstoreSecretAccessKey, 
# emailSmtpUrl, emailFromAddress.

# 5. Package and push the chart to your own registry like GHCR (skip this step if
# you'd rather install directly from my published chart in step 6, instead of publishing your own copy)
helm package charts/pds
gh auth refresh -s write:packages
gh auth token | helm registry login ghcr.io --username <github-user> --password-stdin
helm push pds-*.tgz oci://ghcr.io/<github-user>/charts

# 6. Install from GHCR - either your own registry from step 5
# (oci://ghcr.io/<github-user>/charts/pds), or mine directly. 
# Replace with your email and blob store endpoint
helm upgrade --install pds oci://ghcr.io/<github-user>/charts/pds \
  --version 0.1.0 \
  --namespace pds --create-namespace \
  --set config.hostname=$APP_DOMAIN \
  --set config.adminEmail=you@example.com \
  --set blobstore.endpoint=http://192.168.1.100:7480 \
  --set cloudflare.enabled=true \
  --set cloudflare.tunnelId=$TUNNEL_ID \
  --set cloudflare.hostname=$APP_DOMAIN \
  -f my-secrets.yaml

# 7. Get an invite code and create your account
bash scripts/create-invite-code.sh $APP_DOMAIN
# paste the printed code below
bash scripts/create-account.sh $APP_DOMAIN <username> <your-email> <invite-code>
```

Then log into [bsky.app](https://bsky.app) with your handle. The hosting provider (your domain) should be discovered automatically.

## Install

**Credentials** must be provided at install time. Use a values file (gitignored) rather than `--set` flags so they don't appear in your shell history.

The secrets script generates `jwtSecret`, `adminPassword`, and `plcRotationKey` automatically, and leaves placeholders for the RGW blob storage credentials you need to fill in manually.

**Important:** Back up `credentials.plcRotationKey` outside the cluster. This is one key for the whole server; not one per user. It is the server's signing authority for all `did:plc` operations: user DIDs are created on `plc.directory` at account-creation time with this key listed as the rotation authority, and any future DID update (handle change, PDS migration) must be signed by it. Loss means no DID updates are possible for any account on this PDS — see [When does key loss become permanent?](#when-does-key-loss-become-permanent) for the exact conditions and how a personal rotation key changes the picture.

### RGW endpoint inside the cluster

MicroCeph RGW runs on the node host network, not as a Kubernetes pod. Use the node's LAN IP address as `blobstore.endpoint`, not the `.local` mDNS hostname; mDNS does not resolve inside pods.

If your RGW endpoint is deployed to `node-01`:
```bash
# Find node-01's LAN IP
kubectl get node node-01 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
```

Then set `--set blobstore.endpoint=http://<node-01-ip>:7480`.

### Email (Resend)

The PDS sends email for account verification. [Resend](https://resend.com) works well for this. Resend uses API keys for SMTP. The username is always the literal string `resend` and the password is an API key.

1. In the Resend dashboard, go to **Domains** → **Add Domain**. Use a subdomain like `mail.yourdomain.com` rather than the apex. Since the apex is `config.hostname` here (the PDS itself and every user handle), adding it as a Resend domain too works but mixes concerns unnecessarily; a dedicated subdomain keeps email DNS records separate from PDS/handle DNS records
   - After adding the domain, Resend shows you the DNS records to create (SPF TXT, DKIM CNAMEs, optionally DMARC). Add those at your DNS provider, then click **Verify DNS Records** in Resend. Propagation usually takes a few minutes to an hour. For some DNS providers like Cloudflare, Resend can ask you to log in and can configure the DNS records automatically
2. Go to **API Keys** → **Create API Key** (Sending access is sufficient). Copy the key; it starts with `re_`

Fill in the `credentials.emailSmtpUrl` and `config.emailFromAddress` placeholders that `scripts/gen-secrets.sh` already added to `my-secrets.yaml` (avoid `--set` to keep the API key off your bash history):

```yaml
credentials:
  emailSmtpUrl: "smtps://resend:re_YOUR_API_KEY@smtp.resend.com"
config:
  emailFromAddress: "noreply@mail.yourdomain.com"
```

`smtps://` uses port 465 with implicit TLS. The `From` domain in `emailFromAddress` must exactly match the domain verified in the Resend dashboard. A parent-domain match isn't sufficient (e.g. verifying `mail.yourdomain.com` does not authorize sending from `noreply@yourdomain.com`).

**Branding in emails:** every account email (email address confirmation, password reset, account deletion, PLC operation) includes a header logo (110px) and a small 24px "mark" image in the corner, each with `alt="{{serviceName}}"`. Left unset, `config.serviceName` defaults to `"<hostname> PDS"`, and the two images default to **two different built-in Bluesky assets**: the blue butterfly + "Bluesky" wordmark for the header, and a separate small black butterfly for the corner mark. If your mail client blocks remote images from an unfamiliar sending domain (common default behavior), you'll see the alt text instead: `"yourdomain.com PDS"`, which can look like garbled/truncated text in the small space it's rendered in.

Set `config.serviceName`, `config.homeUrl`, and `config.logoUrl` to replace the defaults with your own branding. Note `logoUrl` only exposes a single override: once set, it replaces **both** the header logo and the corner mark with that same one image (just rendered at different sizes). You can't configure two separate custom images the way the two *defaults* happen to be two separate images.

**Format and size for `logoUrl`:** no server-side validation at all. It's a raw string dropped straight into an `<img src="...">` attribute, so "supported" just means whatever recipients' email clients render. Stick to **PNG, JPEG, or GIF**; avoid SVG (blocked by many clients) and WebP (inconsistent support). Display size is fixed by the template's CSS, not your file's native dimensions: `width:110px` for the header slot, `width:24px` for the corner mark slot, each auto-scaling height to preserve aspect ratio. So ~250–330px wide source images (2–3× the larger slot, for retina) are plenty; there's no benefit to going bigger. Because the same image fills both differently-shaped slots, a roughly square image (near 1:1 aspect ratio) holds up better at both sizes than a wide wordmark-style logo, which would shrink to an unreadable sliver at 24px.

RGW isn't an option for hosting it: `blobstore.endpoint` is a private LAN address, never exposed through the Cloudflare Tunnel, so it's unreachable from wherever your email recipients actually are. Simplest fix is hosting it wherever this repo's other static image already lives: committed to this repo at the root level and served via GitHub's raw content host, no extra infrastructure needed:

```bash
--set config.logoUrl=https://raw.githubusercontent.com/<github-user>/pds/main/at-mark.png
```

## Key config values

| Value | Default | Description |
|---|---|---|
| `image.tag` | `"0.4"` | PDS image tag |
| `config.hostname` | `""` | **Required:** public hostname without scheme (e.g. `yourdomain.com`) |
| `config.adminEmail` | `""` | Public admin contact email (`PDS_CONTACT_EMAIL_ADDRESS`) |
| `config.emailFromAddress` | `""` | From address for outbound email |
| `config.serviceName` | `""` | Branding shown in emails; unset defaults to `"<hostname> PDS"` |
| `config.homeUrl` | `""` | Branding "home" link in emails; unset defaults to `https://bsky.app` |
| `config.logoUrl` | `""` | Logo/mark image shown in emails; unset defaults to Bluesky's own |
| `config.inviteRequired` | `true` | Require invite codes to create accounts |
| `config.rateLimitsEnabled` | `true` | Enable rate limiting |
| `config.blobUploadLimit` | `104857600` | Upload limit in bytes (100 MB) |
| `blobstore.bucket` | `"pds-blobs"` | S3 bucket name in RGW |
| `blobstore.endpoint` | `""` | **Required:** RGW endpoint URL (use node LAN IP, not `.local`) |
| `blobstore.region` | `"us-east-1"` | S3 region (RGW accepts any string) |
| `blobstore.forcePathStyle` | `true` | Required for RGW (no virtual-hosted style) |
| `blobstore.uploadTimeoutMs` | `""` | Max time (ms) a blob upload may take before aborting; unset uses the PDS's own default (20000) |
| `credentials.jwtSecret` | `""` | **Required:** JWT signing secret |
| `credentials.adminPassword` | `""` | **Required:** PDS admin password |
| `credentials.plcRotationKey` | `""` | **Required:** secp256k1 private key hex (back up securely) |
| `credentials.blobstoreAccessKeyId` | `""` | **Required:** RGW access key |
| `credentials.blobstoreSecretAccessKey` | `""` | **Required:** RGW secret key |
| `credentials.emailSmtpUrl` | `""` | SMTP URL for account verification email; embeds credentials, so it's here rather than under `config.*` |
| `credentials.existingSecret` | `""` | Use a pre-existing Secret instead of creating one |
| `persistence.storageClass` | `"ceph-rbd"` | StorageClass for the data PVC |
| `persistence.size` | `"5Gi"` | Data PVC size (SQLite DBs + actor stores) |
| `pdsUser.handle` | `""` | Reference: handle for your first account |
| `pdsUser.email` | `""` | Reference: email for your first account |
| `httpRoute.enabled` | `true` | Create a Gateway API HTTPRoute for local access |
| `cloudflare.enabled` | `false` | Deploy cloudflared for internet access |
| `cloudflare.tunnelId` | `""` | Required when enabled: tunnel ID |
| `cloudflare.hostname` | `""` | Required when enabled: public hostname |
| `cloudflare.credentialsSecret` | `"cloudflared-credentials"` | Secret containing `credentials.json` |
| `cloudflare.image.tag` | `"2026.6.1"` | cloudflared image tag |
| `resources.limits.memory` | `"1Gi"` | Container memory limit |
| `resources.requests.cpu` | `"200m"` | CPU request |
| `resources.requests.memory` | `"256Mi"` | Memory request |

## Publishing the chart

Helm supports two publishing models: **OCI registries** (the modern path) and **classic HTTP chart repositories**. Both are shown below.

All install commands below follow the same pattern as the local install: run `bash scripts/gen-secrets.sh` first, then supply credentials and required config at install time.

### OCI registry (recommended)

OCI lets you push charts to any container registry, including the MicroK8s built-in registry.

```bash
helm package charts/pds
```

#### MicroK8s built-in registry

The MicroK8s registry addon exposes an unauthenticated registry on port 32000 on every node. Use any node's LAN IP or host name to reach it from your laptop.

```bash
# Push (Helm 3.8+)
helm push pds-*.tgz oci://node-01.local:32000/charts --plain-http
```

View published charts:

```bash
# List all repositories in the registry
curl -s http://node-01.local:32000/v2/_catalog | jq

# List available versions of the chart
curl -s http://node-01.local:32000/v2/charts/pds/tags/list | jq

# Inspect chart metadata for a specific version
helm show chart oci://node-01.local:32000/charts/pds --version 0.1.0 --plain-http
```

Install directly from it:

```bash
helm upgrade --install pds oci://node-01.local:32000/charts/pds \
  --version 0.1.0 --plain-http \
  --namespace pds --create-namespace \
  --set config.hostname=yourdomain.com \
  --set blobstore.endpoint=http://192.168.1.100:7480 \
  --set cloudflare.enabled=true \
  --set cloudflare.tunnelId=$TUNNEL_ID \
  --set cloudflare.hostname=yourdomain.com \
  -f my-secrets.yaml
```

#### GitHub Container Registry (GHCR)

**Using the `gh` CLI** (recommended; uses credentials from `gh auth login`, no token management needed):

`gh auth login` does not request `write:packages` by default. Add it once before pushing:

```bash
gh auth status
gh auth refresh -s write:packages
```

```bash
gh auth token | helm registry login ghcr.io --username <github-user> --password-stdin

helm push pds-*.tgz oci://ghcr.io/<github-user>/charts
```

GHCR defaults new packages to private. `helm push` uses the OCI protocol which has no visibility concept, so there is no way to set it at push time. Make the package public once after the first push. It stays public for all subsequent pushes to the same package. Go to **github.com → your profile → Packages → charts/pds → Package settings → Change visibility → Public**.

View published charts:

```bash
gh api /user/packages/container/charts%2Fpds/versions --jq '.[].metadata.container.tags'
```

**Using a personal access token (PAT):** Create one at **GitHub → Settings → Developer settings → Personal access tokens** with `write:packages` to push and `read:packages` to query, then set it in your shell:

```bash
export GITHUB_TOKEN=ghp_...
```

```bash
echo $GITHUB_TOKEN | helm registry login ghcr.io --username <github-user> --password-stdin

helm push pds-*.tgz oci://ghcr.io/<github-user>/charts
```

View published charts:

```bash
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  "https://api.github.com/user/packages/container/charts%2Fpds/versions" \
  | jq '.[].metadata.container.tags'
```

Inspect chart metadata for a specific version (works with either auth method):

```bash
helm show chart oci://ghcr.io/<github-user>/charts/pds --version 0.1.0
```

Install with `helm upgrade` as shown in the TL;DR section.

### Versioning

Bump `version` in `charts/pds/Chart.yaml` before every publish. `appVersion` tracks the upstream PDS release and is independent of the chart version.

## The `goat` CLI

The upstream PDS image bundles [`goat`](https://github.com/bluesky-social/goat), a general-purpose atproto CLI, at `/usr/local/bin/goat` (built from a pinned release in the image's own Dockerfile — this chart's `image.tag` `"0.4"` ships `v0.2.2`). It's a legitimate alternative to the scripts in this repo for most account-management operations, reachable via `kubectl exec` into the PDS pod without installing anything. Run there, admin subcommands need no flags at all: `--admin-password` is picked up from the pod's own `$PDS_ADMIN_PASSWORD` env var, and `--pds-host` defaults to `http://localhost:3000`.

| Operation | `scripts/` | `goat` equivalent |
|---|---|---|
| Create invite + account | `create-invite-code.sh` + `create-account.sh` | `goat pds admin account create --handle <h> --password <p> --email <e>` — one step, auto-generates the invite internally |
| List accounts | `list-accounts.sh` | `goat pds admin account list` — DIDs and status only; does not resolve handles the way our script does |
| Check a single account's status | `check-account-status.sh` | **No equivalent.** `goat resolve <at-identifier>` only resolves DID identity/document; it doesn't check repo hosting status (active/deactivated/takendown) on a specific PDS the way `describeRepo`/`getRepoStatus` do |
| Update handle | `update-handle.sh` | `goat account login -u <identifier> -p <password>` then `goat account update-handle <new-handle>` |
| Deactivate / reactivate account | `deactivate-account.sh` / `reactivate-account.sh` | `goat account login ...` then `goat account deactivate` / `goat account activate` |
| Add rotation key | `add-rotation-key.sh` | `goat key generate --type secp256k1`, `goat account login ...`, `goat account plc request-token`, `goat account plc add-rotation-key <pubkey> --first --token <token>` |
| Derive/verify a rotation key's `did:key` | `check-rotation-key.sh` | `goat key inspect <key>` — same idea (parses a key and prints its `did:key`), but only accepts multibase-encoded keys, not the raw hex this chart generates (`openssl rand -hex 32`); also takes the key as a CLI argument rather than prompting interactively, which is worse for shell-history hygiene with a private key |
| Generate a new **server** PLC rotation keypair ([rotation](#rotating-the-plc-rotation-key) step 1) | `generate-plc-rotation-key.sh` | `goat key generate --type secp256k1` — same curve, but prints the private key in multikey/multibase format to stdout rather than writing `{didKey, privHex}` as JSON to disk; you'd have to convert it to the raw hex `credentials.plcRotationKey` expects yourself |
| Add the new server key to an account, old key still active ([rotation](#rotating-the-plc-rotation-key) step 2) | `authorize-plc-rotation-key.sh` | `goat account login ...`, `goat account plc request-token`, `goat account plc add-rotation-key <new-pubkey> --token <token>` — same idea, but only supports appending at the end or `--first` (index 0); no way to insert at an arbitrary index the way our script does (right after the old server key, to preserve its priority relative to any other keys) |
| Remove the old server key from an account, new key already active ([rotation](#rotating-the-plc-rotation-key) step 5) | `deauthorize-plc-rotation-key.sh` | **No equivalent.** `goat account plc` has no remove/delete-rotation-key subcommand at all — closest path is the lower-level `goat account plc current` (fetch), hand-editing the JSON yourself to drop the key, then `goat account plc sign <file> --token <token>` + `goat account plc submit <file>` |
| Swap the server's own `credentials.plcRotationKey` ([rotation](#rotating-the-plc-rotation-key) step 4) | `rotate-plc-rotation-key.sh` | **No equivalent.** This is a Helm/Kubernetes operation (`helm upgrade` + `kubectl rollout restart`) on this chart's own deployment, not an AT Protocol account operation `goat` operates on |
| Back up a repo | `backup-repo.sh` | `goat repo export <at-identifier>` |
| Restore a repo | `restore-repo.sh` | `goat account login -u <identifier> -p <password>` then `goat repo import <car-file>` |
| Upload missing blobs after a restore | `upload-missing-blobs.sh` | **No direct equivalent.** `goat account migrate` bundles this (via `com.atproto.sync.listBlobs` on the old PDS, re-uploading all of them) into a single end-to-end account-migration command, rather than exposing it as a standalone step usable after our modular `restore-repo.sh` |
| Delete account (admin) | `delete-account-admin.sh` | `goat pds admin account delete <did-or-handle>` |
| Delete account (self-service) | `delete-account-self.sh` | **No equivalent.** `goat account` only exposes `deactivate`, not the emailed-token `requestAccountDelete`/`deleteAccount` pair |
| Tombstone a DID | `tombstone-did.sh` | **No equivalent.** `goat`'s PLC code only rejects building an update on top of an already-tombstoned op; it never creates one |
| List invite codes | `list-invite-codes.sh` | **No equivalent.** `goat pds admin create-invites` only generates codes; nothing lists or inspects existing ones |
| Disable an invite code | `disable-invite-code.sh` | **No equivalent.** |
| Request email confirmation | `request-email-confirmation.sh` | **No equivalent.** No email-related commands in `goat` at all |

**Security posture differs from our scripts.** `goat account login` writes both the app password and the resulting session tokens to `$XDG_STATE_HOME/goat/auth-session.json`, in cleartext — [`goat`'s own README warns about this explicitly](https://github.com/bluesky-social/goat#readme) — and that session persists until you run `goat account logout`. Which disk depends on where you run it:
- **Via `kubectl exec` into the pod** (using the binary already baked into the image, as described above): the file lands inside the **PDS container's own filesystem** — here that's `/root/.local/state/goat/auth-session.json`, since the container runs as `root`. That path isn't part of the `/pds` PVC, so it's on the container's ephemeral writable layer and won't survive a pod restart or reschedule — but while the pod is alive, anyone with `kubectl exec` access to that pod/namespace can read it
- **Installed locally** (`brew install goat` / `go install`) and run from your own machine against `https://yourdomain.com`: the same file lands on **your workstation** instead, completely outside the cluster

Our scripts never persist anything either way: they prompt for passwords and emailed tokens interactively each run and hold them only in memory for that one invocation.

One more gotcha if you use `goat key generate` for a rotation key: it defaults to the P-256 curve, not secp256k1. PLC does accept P-256 rotation keys, but it won't match the secp256k1 key `scripts/add-rotation-key.sh` generates. Pass `--type secp256k1` if you want parity. Both curves are equally secure; secp256k1 is preferred here purely for consistency with the existing ecosystem (the server's own `plcRotationKey`, `@atproto/crypto`, `@did-plc/lib`), not because P-256 is weaker.

## Custom handles

Users get a default handle under the PDS hostname (e.g. `you.yourdomain.com`). If a user controls their own domain they can use it as their handle instead. No Bluesky involvement required, everything goes through your PDS.

For handles under your PDS's own service domain (e.g. `you.yourdomain.com`), the PDS rejects any first label matching a static, hardcoded reserved list baked into the upstream image. See [`reserved.ts`](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/handle/reserved.ts). Not configurable via chart values. This list does not apply to custom domains (below); those are validated by DNS/HTTP ownership proof instead, not the reserved list.

A custom handle doesn't need a subdomain. A bare root domain (e.g. `example.com` instead of `alice.example.com`) works the same way, since the PDS treats anything outside its own service domain as a custom domain and checks ownership by resolving it back to your DID rather than applying service-domain constraints.

**Which method gets checked, and when:**

- **Fresh signup** (`create-account.sh` / `com.atproto.server.createAccount`, not bringing your own DID) can only ever get a service-domain handle. The PDS's own handle validation ([`normalizeAndValidateHandle`](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/account-manager/account-manager.ts)) unconditionally rejects any non-service-domain handle when there's no DID yet. Neither proof method is even looked up at this point. A custom handle is only reachable afterward, via `updateHandle` (Step 2 below). This is a general rule, not specific to the bare-domain case below
- **`updateHandle`** (Step 2) and **account migration** (bringing an existing DID into `createAccount`) do actively check: the PDS's [`HandleResolver`](https://github.com/bluesky-social/atproto/blob/main/packages/identity/src/handle/index.ts) races a DNS TXT lookup against an HTTPS fetch of the well-known file in parallel, and accepts whichever resolves to your DID first. DNS TXT wins outright if it answers before the HTTP request does (the fetch is aborted at that point). The well-known result is only used if DNS didn't resolve at all so publishing either proof alone is sufficient. Publishing both just means DNS TXT usually decides it. Migrating an existing custom-handle account to this PDS re-runs this exact check before the account is created here, same as a plain `updateHandle` call

**Choosing between the two methods below:** DNS TXT needs only access to your domain's DNS records. No web server required at that hostname at all, which matters if the domain (or bare handle) isn't hosting anything else. The well-known file needs something already serving HTTPS there; simpler to swap without touching DNS if you have static hosting in place already, and a change takes effect the moment the file changes rather than waiting on DNS propagation. Either is fully sufficient on its own and picking one is purely about which is easier to publish in your setup.

**Special case: switching to your PDS's own bare domain as your handle** (e.g. account is `something.yourdomain.com`, you want `yourdomain.com`). Use the DNS TXT method below, not the well-known file. The PDS's own `/.well-known/atproto-did` handler treats requests to its bare hostname as a lookup for a local account whose handle is *already* exactly that hostname. But during the update your account's handle is still the old one, so that lookup fails and the update can never pass verification (a chicken-and-egg problem). DNS TXT resolution doesn't touch the PDS at all, so it sidesteps this entirely.

**Step 1 — Prove domain ownership.** Choose one method:

DNS TXT record on the user's domain:
```
_atproto.alice.example.com  TXT  "did=did:plc:xxxx"
```

Verify it's live before moving on to step 2 (DNS propagation can lag, and this checks the record directly rather than through the PDS's own resolution, which also races the well-known file and could mask a TXT record that isn't actually resolving yet):
```bash
dig +short TXT _atproto.alice.example.com
```

Or a file served at the user's domain:
```
https://alice.example.com/.well-known/atproto-did
```
containing only the bare DID string (e.g. `did:plc:xxxx`). No JSON, no wrapper.

The user's `did:plc` is returned in the `createAccount` response, or can be retrieved later:
```bash
curl -s "https://yourdomain.com/xrpc/com.atproto.identity.resolveHandle?handle=you.yourdomain.com" \
  | jq -r '.did'
```

**Step 2 — Update the handle.** The user authenticates as themselves (not admin). `scripts/update-handle.sh` logs in and calls `updateHandle`, prompting for the account password rather than taking it as an argument:

```bash
bash scripts/update-handle.sh yourdomain.com you.yourdomain.com alice.example.com
```

The PDS verifies the DNS/HTTP proof resolves to the user's DID, then signs and publishes the handle update to `plc.directory` using the server's `plcRotationKey`.

## Adding a personal rotation key

By default the server's `plcRotationKey` is the only signing authority for your `did:plc`. If this PDS disappears, no one can sign DID updates for your account, including an update pointing to a new PDS. Adding your own rotation key at index 0 (higher authority than the server's key) lets you sign those updates yourself.

`scripts/add-rotation-key.sh` runs the whole flow: generates a secp256k1 keypair encoded as a `did:key` (via a scratch install of `@atproto/crypto`; this encoding is AT Protocol-specific, not a plain openssl one-liner), logs you in to your PDS account (`com.atproto.server.createSession`, prompting for your account password), fetches the server's current rotation key as its public `did:key` from `plc.directory/<did>/data` (`rotationKeys[0]`, since no personal key has been added yet), requests an emailed confirmation token (prompting you for it interactively), then signs and submits the PLC operation to your PDS (`com.atproto.identity.submitPlcOperation`, which relays it on to `plc.directory`) with your key at index 0 and the server's at index 1:

```bash
bash scripts/add-rotation-key.sh yourdomain.com you.yourdomain.com
```

It prints the new `did:key` and private key hex before doing anything else. Store that hex in a password manager or hardware key immediately, since it's shown only once. At the end it prints the account's `rotationKeys` from `plc.directory` so you can confirm your `did:key` landed at index 0.

### When does key loss become permanent?

Every PLC operation (other than the genesis create) must be signed by a key already listed in that specific account's *current* `rotationKeys` (verified in [`did-method-plc`'s `assureValidSig`](https://github.com/did-method-plc/did-method-plc/blob/main/packages/lib/src/operations.ts#L263)). A signature from any other key is simply rejected; there's no fallback path. That one rule produces three distinct ways signing ability is lost, each with a different blast radius:

1. **The server rotates `plcRotationKey` without first authorizing the new key on an account.** The server still holds *working* key material here; it's just not yet authorized for that account. Two ways out: revert `credentials.plcRotationKey` back to the old value (the old key is still listed in `rotationKeys`, so it still signs validly), or use another rotation key already on the account to authorize the new one. Only becomes permanent if you've also discarded the old key *and* the account has no other rotation key
2. **The server's `plcRotationKey` is lost outright** (secret deleted, no backup, disaster) with no personal key ever added to an account. This is a strictly worse position than #1: there's no "old key" to revert to, because the lost key *is* the one that was authorized so the revert option in #1 doesn't exist here at all. The only possible recovery is an independently-held rotation key already on the account signing a new op to install a replacement. Without one, this is immediately unrecoverable. This is exactly why the callout above says to back this key up
3. **A rotation key is compromised and used to sign a malicious/conflicting operation.** A higher-priority key (one listed *earlier* in `rotationKeys`) can nullify it, but only within a 72-hour window from when the malicious op first appeared ([`did-method-plc`'s `RECOVERY_WINDOW`/`LateRecoveryError`](https://github.com/did-method-plc/did-method-plc/blob/main/packages/lib/src/data.ts#L77)). If you miss that window the malicious operation becomes permanently canonical. **If the compromised key is already the highest-priority one (index 0), there is no higher key to ever invoke this recovery. Confirmed directly in [`did-method-plc`'s source](https://github.com/did-method-plc/did-method-plc/blob/main/packages/lib/src/data.ts#L62): the set of "more powerful keys" it checks against is `rotationKeys.slice(0, indexOfSigner)`, which is empty when the signer is already at index 0.** Compromise of the top key is permanent. There's no window or override

Adding a personal rotation key (above) protects you against #1 and #2 for that account. It's a fallback that doesn't depend on the server at all. But it does *not* create a new failure mode for scenario #3; it just moves the account's single point of failure from the server's key to your personal key's private hex. Guard that hex accordingly (password manager or hardware key, per above). It's now the one thing standing between you and an unrecoverable lockout for that account.

To later confirm a stored private key hex (e.g. pulled back out of a password manager) actually matches the `did:key` you expect before trusting it for a real recovery or rotation, use `scripts/check-rotation-key.sh`. It prompts for the hex (never take it as a command-line argument; that would land in shell history), derives its public `did:key` via the same `@atproto/crypto` encoding, and prints it or compares it against an expected value if you pass one:

```bash
bash scripts/check-rotation-key.sh                    # just print the derived did:key
bash scripts/check-rotation-key.sh did:key:zQ3sh...   # compare, exits non-zero on mismatch
```

## Backing up your repo

Your AT Protocol repo is a content-addressed data structure (a CAR file) containing all your posts, follows, likes, and other records. Export it with:

```bash
bash scripts/backup-repo.sh yourdomain.com you.yourdomain.com
```

Writes to `<handle>.car` by default, or pass a third argument for a different output path. The endpoint is unauthenticated so no JWT needed. Run this periodically so a backup is available if the PDS goes offline unexpectedly.

To **restore on a new PDS**, once your account exists there, `scripts/restore-repo.sh` logs in as that account and uploads the CAR file via `com.atproto.repo.importRepo`:

```bash
bash scripts/restore-repo.sh newdomain.com you.newdomain.com you.yourdomain.com.car
```

This restores repo records (posts, likes, follows, etc.) only. Blobs (avatars, media) referenced by those records aren't part of the CAR file and need to be re-uploaded separately. `scripts/upload-missing-blobs.sh` handles this: it logs in to the new PDS, calls `com.atproto.repo.listMissingBlobs` to find exactly which blob CIDs the imported records reference but don't yet have bytes for, fetches each one from the old PDS via the unauthenticated `com.atproto.sync.getBlob`, and re-uploads it via `com.atproto.repo.uploadBlob` preserving the original `Content-Type`. Since blob CIDs are content hashes, uploading the same bytes reproduces the same CID and satisfies the reference without touching the imported records:

```bash
bash scripts/upload-missing-blobs.sh newdomain.com you.newdomain.com yourdomain.com
```

Requires the old account/PDS to still be reachable. Combined with a personal rotation key (above), this gives you full account portability independent of the PDS this chart deployed. You can back up, restore to a new PDS, and sign the DID update yourself even if this one disappears.

## Creating accounts

With the default `config.inviteRequired=true`, an admin-generated invite code is required before anyone can create an account. `scripts/create-invite-code.sh` fetches the admin password from the cluster Secret and calls `com.atproto.server.createInviteCode`:

```bash
bash scripts/create-invite-code.sh yourdomain.com
```

Prints the generated code. Pass a second argument to set the code's use quota (default `1`, i.e. single-use).

With a code in hand, `scripts/create-account.sh` calls the self-service `com.atproto.server.createAccount` endpoint. No admin auth needed since the invite code itself is the authorization:

```bash
bash scripts/create-account.sh yourdomain.com <username> <your-email> <invite-code>
```

`<username>` becomes the first label of the account's handle (`<username>.yourdomain.com`). A password is generated randomly if you don't pass one as a fifth argument. The script prints the handle, password, and server address on success — the same output shown in the TL;DR section.

## Listing accounts

`com.atproto.sync.listRepos` (enumerates DIDs hosted by the PDS) and `com.atproto.repo.describeRepo` (resolves a DID to its current handle) are both unauthenticated. Listing accounts is a public capability of the network, not an admin-only one. `scripts/list-accounts.sh` wraps both calls and handles `listRepos`' cursor-based pagination:

```bash
bash scripts/list-accounts.sh yourdomain.com
```

Prints one line per account: `handle`, `did`, `active` (`true`/`false`), `status` (`active` when active; otherwise whatever reason the server reports — `takendown`/`suspended`/`deactivated`/etc. — or `unspecified` if it reports none), and `rev` (a TID marking the repo's latest commit). The API itself only populates `status` for inactive accounts, so the script fills in `active`/`unspecified` explicitly rather than leaving an ambiguous blank that could mean either. `active`/`status`/`rev` all come from the same `listRepos` response already being fetched — no extra calls needed; only `handle` requires the separate `describeRepo` lookup per account. `status` is what surfaces accounts left `deactivated` via `scripts/deactivate-account.sh` (above).

### Checking a single account

`list-accounts.sh` doesn't scale to a server the size of `bsky.social` (tens of millions of accounts). Paging through `listRepos` to find one account isn't practical. `scripts/check-account-status.sh` checks a single handle or DID directly, unauthenticated, against any PDS or entryway:

```bash
bash scripts/check-account-status.sh bsky.social jay.bsky.team
```

Built on `com.atproto.repo.describeRepo`, which accepts a handle or DID directly — no separate resolve step needed. A successful response means the account is active; the script reports `handle`, `did`, `handleIsCorrect`, and a `collections` count. A failure distinguishes `not found` / `takendown` / `deactivated` (per `describeRepo`'s own error codes) from anything else. It also opportunistically calls `com.atproto.sync.getRepoStatus` for the repo's current `rev`, but doesn't require it — some servers (e.g. `bsky.social`'s own entryway) require auth for that endpoint even though `describeRepo` doesn't, so it's included only when available.

### Listing invite codes

`com.atproto.admin.getInviteCodes` gives an admin-wide view of every invite code on the server (unlike `listRepos`/`describeRepo` above, this one needs admin auth). `scripts/list-invite-codes.sh` fetches the admin password from the cluster Secret and handles pagination:

```bash
bash scripts/list-invite-codes.sh yourdomain.com
```

Prints one line per code with its use quota, actual use count, a computed `exhausted` flag, `disabled` state, creator, and creation time. Pass `usage` as a second argument to sort by use count instead of recency.

The API's own `available` field is the code's original use quota, not a live remaining count — it never changes after creation, even once a code is fully used or its associated account is deleted (`deleteAccount` doesn't touch invite-code tables at all). The script compares quota against actual use count itself so you don't have to.

**Disabling a leaked invite code:** there is no delete endpoint for invite codes anywhere in the protocol — only `com.atproto.admin.disableInviteCodes`, which sets `disabled: true` on the row(s); it doesn't remove them. `scripts/disable-invite-code.sh` wraps it and accepts one or more codes:

```bash
bash scripts/disable-invite-code.sh yourdomain.com <code> [code2] [code3] ...
```

For a code that's already `exhausted` (see above), disabling adds little — it's already unusable. This is for revoking a code that's leaked or otherwise shouldn't be used again before its quota runs out.

## Requesting an email confirmation

Account creation never sends email on its own. None of the PDS's email templates (password reset, account deletion, email confirmation/change, PLC operation signing) are wired into `createAccount`. Each requires an explicit, self-service call to its own endpoint. To trigger a confirmation email for the account's address on file:

```bash
bash scripts/request-email-confirmation.sh yourdomain.com you.yourdomain.com
```

Rate-limited server-side to 5/hour and 15/day per account. The Bluesky app's Settings → Account usually surfaces this as a "Verify your email" prompt that calls the same endpoint, if you'd rather trigger it from there.

## Deactivating an account

A softer, fully reversible alternative to deleting an account: `com.atproto.server.deactivateAccount` stops the repo from being served and blocks further writes, but touches no data at all — it just sets a timestamp on the account's row. Its primary intended use is account migration (deactivate on the old host once the account is active on the new one), but nothing stops you from using it as a general pause. It's self-service, authenticated as the account itself (not admin), and deactivated accounts can still log in — that's what lets you reactivate.

```bash
bash scripts/deactivate-account.sh yourdomain.com you.yourdomain.com
```

`deleteAfter` (optional third argument, ISO 8601) is only a recommendation to the server for eventual cleanup, not a guarantee or a schedule it enforces.

Reverse it with:

```bash
bash scripts/reactivate-account.sh yourdomain.com you.yourdomain.com
```

## Deleting a user

There are two ways to delete an account, depending on who initiates it.

**As the PDS admin** — immediate, no confirmation token, irreversible:

```bash
bash scripts/delete-account-admin.sh yourdomain.com did:plc:xxxx
```

This unlinks the account from the account manager, notifies the sequencer, and removes the actor's files from disk. Look up the DID first with `scripts/list-accounts.sh` (above) — `resolveHandle` only works while the account still exists on this PDS, so once it's deleted the DID is hard to recover if you didn't note it down first.

**As the user themselves** — self-service, requires an emailed confirmation token. `scripts/delete-account-self.sh` prompts for both the account password and the emailed token rather than taking them as arguments:

```bash
bash scripts/delete-account-self.sh yourdomain.com you.yourdomain.com
```

Either method only deletes the account from this PDS. The `did:plc` document on `plc.directory` is untouched; the DID persists but no longer resolves to any PDS-hosted data.

### Tombstoning the DID

Deleting the PDS account does not tombstone the `did:plc` document. The DID persists indefinitely, still pointing at your (now stale) PDS endpoint and handle, unless you deliberately tombstone it. A tombstone is a special PLC operation that permanently clears all fields and deactivates the DID; it must be signed by one of the DID's current rotation keys. `scripts/delete-account-admin.sh` prints the exact next command to run.

```bash
bash scripts/tombstone-did.sh did:plc:xxxx
```

- By default this signs with the server's `plcRotationKey`, read straight out of the cluster's Secret (not pasted as a literal, so it never ends up sitting in shell history). Pass a different `[release] [namespace]` if your install isn't named `pds`/`pds`, or adapt the script if you need to sign with a personal rotation key instead
- The same 72-hour recovery window as any other PLC operation applies: a higher-authority rotation key could nullify the tombstone within that window
- Tombstoning is one-way and permanent. Only do it if you want to retire the DID for good
- The script verifies the result itself: `plc.directory/<did>` should respond `{"message":"DID not available: ..."}`, and the last audit log entry should be `plc_tombstone`

**Reusing a handle for a different DID:** tombstoning is not required for this. `createAccount`'s handle-availability check only looks at this PDS's local database, and `deleteAccount` (above) hard-deletes those rows, so the handle is immediately free to assign to a new account here, tombstoned or not. The old DID's document, if left un-tombstoned, keeps listing the handle in `alsoKnownAs` and this PDS as its `atproto_pds` service, but that claim goes stale on its own: handle verification resolves the handle to whichever DID the PDS currently associates with it, so the new account's own genesis operation is what gets verified, not the old document. Tombstoning the old DID first is still worth doing for cleanliness, since it avoids a window where AppViews or clients with cached data momentarily associate the handle with the old identity.

## Production notes

- **Domain stability:** `config.hostname` cannot be changed after first start without migrating every account individually. Choose your domain before deploying
- **PLC rotation key:** One secp256k1 private key for the entire server (not one per user). The PDS server's own identity is a `did:web` derived from `config.hostname`; no PLC key is needed for that. User accounts, however, get `did:plc` identities registered on `plc.directory` at account-creation time. Each genesis operation includes a `rotationKeys` list; this server key is always one of them, giving the server signing authority for future DID updates (handle changes, PDS hostname migrations). Back it up outside the cluster (password manager, hardware key). Loss means the server cannot perform DID updates for any hosted account
- **User-owned rotation keys:** A `did:plc` document supports up to 5 rotation keys ordered by descending authority (index 0 = highest). Any rotation key can sign a DID update, but within a 72-hour window a higher-authority key can dispute and override an operation signed by a lower-authority key. A user who adds their own rotation key at index 0 (via AT Protocol tooling or a Bluesky client that exposes this) and keeps the server's key at index 1 can sign DID updates independently, meaning they can migrate to another PDS even if this server loses its `plcRotationKey` or disappears entirely. Without a user-owned key, the server's key is the only rotation authority and its loss permanently freezes the account's DID
- **Email:** Without SMTP, account email verification links will not be delivered. Bluesky app clients may warn users that email is unverified
- **Blob upload timeout on resource-constrained RGW:** the PDS aborts a blob upload after `blobstore.uploadTimeoutMs` (default 20000ms upstream) if the S3 blobstore hasn't finished accepting it. On a resource-constrained RGW node (e.g. a Raspberry Pi also carrying mon/OSD/control-plane duties), a burst of concurrent uploads, such as an account migration via a tool, can push individual PUTs past that window, surfacing as `500 Internal Server Error` / `Blob upload timed out` in the migration tool's console (and sometimes a misleading CORS error alongside it, if the connection drops before any response headers arrive) even though the underlying Ceph cluster is healthy. Raise `blobstore.uploadTimeoutMs` (e.g. `60000`) on constrained hardware to give it more headroom
- **Wildcard DNS:** `*.yourdomain.com` must resolve to the tunnel so user handles are verifiable by other ATProto services. DNS resolving is not sufficient on its own if `config.hostname` is a subdomain rather than the apex. See [Prerequisites](#prerequisites); without Total TLS (or zone delegation) in that case, Cloudflare drops the TLS handshake for user handles before the request reaches the tunnel, even though the root PDS hostname itself works fine
- **Uptime monitoring:** point an HTTP(s) monitor (e.g. [Uptime Kuma](https://github.com/louislam/uptime-kuma), which you can easily deploy with [my chart](https://github.com/santisbon/uptime)) at `https://yourdomain.com/xrpc/_health`, expecting a `200` status. This is the same unauthenticated endpoint this chart's own liveness/readiness probes use, and checking the public hostname (not an internal ClusterIP) validates the full path: Cloudflare edge → tunnel → Service → pod — rather than just "the pod is alive". It's worth setting up alerts too so you'll know immediately if it goes down (see my Uptime Kuma chart for details)
- **[Litestream](https://github.com/benbjohnson/litestream):** Not included in this chart but worth considering for critical workloads like running a paid service hosting customer AT Protocol accounts. The PDS keeps three shared databases (`account.sqlite`, `sequencer.sqlite`, `did_cache.sqlite`) plus a **separate SQLite file per user account** under `actors/<hash>/<did>/store.sqlite` — a new one appears every time someone signs up. Litestream (`v0.5.3+`) has a directory-replication mode built for exactly this "multi-tenant databases" case: point it at the `actors/` tree with `watch: true` and it discovers and streams new per-user files as they're created, alongside static entries for the three shared DBs.

  What it would actually get you over Ceph RBD's 3× block-level replication ([replicated, not erasure-coded, per Canonical's own guidance for latency-sensitive workloads](https://github.com/canonical/microceph/blob/main/docs/snap/explanation/canonical-ceph-reference-architecture/replication-vs-erasure-coding.rst)): Ceph protects against a single disk/node failing *within this cluster*. All three replicas are identical, in the same place, updated instantly, including any corruption or bad write. It's not point-in-time recovery, and it's gone along with everything else if the PVC itself is deleted (e.g. `helm uninstall`, see Uninstall below) or if the whole cluster is lost. Litestream instead continuously streams the WAL to an external destination (ideally off-cluster/off-site), giving you (1) survivability independent of this cluster/PVC entirely, and (2) a rollback history you can restore to a point *before* a bad migration, accidental deletion, or corruption — something Ceph's replication can't give you, since it just replicates whatever was written, good or bad, everywhere, immediately. It's a genuine addition, not a duplicate of what Ceph already does; it only covers the SQLite side, not the RGW-hosted blobs
- **No automatic image updates:** the [upstream reference `compose.yaml`](https://github.com/bluesky-social/pds/blob/main/compose.yaml) runs a [Watchtower](https://github.com/nicholas-fedor/watchtower) container that auto-updates the PDS nightly. This chart has no equivalent as `image.tag` and `cloudflare.image.tag` in `values.yaml` are pinned and change only when you bump them and run `helm upgrade`. Watchtower itself is a poor fit for Kubernetes. [Its README says](https://github.com/nicholas-fedor/watchtower#readme) that it's not recommended for commercial or production use at all, pointing production/Kubernetes users elsewhere instead. It requires a Docker Engine API (typically the Docker socket; MicroK8s runs containerd instead, so there isn't one), and even where Docker is available it mutates containers directly (pull image, stop container, restart with the same options) rather than through the Kubernetes API, bypassing rolling updates and causing drift from the cluster's declared state. None are included in this chart, but these are ways to automate image updates properly in Kubernetes/GitOps workflows instead:
  - **[Flux's image-automation controller](https://github.com/fluxcd/flux2)** — part of Flux CD; updates image references in your Git repo's manifests and lets Flux's normal GitOps reconciliation apply the change from there. A proper Kubernetes Operator: defines its own `ImageUpdateAutomation` CRD
  - **[Argo CD Image Updater](https://github.com/argoproj-labs/argocd-image-updater)** — a companion project for Argo CD specifically; updates image references on an Argo CD Application, either via Git or by patching the Application directly. Also a proper Kubernetes Operator, with its own CRD
  - **[Keel](https://github.com/keel-hq/keel)** — watches registries and mutates the live Deployment/StatefulSet directly, no Git involved. Runs in-cluster but works off annotations on existing resources. Technically a controller rather than an operator by strict definition (no CRDs of its own) but commonly called an operator
  - **[Renovate](https://github.com/renovatebot/renovate)** — general-purpose dependency update tool, not Kubernetes-specific. Scans a Git repo across many ecosystems (image tags, Helm charts, npm, Terraform, etc.) and opens pull requests for a human or CI to merge. Not a Kubernetes Operator — it only talks to your Git hosting platform's API, never the Kubernetes API
- This chart uses the Bluesky PDS implementation, which scales well up to around half a million users. To support tens of millions of users, Bluesky uses an interface to its many PDSs called the [Entryway](https://docs.bsky.app/docs/advanced-guides/entryway). This chart does not use an entryway

## Rotating secrets

All values under `credentials.*` (including `emailSmtpUrl`, which embeds the Resend API key) can be rotated post-install. The general mechanics are the same for all of them (notice the space at the beginning of the command to keep it from your shell history):

*Replace the location of the OCI chart with your chosen registry or if you're deploying from source*
```bash
 helm upgrade pds \
  oci://ghcr.io/<github-user>/charts/pds \
  --version $VERSION \
  --namespace pds \
  --reuse-values \
  --set credentials.<field>=<new-value>
```

`--reuse-values` keeps every other existing value (including secrets) untouched, so you don't need `-f my-secrets.yaml` or to re-supply anything else on the command line. Two things apply across the board:

- **Update `my-secrets.yaml` too.** `--reuse-values` only updates the live release; if you later run a plain `-f my-secrets.yaml` install/upgrade without also updating the file, it silently rolls the secret back to the old value
- **Pods don't pick up the change on their own.** Env vars sourced from the Secret via `secretKeyRef` are only read at container start, and this chart has no checksum annotation forcing a rollout on Secret changes. After the `helm upgrade`, restart the pod:
  ```bash
  kubectl rollout restart deployment/pds -n pds
  ```
  (Safe here specifically because the Deployment uses `strategy: Recreate` in `deployment.yaml` so there's never a moment with two replicas signing or writing concurrently)

What changes safely, and what each rotation actually affects:

- **`credentials.jwtSecret`** — safe to rotate any time. Effect: every existing access/refresh token stops verifying immediately, so all logged-in users (and any script mid-session) must re-authenticate. No data impact. OAuth-based clients recover silently via a token refresh; classic app-password clients (e.g. the official Bluesky app) need a full interactive re-login, which can also surface a one-time "what's your birthday?" prompt on accounts never onboarded through Bluesky's own app. If you've already given Bluesky your birthday and it's still asking for it after rotating the JWT, clear your browser's data (history, cookies, cache) and reload the page
- **`credentials.adminPassword`** — safe, no user-facing impact. The admin-authenticated scripts (`list-invite-codes.sh`, `disable-invite-code.sh`, `delete-account-admin.sh`, etc.) fetch the password fresh from the cluster Secret on every run, so there's nothing else to update
- **`credentials.blobstoreAccessKeyId` / `credentials.blobstoreSecretAccessKey`** — RGW supports multiple active keys per user, so rotate without a gap:
  1. Add a new key alongside the existing one (don't remove the old one yet): `sudo radosgw-admin key create --uid=pds --key-type=s3 --gen-access-key --gen-secret`
  2. `helm upgrade` both fields, then `kubectl rollout restart`
  3. Verify blob uploads still work (e.g. change an avatar from a Bluesky client, or watch `kubectl logs` for blobstore errors)
  4. Only then remove the old key: `sudo radosgw-admin key rm --uid=pds --access-key=<old-access-key>`
- **`credentials.emailSmtpUrl`** (Resend API key) — create the new key in the Resend dashboard first, `helm upgrade` + restart, and verify with an action that triggers an email like changing your password. Then revoke the old key in Resend. Same add-before-remove order as the blobstore keys
- **`credentials.plcRotationKey`** — see [Rotating the PLC rotation key](#rotating-the-plc-rotation-key) below. Unlike the other values, this one is **not** a simple config swap

### Rotating the PLC rotation key
IMPORTANT: Read this **entire** section **before** starting to follow the steps.

This key only controls which signature the server produces for *future* `did:plc` operations. It does nothing to any account's already-published DID document. Every existing account's DID currently lists the *old* key's `did:key` in its `rotationKeys` (from [Adding a personal rotation key](#adding-a-personal-rotation-key)/[Listing accounts](#listing-accounts) context, `plc.directory/<did>/data`). If you swap in a brand-new private key without first authorizing its `did:key` on each existing account's DID, the server permanently loses the ability to sign valid PLC operations (handle changes, PDS migrations) for every pre-existing account — the same failure mode as losing the key outright (see [When does key loss become permanent?](#when-does-key-loss-become-permanent)), except self-inflicted. New accounts created *after* the swap are unaffected, since they get the new key baked into their genesis operation automatically.

This can't be done as a single swap per account, only add-then-remove. The PDS's own `submitPlcOperation` handler hard-rejects any operation whose resulting `rotationKeys` doesn't include the server's *own currently-configured* key; [confirmed directly in atproto's source](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/api/com/atproto/identity/submitPlcOperation.ts) (`"Rotation keys do not include server's rotation key"`) and its own test suite literally titles this check *"prevents submitting an operation that removes the server's rotation key"*. So you can never go straight from old to new in one operation: the server refuses to sign anything that would drop the key it's currently running. Four dedicated scripts enforce the correct add-then-remove order. Note that `scripts/add-rotation-key.sh` is a different thing — it only adds an account's *personal* key, not this fleet-wide swap of the *server's* key.

**Step 1 — generate the new keypair**

```bash
bash scripts/generate-plc-rotation-key.sh
NEW_SERVER_DID_KEY=$(jq -r .didKey ~/new-plc-key.json)
```

Writes `{didKey, privHex}` to `~/new-plc-key.json` (default path; pass a different one as the first argument). The private hex is written to disk only, never printed.

**Back up `privHex` to your password manager now**, before doing anything else. Step 4 deletes `~/new-plc-key.json` automatically once it succeeds, and if the file is lost before then (disk issue, wrong directory cleaned up, etc.) you'd have to generate a fresh keypair and redo every account's step 2. Keep your **old** server key's backup entry in the password manager too — don't overwrite or delete it until step 6 confirms every account is fully migrated. It's your only way to revert per [scenario 1 in When does key loss become permanent?](#when-does-key-loss-become-permanent) if an account gets missed below, and reverting after step 4 (before step 5 removes the old key anywhere) is still safe.

**Step 2 — for EVERY existing account, ADD the new key alongside the old one**

```bash
OLD_SERVER_DID_KEY="did:key:..."   # the current server key; find it in any account's rotationKeys, see below

bash scripts/authorize-plc-rotation-key.sh yourdomain.com you.yourdomain.com "$OLD_SERVER_DID_KEY" "$NEW_SERVER_DID_KEY"
# ...repeat for every other account on this PDS
```

Not sure what `OLD_SERVER_DID_KEY` is? Look it up from any account's current `rotationKeys`:

```bash
curl -s "https://plc.directory/<did>/data" | jq .rotationKeys
```

Each run of `authorize-plc-rotation-key.sh` logs in as that account (prompting for its password), then requests and prompts for an emailed confirmation token before submitting the PLC operation. It **adds** the new key immediately next to the old one in `rotationKeys`. It does not remove the old key yet, since the server is still running it and would reject an operation that dropped it. Every other key already on the account (e.g. a personal rotation key) is left untouched, and inserting the new key right next to the old one means it naturally lands in the old key's exact slot once step 5 removes it, preserving priority relative to any other keys.

**Step 3 — confirm every account before proceeding**

```bash
curl -s "https://plc.directory/<did>/data" | jq .rotationKeys
```

Repeat for each account's DID. Every one must show **both** `$OLD_SERVER_DID_KEY` and `$NEW_SERVER_DID_KEY` before moving on. **Do not proceed to step 4 until every account confirms**. Any account skipped here will reject all future server-signed DID updates the moment step 4 switches the server over to the new key, unless that account already has its own personal rotation key.

**Step 4 — only after ALL accounts confirm, swap the server's key**

```bash
bash scripts/rotate-plc-rotation-key.sh <chart-version>
```

*Deploying from your own registry or from source instead of `oci://ghcr.io/santisbon/charts/pds`?* Set `CHART` to override it (defaults to `oci://ghcr.io/santisbon/charts/pds`; a local path works too, e.g. `charts/pds`):

```bash
CHART=oci://ghcr.io/<github-user>/charts/pds bash scripts/rotate-plc-rotation-key.sh <chart-version>
```

If `CHART` points at a local directory, the script detects that and drops `--version` from the `helm upgrade` call automatically (Helm has no version lookup for a local path so it's ignored either way, this just avoids passing a flag that wouldn't mean anything). `<chart-version>` is still a required argument in that case; it's just unused.

This re-derives the `did:key` from the key file's own private hex as a sanity check (catches a stale copy/paste), then runs `helm upgrade` + `kubectl rollout restart`/`status`, and only deletes `~/new-plc-key.json` once the rollout is confirmed healthy. At this point every account still lists **both** keys; the server just now signs with the new one.

**Step 5 — for EVERY existing account, REMOVE the old key**

```bash
bash scripts/deauthorize-plc-rotation-key.sh yourdomain.com you.yourdomain.com "$OLD_SERVER_DID_KEY"
# ...repeat for every other account on this PDS
```

This works only now, after step 4. The server signs with the new key, so an operation removing the old key still satisfies `submitPlcOperation`'s check (the new key is present, which is all it requires). Running this before step 4 would fail with the exact same error as trying to swap directly in step 2.

**Step 6 — confirm every account is fully migrated**

```bash
curl -s "https://plc.directory/<did>/data" | jq .rotationKeys
```

Repeat for each account's DID. Every one must show only `$NEW_SERVER_DID_KEY` (plus any personal keys), with `$OLD_SERVER_DID_KEY` gone. Once all accounts confirm:

- **Update your password manager entry**: replace the old server key's backup with the new `privHex` you saved back in step 1. It's no longer authoritative for any account, so there's no reason to keep it around
- **Update `my-secrets.yaml`**'s `credentials.plcRotationKey` with the new value too, same as any other rotated secret (above). This local file is a convenience for future `helm upgrade -f my-secrets.yaml` runs, not a substitute for the password manager backup. It's a plaintext file on your workstation, not designed for secure long-term storage

## Uninstall

```bash
helm uninstall pds --namespace pds
```

This removes all chart resources **including the data PVC**. Back up SQLite databases first. The RGW bucket and its blobs are not removed.

### Cloudflare Tunnel cleanup

```bash
kubectl delete secret cloudflared-credentials --namespace pds
cloudflared tunnel delete pds
```

## Glossary

| Term | Meaning |
|---|---|
| API | Application Programming Interface |
| AT Protocol (ATProto) | Authenticated Transfer Protocol — the open, federated social networking protocol underpinning Bluesky |
| AWS | Amazon Web Services — the cloud provider whose CLI this chart's docs use to manage the RGW blob bucket |
| CAR | Content Addressable aRchive — the file format used to export an AT Protocol repo |
| CID | Content Identifier — a content-addressed hash identifying a blob or record in an AT Protocol repo |
| CLI | Command Line Interface |
| CNAME | Canonical Name — a DNS record type that aliases one domain name to another |
| CORS | Cross-Origin Resource Sharing — a browser security mechanism controlling which origins may make cross-origin requests |
| CPU | Central Processing Unit |
| CRD | Custom Resource Definition — extends the Kubernetes API with new resource types; the basis of the Operator pattern |
| DDoS | Distributed Denial of Service — an attack that floods a target with traffic from many sources to disrupt availability |
| DID | Decentralized Identifier — a globally unique, cryptographically verifiable identifier; AT Protocol uses `did:plc` and `did:web` |
| DKIM | DomainKeys Identified Mail — an email authentication method using cryptographic signatures in message headers |
| DMARC | Domain-based Message Authentication, Reporting, and Conformance — an email policy framework built on top of SPF and DKIM |
| DNS | Domain Name System — the internet's directory that maps domain names to IP addresses |
| GHCR | GitHub Container Registry — GitHub's OCI-compatible container and Helm chart registry |
| GIF | Graphics Interchange Format — an image file format |
| HTTP / HTTPS | Hypertext Transfer Protocol (Secure) — the foundation of data communication on the web |
| IP | Internet Protocol — the addressing scheme underlying network communication (e.g. a node's LAN IP) |
| ISO | International Organization for Standardization — as in ISO 8601, a date/time string format |
| JPEG | Joint Photographic Experts Group — an image file format |
| JSON | JavaScript Object Notation — a lightweight, text-based data interchange format |
| JWT | JSON Web Token — a compact, signed token format used for authentication |
| LAN | Local Area Network — a private network within a home or office |
| MB | Megabyte |
| mDNS | Multicast DNS — a protocol for resolving hostnames on a local network without a central DNS server (`.local` addresses); does not resolve inside Kubernetes pods |
| Mi | Mebibyte — a binary unit (2^20 bytes = 1,048,576 bytes), distinct from the decimal Megabyte (MB, 10^6 bytes); Kubernetes reports pod memory in this unit |
| OCI | Open Container Initiative — the standard for container image formats and registries |
| OSD | Object Storage Daemon — the Ceph process responsible for storing data on a single storage device |
| PAT | Personal Access Token — a GitHub credential used in place of a password for API or registry access |
| PDS | Personal Data Server — the AT Protocol server that hosts your account, DID, and data repo |
| PLC | Public Ledger of Credentials — the AT Protocol DID method (`did:plc`), originally intended as a placeholder but now the primary method used by Bluesky |
| PNG | Portable Network Graphics — an image file format |
| PVC | Persistent Volume Claim — a Kubernetes request for durable storage backed by a StorageClass |
| RADOS | Reliable Autonomic Distributed Object Store — the underlying distributed storage layer of Ceph; RBD and RGW are both built on top of it |
| RBD | RADOS Block Device — Ceph's block storage interface, used here as the StorageClass backing the SQLite PVC |
| RGW | RADOS Gateway — Ceph's S3-compatible object storage gateway, used here for blob (media) storage |
| S3 | Simple Storage Service — Amazon's object storage API, also implemented by RGW |
| SATA | Serial AT Attachment — an interface for connecting storage drives |
| SMTP | Simple Mail Transfer Protocol — the standard protocol for sending email |
| SPF | Sender Policy Framework — a DNS-based email authentication method that specifies which mail servers may send on behalf of a domain |
| SSD | Solid State Drive |
| SSH | Secure Shell — a protocol for securely accessing a remote machine's command line |
| SSL | Secure Sockets Layer — the predecessor to TLS, still used as a common name for the protocol family |
| SVG | Scalable Vector Graphics — an XML-based vector image format |
| TID | Timestamp Identifier — AT Protocol's sortable, timestamp-based key format used for record and commit revisions |
| TLS | Transport Layer Security — the cryptographic protocol that secures HTTPS and `smtps://` connections |
| TXT | Text Record — a DNS record type used for SPF, domain ownership verification, and other machine-readable data |
| URL | Uniform Resource Locator — a web address, e.g. `https://yourdomain.com` |
| USB | Universal Serial Bus |
| WAF | Web Application Firewall — filters HTTP traffic to a web application to block common attacks |
| WAL | Write-Ahead Log — a database's append-only log of pending changes, used here for Litestream's continuous replication of the PDS's SQLite databases |
