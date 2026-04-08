# OpenCode on OpenShift

Deploy [OpenCode](https://opencode.ai) as a web application on Red Hat OpenShift, secured with OpenShift OAuth Proxy and backed by a [vLLM](https://docs.vllm.ai/) inference server running on the same cluster.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              OpenShift Cluster                                      │
│                                                                                     │
│  Namespace: opencode                        Namespace: vllm (or KServe / RHOAI)     │
│  ┌───────────────────────────────────────┐  ┌─────────────────────────────────────┐ │
│  │                                       │  │                                     │ │
│  │  ┌─────────────────────────────────┐  │  │  ┌───────────────────────────────┐  │ │
│  │  │     Route (reencrypt TLS)       │  │  │  │  vLLM Inference Server        │  │ │
│  │  │     opencode-web                │  │  │  │                               │  │ │
│  │  └──────────────┬──────────────────┘  │  │  │  ◆ OpenAI-compatible API      │  │ │
│  │                 │                     │  │  │  ◆ /v1/chat/completions       │  │ │
│  │                 ▼ :8443               │  │  │  ◆ GPU-accelerated            │  │ │
│  │  ┌─────────────────────────────────┐  │  │  │                               │  │ │
│  │  │     Service (ClusterIP)         │  │  │  └───────────────┬───────────────┘  │ │
│  │  │     opencode-web                │  │  │                  │                  │ │
│  │  └──────────────┬──────────────────┘  │  │  ┌───────────────┴───────────────┐  │ │
│  │                 │                     │  │  │  Service (ClusterIP)          │  │ │
│  │  ┌──────────────┴──────────────────┐  │  │  │  e.g. vllm-svc:80/v1          │  │ │
│  │  │       Pod: opencode-web         │  │  │  └───────────────────────────────┘  │ │
│  │  │                                 │  │  │                                     │ │
│  │  │  ┌──────────────┐ ┌──────────┐  │  │  └─────────────────────────────────────┘ │
│  │  │  │ OAuth Proxy  │ │ OpenCode │  │  │                    ▲                     │
│  │  │  │ :8443 (TLS)  │─│ Web      │  │  │                    │                     │
│  │  │  │              │ │ :8003    │──┼──┼── API calls ───────┘                     │
│  │  │  │ ◆ OCP auth   │ │          │  │  │  (cluster-internal)                      │
│  │  │  │ ◆ SAR check  │ │ ◆ UI     │  │  │                                          │
│  │  │  │ ◆ Cookie     │ │ ◆ Agent  │  │  │                                          │
│  │  │  └──────────────┘ └────┬─────┘  │  │                                          │
│  │  │                        │        │  │                                          │
│  │  │              ┌─────────┴──────┐ │  │                                          │
│  │  │              │ PVC (10Gi)     │ │  │                                          │
│  │  │              │ /home/opencode │ │  │                                          │
│  │  │              │ /workspace     │ │  │                                          │
│  │  │              └────────────────┘ │  │                                          │
│  │  └─────────────────────────────────┘  │                                          │
│  │                                       │                                          │
│  └───────────────────────────────────────┘                                          │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
         ▲
         │ HTTPS
         │
    ┌────┴────┐
    │  User   │
    │ Browser │
    └─────────┘
```

### How It Works

1. A **vLLM** inference server runs on the same OpenShift cluster (e.g. via KServe, RHOAI, or a standalone Deployment with GPU nodes), exposing an OpenAI-compatible API on a cluster-internal Service.
2. A user navigates to the OpenShift **Route** in their browser.
3. The **OAuth Proxy** sidecar intercepts the request, authenticates the user against the OpenShift OAuth server, and enforces RBAC (the user must have `get` access to `services` in the `opencode` namespace).
4. Once authenticated, the request is forwarded over `localhost` to the **OpenCode Web** container on port `8003`.
5. OpenCode Web serves the coding assistant UI and sends inference requests to the **vLLM** service over the cluster-internal network -- traffic never leaves the cluster.
6. The workspace is persisted on a **PVC** so files survive pod restarts.

## Prerequisites

- OpenShift 4.x cluster with cluster-admin access (or sufficient RBAC to create namespaces, service accounts, routes, and secrets)
- `oc` CLI installed and authenticated (`oc login`)
- `podman` or `docker` for building the container image (if building from source)
- A **vLLM inference server** already running on the cluster (e.g. deployed via [KServe](https://kserve.github.io/), [Red Hat OpenShift AI](https://www.redhat.com/en/technologies/cloud-computing/openshift/openshift-ai), or a standalone Deployment on GPU nodes) with a reachable cluster-internal Service URL

## Project Structure

```
.
├── Containerfile                  # Container build (UBI 10 minimal)
├── LICENSE                        # Apache License 2.0
├── README.md                      # This file
└── manifests/
    ├── kustomization.yaml         # Kustomize root: resources, ConfigMaps, Secrets
    ├── namespace.yaml             # Namespace: opencode
    ├── serviceaccount.yaml        # ServiceAccount with OAuth redirect annotation
    ├── deployment.yaml            # Deployment: oauth-proxy + opencode-web containers
    ├── service.yaml               # ClusterIP Service (ports 8443, 8003)
    ├── route.yaml                 # Route with reencrypt TLS termination
    ├── pvc.yaml                   # 10Gi RWO PersistentVolumeClaim
    └── config-template.json       # OpenCode config template (provider + model)
```

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/aicatalyst-team/opencode-openshift.git
cd opencode-openshift

# 2. Configure the vLLM endpoint (see "Configuration" below)
#    Edit manifests/kustomization.yaml with your vLLM service URL and model

# 3. Deploy to OpenShift
oc apply -k manifests/

# 4. Wait for the rollout
oc -n opencode rollout status deployment/opencode-web

# 5. Get the route URL
oc -n opencode get route opencode-web -o jsonpath='https://{.spec.host}{"\n"}'
```

Open the printed URL in your browser. You will be redirected to the OpenShift login page, and after authentication you will land in the OpenCode web UI.

## Building the Container Image

The provided `Containerfile` builds on **UBI 10 minimal** and installs OpenCode along with common development tools.

```bash
# Build
podman build -t quay.io/<your-org>/opencode:latest .

# Push
podman push quay.io/<your-org>/opencode:latest
```

### What the Image Contains

| Layer | Purpose |
|-------|---------|
| UBI 10 minimal base | RHEL-compatible minimal image |
| git, curl, tar, jq, make, etc. | Common CLI tools for development workflows |
| Python 3 + venv (`/opt/venv`) | Python environment for tool/script execution |
| OpenCode binary | Installed via `https://opencode.ai/install` |
| `/home/opencode/workspace` | Pre-initialized git repo for workspace |

If you use the pre-built image (`quay.io/aicatalyst/opencode:latest`), you can skip this step.

## Configuration

All runtime configuration is managed through the `manifests/kustomization.yaml` file.

### vLLM Endpoint Settings

Edit the `secretGenerator` section to point to your cluster-internal vLLM service:

```yaml
secretGenerator:
  - name: opencode-web-secret
    literals:
      - BASE_URL=http://<vllm-service>.<namespace>.svc.cluster.local/v1   # Cluster-internal vLLM URL
      - API_KEY=<your-api-key>                                             # API key (use "token" if auth is disabled)
      - MODEL_NAME=<your-model-name>                                       # Model loaded in vLLM (e.g. RedHatAI/Qwen3-Next-80B-A3B-Instruct-FP8)
    options:
      disableNameSuffixHash: true
```

The `BASE_URL` should use the cluster-internal DNS name of your vLLM Service (e.g. `http://vllm-svc.vllm.svc.cluster.local/v1`). If vLLM is served via KServe or RHOAI, use the internal InferenceService URL.

These values are injected into the pod as environment variables and substituted into the config template at startup.

### OAuth Proxy Cookie Secret

Generate a new session secret for the OAuth Proxy:

```bash
# Generate a random base64-encoded 32-byte secret
python3 -c "import os, base64; print(base64.b64encode(os.urandom(32)).decode())"
```

Replace the `session_secret` value in `kustomization.yaml`:

```yaml
  - name: opencode-web-proxy-cookie
    type: Opaque
    literals:
      - session_secret=<your-generated-secret>
    options:
      disableNameSuffixHash: true
```

### Storage

The default PVC requests **10Gi** with `standard-csi` storage class. Adjust in `manifests/pvc.yaml` if your cluster uses a different storage class:

```yaml
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: <your-storage-class>   # e.g. gp3-csi, ocs-storagecluster-cephfs
```

### Custom Image

If you built and pushed your own image, update `manifests/deployment.yaml`:

```yaml
- name: opencode-web
  image: quay.io/<your-org>/opencode:latest
```

### Config Template

The `manifests/config-template.json` defines the OpenCode provider configuration. It uses the `@ai-sdk/openai-compatible` SDK which maps directly to vLLM's OpenAI-compatible API. Placeholders (`${BASE_URL}`, `${API_KEY}`, `${MODEL_NAME}`) are substituted at container startup from the secret environment variables.

To add additional providers or change settings, edit this file following the [OpenCode configuration schema](https://opencode.ai/config.json).

## Deployment

### Step 1: Log in to OpenShift

```bash
oc login --server=https://api.<cluster-domain>:6443
```

### Step 2: Review and Customize Configuration

Ensure all values in `manifests/kustomization.yaml` are correct for your environment (see [Configuration](#configuration) above).

### Step 3: Deploy

```bash
oc apply -k manifests/
```

This creates the following resources in the `opencode` namespace:

| Resource | Name | Purpose |
|----------|------|---------|
| Namespace | `opencode` | Isolated project for the deployment |
| ServiceAccount | `opencode-web` | Identity for OAuth proxy integration |
| ConfigMap | `opencode-web-config` | OpenCode configuration template |
| Secret | `opencode-web-secret` | vLLM endpoint credentials |
| Secret | `opencode-web-proxy-cookie` | OAuth proxy session cookie secret |
| Secret | `opencode-web-tls` | Auto-generated serving certificate |
| PVC | `opencode-web-pvc` | Persistent workspace storage (10Gi) |
| Deployment | `opencode-web` | Pod with oauth-proxy + opencode-web containers |
| Service | `opencode-web` | Internal cluster networking |
| Route | `opencode-web` | External HTTPS endpoint |

### Step 4: Verify the Deployment

```bash
# Check pod status
oc -n opencode get pods

# Check logs for the opencode container
oc -n opencode logs deployment/opencode-web -c opencode-web

# Check logs for the oauth proxy
oc -n opencode logs deployment/opencode-web -c oauth-proxy

# Get the external URL
oc -n opencode get route opencode-web -o jsonpath='https://{.spec.host}{"\n"}'
```

### Step 5: Access OpenCode

Open the route URL in your browser. You will be prompted to log in with your OpenShift credentials. After authentication, the OpenCode web UI will load.

> **Note:** The OAuth proxy enforces that the authenticated user has `get` permission on `services` in the `opencode` namespace. Grant access with:
>
> ```bash
> oc -n opencode adm policy add-role-to-user view <username>
> ```

## Security Considerations

### Secrets Management

The `kustomization.yaml` file contains plaintext secret values for convenience. **For production deployments**, replace the inline secrets with a proper secrets management solution:

- [Sealed Secrets](https://sealed-secrets.netlify.app/) for GitOps workflows
- [External Secrets Operator](https://external-secrets.io/) for integration with Vault, AWS Secrets Manager, etc.
- [OpenShift Secrets Store CSI Driver](https://docs.openshift.com/container-platform/latest/nodes/pods/nodes-pods-secrets-store.html) for direct volume-mounted secrets

### TLS

TLS is handled automatically:
- The Service annotation `service.beta.openshift.io/serving-cert-secret-name` triggers OpenShift to generate a serving certificate into the `opencode-web-tls` secret.
- The Route uses `reencrypt` termination, meaning traffic is encrypted end-to-end from the user to the OAuth Proxy.

### RBAC

The OAuth Proxy enforces a **Subject Access Review (SAR)** check. Only users who can `get services` in the `opencode` namespace are allowed through. This ties access control to standard OpenShift RBAC.

## Troubleshooting

### Pod stuck in `Pending`

```bash
oc -n opencode describe pod -l app=opencode
```

Common causes:
- **PVC not bound** -- check that the `standard-csi` storage class exists: `oc get storageclass`
- **Image pull error** -- verify the image reference and ensure the cluster can pull from `quay.io/aicatalyst/opencode`

### OAuth Proxy returns 403

The authenticated user lacks the required RBAC permission. Grant it:

```bash
oc -n opencode adm policy add-role-to-user view <username>
```

### OpenCode cannot reach vLLM

Check that the vLLM service is running and reachable from within the cluster:

```bash
# Verify the vLLM service exists and has endpoints
oc get svc -A | grep vllm

# Test connectivity from the opencode pod to the vLLM service
oc -n opencode exec deployment/opencode-web -c opencode-web -- \
  curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/models"
```

If vLLM is in a different namespace, ensure that no `NetworkPolicy` is blocking cross-namespace traffic. The `BASE_URL` must use the full cluster-internal DNS: `http://<service>.<namespace>.svc.cluster.local/v1`.

### Viewing the rendered config

```bash
oc -n opencode exec deployment/opencode-web -c opencode-web -- \
  printenv OPENCODE_CONFIG_CONTENT | jq .
```

## Cleanup

Remove all deployed resources:

```bash
oc delete -k manifests/
```

This deletes the namespace and all resources within it.

## License

Apache License 2.0 -- see [LICENSE](LICENSE) for details.
