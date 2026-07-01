# PDS
[Under development]

An opinionated Helm chart for the [Bluesky PDS](https://github.com/bluesky-social/pds) (Personal Data Server), the server that hosts your AT Protocol account and data. Designed for a homelab running [MicroK8s](https://canonical.com/microk8s) + [MicroCeph](https://canonical.com/microk8s/docs/how-to-ceph) on a [Raspberry Pi](https://www.raspberrypi.com/products/) cluster.

Blobs (media, avatars, video) are stored in MicroCeph's S3-compatible RGW object store. Account data and per-user repos use SQLite on a Ceph RBD PVC. Internet access is provided by a [Cloudflare Tunnel](CLOUDFLARE.md) so no open inbound ports or router configuration needed.

## Prerequisites

- Helm
- MicroCeph cluster with RGW enabled on at least one node (`sudo microceph enable rgw --port 7480`)
- MicroK8s cluster with:
  - `rook-ceph` addon enabled and connected to MicroCeph (`microk8s connect-external-ceph`)
  - `ceph-rbd` StorageClass available and set as default
  - `ingress` addon enabled (provides `traefik-gateway` in the `ingress` namespace). Only needed if you want local LAN access via the Gateway API HTTPRoute (`httpRoute.enabled=true`, the default); not required for the Cloudflare Tunnel
- A public domain name managed in Cloudflare
- A kubeconfig pointing at the k8s cluster (see [books README](https://github.com/santisbon/books) for setup steps)

## TL;DR

```bash
# 0. Generate `my-secrets.yaml` with random credentials.
bash scripts/gen-secrets.sh

# 1. Create RGW user and use the access_key / secret_key from output in `my-secrets.yaml`
sudo radosgw-admin user create --uid=pds --display-name=pds

# 2. Create the blob bucket
aws s3 mb s3://pds-blobs --profile homelab

# 3. Create a Cloudflare Tunnel
cloudflared tunnel login

APP_DOMAIN=pds.yourdomain.com

TUNNEL_ID=$(cloudflared tunnel create -o json pds | jq -r '.id')
# PDS requires two DNS records. 
# The wildcard record is required so that other ATProto services can verify user handles of the form `you.pds.yourdomain.com`.
# 1. The PDS itself
cloudflared tunnel route dns pds $APP_DOMAIN
# 2. Wildcard for user handles
cloudflared tunnel route dns pds "*.$APP_DOMAIN"

cloudflared tunnel list

kubectl create secret generic cloudflared-credentials \
  --from-file=credentials.json=$HOME/.cloudflared/$TUNNEL_ID.json \
  --namespace pds

# 4. Generate secrets
bash scripts/gen-secrets.sh
# Edit my-secrets.yaml and fill in 
# blobstoreAccessKeyId / blobstoreSecretAccessKey, 
# emailSmtpUrl, emailFromAddress.

# 5. Package and push the chart to GHCR
helm package charts/pds
gh auth refresh -s write:packages
gh auth token | helm registry login ghcr.io --username <github-user> --password-stdin
helm push pds-*.tgz oci://ghcr.io/<github-user>/charts

# 6. Install from GHCR. Replace with your domain and blob store endpoint
helm upgrade --install pds oci://ghcr.io/<github-user>/charts/pds \
  --version 0.1.0 \
  --namespace pds --create-namespace \
  --set config.hostname=pds.yourdomain.com \
  --set config.adminEmail=you@example.com \
  --set config.emailFromAddress=noreply@pds.yourdomain.com \
  --set blobstore.endpoint=http://192.168.1.100:7480 \
  --set cloudflare.enabled=true \
  --set cloudflare.tunnelId=$TUNNEL_ID \
  --set cloudflare.hostname=pds.yourdomain.com \
  -f my-secrets.yaml

# 7. Get the invite code and create your account
# Get admin password
PDS_ADMIN_PASSWORD=$(kubectl get secret pds -n pds \
  -o jsonpath='{.data.admin-password}' | base64 -d)

# Create an invite code
curl -sX POST https://pds.yourdomain.com/xrpc/com.atproto.server.createInviteCode \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n "admin:${PDS_ADMIN_PASSWORD}" | base64)" \
  -d '{"useCount": 1}' | jq -r '.code'

# Create your account
curl -sX POST https://pds.yourdomain.com/xrpc/com.atproto.server.createAccount \
  -H "Content-Type: application/json" \
  -d '{
    "handle": "you.pds.yourdomain.com",
    "email": "you@example.com",
    "password": "YOUR_ACCOUNT_PASSWORD",
    "inviteCode": "INVITE_CODE"
  }'
```

Then log into [bsky.app](https://bsky.app) by choosing "Use my own PDS" and entering `https://pds.yourdomain.com`

## Architecture

```
Internet → Cloudflare Edge → cloudflared (2 replicas) → ClusterIP Service → PDS pod
                                                                                │
                                          PVC (ceph-rbd, 5Gi) ←────────────────┤  /pds
                                          MicroCeph RGW (S3) ←─────────────────┘  blobs
```

The PDS image (`ghcr.io/bluesky-social/pds`) runs on port 3000. Caddy from the upstream compose file is replaced by the Cloudflare Tunnel: TLS terminates at the Cloudflare edge, the tunnel carries plain HTTP to the ClusterIP service inside the cluster, and WebSockets are supported natively by the tunnel.

## Install

**Credentials** must be provided at install time. Use a values file (gitignored) rather than `--set` flags so they don't appear in your shell history.

The secrets script generates `jwtSecret`, `adminPassword`, and `plcRotationKey` automatically, and leaves placeholders for the RGW blob storage credentials you need to fill in manually.

**Important:** Back up `credentials.plcRotationKey` outside the cluster. This is one key for the whole server; not one per user. It is the server's signing authority for all `did:plc` operations: user DIDs are created on `plc.directory` at account-creation time with this key listed as the rotation authority, and any future DID update (handle change, PDS migration) must be signed by it. Loss means no DID updates are possible for any account on this PDS.

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

1. In the Resend dashboard, go to **Domains** → **Add Domain**.
   - Use a subdomain like `mail.yourdomain.com` if your root domain is already used for email (e.g. Gmail/Google Workspace). If Resend is your only email sender, `yourdomain.com` works too.
   - After adding the domain, Resend shows you the DNS records to create (SPF TXT, DKIM CNAMEs, optionally DMARC). Add those at your DNS provider, then click **Verify DNS Records** in Resend. Propagation usually takes a few minutes to an hour. For some DNS providers like Cloudflare, Resend can ask you to log in and can configure the DNS records automatically.
2. Go to **API Keys** → **Create API Key** (Sending access is sufficient). Copy the key; it starts with `re_`.

Set in `my-secrets.yaml` (avoid `--set` to keep the API key off your bash history):

```yaml
config:
  emailSmtpUrl: "smtps://resend:re_YOUR_API_KEY@smtp.resend.com"
  emailFromAddress: "noreply@pds.yourdomain.com"
```

`smtps://` uses port 465 with implicit TLS. The `From` domain in `emailFromAddress` must match a domain verified in the Resend dashboard.

## Key config values

| Value | Default | Description |
|---|---|---|
| `image.tag` | `"0.4"` | PDS image tag |
| `config.hostname` | `""` | **Required:** public hostname without scheme (e.g. `pds.yourdomain.com`) |
| `config.adminEmail` | `""` | Admin contact email (`PDS_CONTACT_EMAIL_ADDRESS`) |
| `config.emailSmtpUrl` | `""` | SMTP URL for account verification email |
| `config.emailFromAddress` | `""` | From address for outbound email |
| `config.inviteRequired` | `true` | Require invite codes to create accounts |
| `config.rateLimitsEnabled` | `true` | Enable rate limiting |
| `config.blobUploadLimit` | `104857600` | Upload limit in bytes (100 MB) |
| `blobstore.bucket` | `"pds-blobs"` | S3 bucket name in RGW |
| `blobstore.endpoint` | `""` | **Required:** RGW endpoint URL (use node LAN IP, not `.local`) |
| `blobstore.region` | `"us-east-1"` | S3 region (RGW accepts any string) |
| `blobstore.forcePathStyle` | `true` | Required for RGW (no virtual-hosted style) |
| `credentials.jwtSecret` | `""` | **Required:** JWT signing secret |
| `credentials.adminPassword` | `""` | **Required:** PDS admin password |
| `credentials.plcRotationKey` | `""` | **Required:** secp256k1 private key hex (back up securely) |
| `credentials.blobstoreAccessKeyId` | `""` | **Required:** RGW access key |
| `credentials.blobstoreSecretAccessKey` | `""` | **Required:** RGW secret key |
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
  --set config.hostname=pds.yourdomain.com \
  --set blobstore.endpoint=http://192.168.1.100:7480 \
  --set cloudflare.enabled=true \
  --set cloudflare.tunnelId=$TUNNEL_ID \
  --set cloudflare.hostname=pds.yourdomain.com \
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

## Custom handles

Users get a default handle under the PDS hostname (e.g. `you.pds.yourdomain.com`). If a user controls their own domain they can use it as their handle instead. No Bluesky involvement required, everything goes through your PDS.

**Step 1 — Prove domain ownership.** Choose one method:

DNS TXT record on the user's domain:
```
_atproto.alice.example.com  TXT  "did=did:plc:xxxx"
```

Or a file served at the user's domain:
```
https://alice.example.com/.well-known/atproto-did
```
containing only the bare DID string (e.g. `did:plc:xxxx`). No JSON, no wrapper.

The user's `did:plc` is returned in the `createAccount` response, or can be retrieved later:
```bash
curl -s "https://pds.yourdomain.com/xrpc/com.atproto.identity.resolveHandle?handle=you.pds.yourdomain.com" \
  | jq -r '.did'
```

**Step 2 — Update the handle.** The user calls `updateHandle` authenticated as themselves (not admin). Get an access JWT first:

```bash
ACCESS_JWT=$(curl -sX POST https://pds.yourdomain.com/xrpc/com.atproto.server.createSession \
  -H "Content-Type: application/json" \
  -d '{"identifier": "you.pds.yourdomain.com", "password": "YOUR_ACCOUNT_PASSWORD"}' \
  | jq -r '.accessJwt')
```

Then update the handle:

```bash
curl -sX POST https://pds.yourdomain.com/xrpc/com.atproto.identity.updateHandle \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ACCESS_JWT" \
  -d '{"handle": "alice.example.com"}'
```

The PDS verifies the DNS/HTTP proof resolves to the user's DID, then signs and publishes the handle update to `plc.directory` using the server's `plcRotationKey`.

## Adding a personal rotation key

By default the server's `plcRotationKey` is the only signing authority for your `did:plc`. If this PDS disappears, no one can sign DID updates for your account, including an update pointing to a new PDS. Adding your own rotation key at index 0 (higher authority than the server's key) lets you sign those updates yourself.

**Step 1 — Generate a secp256k1 keypair.** The key must be encoded as a `did:key` multikey string, which requires AT Protocol-specific encoding and is not a plain openssl one-liner. The easiest path is the `@atproto/crypto` package:

```bash
node -e "
const { Secp256k1Keypair } = require('@atproto/crypto');
Secp256k1Keypair.create({ exportable: true }).then(async kp => {
  const priv = Buffer.from(await kp.export()).toString('hex');
  console.log('did:key  =>', kp.did());
  console.log('priv hex =>', priv);
});
"
```

Store the private key hex in a password manager or hardware key. The `did:key` string is the public identifier used in the next steps.

**Step 2 — Get the server's current rotation key** from the PLC directory so you can include it at index 1:

```bash
DID=$(curl -s "https://pds.yourdomain.com/xrpc/com.atproto.identity.resolveHandle?handle=you.pds.yourdomain.com" \
  | jq -r '.did')
SERVER_KEY=$(curl -s "https://plc.directory/$DID" | jq -r '.rotationKeys[0]')
```

**Step 3 — Request an email verification token** (the PDS requires this before signing PLC operations):

```bash
curl -sX POST https://pds.yourdomain.com/xrpc/com.atproto.identity.requestPlcOperationSignature \
  -H "Authorization: Bearer $ACCESS_JWT"
```

**Step 4 — Sign and submit the PLC operation.** Pass your key at index 0, the server key at index 1:

```bash
OPERATION=$(curl -sX POST https://pds.yourdomain.com/xrpc/com.atproto.identity.signPlcOperation \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ACCESS_JWT" \
  -d "{\"token\": \"EMAIL_TOKEN\", \"rotationKeys\": [\"$USER_DID_KEY\", \"$SERVER_KEY\"]}" \
  | jq '.operation')

curl -sX POST https://pds.yourdomain.com/xrpc/com.atproto.identity.submitPlcOperation \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ACCESS_JWT" \
  -d "{\"operation\": $OPERATION}"
```

Verify the result at `https://plc.directory/$DID`. Your `did:key` should appear at index 0 of `rotationKeys`.

## Backing up your repo

Your AT Protocol repo is a content-addressed data structure (a CAR file) containing all your posts, follows, likes, and other records. Export it with:

```bash
DID=$(curl -s "https://pds.yourdomain.com/xrpc/com.atproto.identity.resolveHandle?handle=you.pds.yourdomain.com" \
  | jq -r '.did')

curl -s "https://pds.yourdomain.com/xrpc/com.atproto.sync.getRepo?did=$DID" \
  -o repo-backup.car
```

The endpoint is unauthenticated so no JWT needed. Run this periodically so a backup is available if the PDS goes offline unexpectedly.

To restore on a new PDS, use `com.atproto.repo.importRepo` once your account exists there. Combined with a personal rotation key (above), this gives you full account portability independent of this server.

## Production notes

- **Domain stability:** `config.hostname` cannot be changed after first start without migrating every account individually. Choose your domain before deploying.
- **PLC rotation key:** One secp256k1 private key for the entire server (not one per user). The PDS server's own identity is a `did:web` derived from `config.hostname`; no PLC key is needed for that. User accounts, however, get `did:plc` identities registered on `plc.directory` at account-creation time. Each genesis operation includes a `rotationKeys` list; this server key is always one of them, giving the server signing authority for future DID updates (handle changes, PDS hostname migrations). Back it up outside the cluster (password manager, hardware key). Loss means the server cannot perform DID updates for any hosted account.
- **User-owned rotation keys:** A `did:plc` document supports up to 5 rotation keys ordered by descending authority (index 0 = highest). Any rotation key can sign a DID update, but within a 72-hour window a higher-authority key can dispute and override an operation signed by a lower-authority key. A user who adds their own rotation key at index 0 (via AT Protocol tooling or a Bluesky client that exposes this) and keeps the server's key at index 1 can sign DID updates independently, meaning they can migrate to another PDS even if this server loses its `plcRotationKey` or disappears entirely. Without a user-owned key, the server's key is the only rotation authority and its loss permanently freezes the account's DID.
- **Email:** Without SMTP, account email verification links will not be delivered. Bluesky app clients may warn users that email is unverified.
- **Wildcard DNS:** `*.pds.yourdomain.com` must resolve to the tunnel so user handles are verifiable by other ATProto services.
- **Litestream:** For additional SQLite replication, you can add a [Litestream](https://litestream.io) sidecar. Not included in this chart because the Ceph RBD PVC already provides 3× replication at the block level.

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
| CAR | Content Addressable aRchive — the file format used to export an AT Protocol repo |
| CNAME | Canonical Name — a DNS record type that aliases one domain name to another |
| CPU | Central Processing Unit |
| DID | Decentralized Identifier — a globally unique, cryptographically verifiable identifier; AT Protocol uses `did:plc` and `did:web` |
| DKIM | DomainKeys Identified Mail — an email authentication method using cryptographic signatures in message headers |
| DMARC | Domain-based Message Authentication, Reporting, and Conformance — an email policy framework built on top of SPF and DKIM |
| DNS | Domain Name System — the internet's directory that maps domain names to IP addresses |
| GHCR | GitHub Container Registry — GitHub's OCI-compatible container and Helm chart registry |
| HTTP / HTTPS | Hypertext Transfer Protocol (Secure) — the foundation of data communication on the web |
| JWT | JSON Web Token — a compact, signed token format used for authentication |
| LAN | Local Area Network — a private network within a home or office |
| mDNS | Multicast DNS — a protocol for resolving hostnames on a local network without a central DNS server (`.local` addresses); does not resolve inside Kubernetes pods |
| OCI | Open Container Initiative — the standard for container image formats and registries |
| PAT | Personal Access Token — a GitHub credential used in place of a password for API or registry access |
| PDS | Personal Data Server — the AT Protocol server that hosts your account, DID, and data repo |
| PLC | Public Ledger of Credentials — the AT Protocol DID method (`did:plc`), originally intended as a placeholder but now the primary method used by Bluesky |
| PVC | Persistent Volume Claim — a Kubernetes request for durable storage backed by a StorageClass |
| RADOS | Reliable Autonomic Distributed Object Store — the underlying distributed storage layer of Ceph; RBD and RGW are both built on top of it |
| RBD | RADOS Block Device — Ceph's block storage interface, used here as the StorageClass backing the SQLite PVC |
| RGW | RADOS Gateway — Ceph's S3-compatible object storage gateway, used here for blob (media) storage |
| S3 | Simple Storage Service — Amazon's object storage API, also implemented by RGW |
| SMTP | Simple Mail Transfer Protocol — the standard protocol for sending email |
| SPF | Sender Policy Framework — a DNS-based email authentication method that specifies which mail servers may send on behalf of a domain |
| TLS | Transport Layer Security — the cryptographic protocol that secures HTTPS and `smtps://` connections |
| TXT | Text Record — a DNS record type used for SPF, domain ownership verification, and other machine-readable data |
| URL | Uniform Resource Locator — a web address, e.g. `https://pds.yourdomain.com` |
