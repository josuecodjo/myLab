# myLab — a reproducible GitOps homelab

A single-node k3s cluster, provisioned by Ansible, that bootstraps itself into a
full GitOps platform: Argo CD manages every component, Kyverno and Falco enforce
and watch security, kro provides application abstractions, and Kargo promotes
releases across stages.

Everything after the Ansible run is declarative. You apply **one** ApplicationSet;
Argo CD creates the rest — on this cluster, and on any other you register.

---

## Table of contents

1. [What gets built](#1-what-gets-built)
2. [Repositories involved](#2-repositories-involved)
3. [Prerequisites](#3-prerequisites)
4. [Step 1 — Prepare the target machine](#step-1--prepare-the-target-machine)
5. [Step 2 — Prepare the control node](#step-2--prepare-the-control-node)
6. [Step 3 — Configure inventory and variables](#step-3--configure-inventory-and-variables)
7. [Step 4 — Run the playbook](#step-4--run-the-playbook)
8. [Step 5 — Reach Argo CD](#step-5--reach-argo-cd)
9. [Step 6 — Understand and drive the app-of-apps](#step-6--understand-and-drive-the-app-of-apps)
10. [Step 7 — Deploy the ApplicationSets](#step-7--deploy-the-applicationsets)
11. [Step 8 — kro abstractions](#step-8--kro-abstractions)
12. [Step 9 — Kargo promotion pipeline](#step-9--kargo-promotion-pipeline)
13. [Step 10 — Validate the security stack](#step-10--validate-the-security-stack)
14. [Step 11 — Vault](#step-11--vault-optional-needs-manual-initialisation)
15. [Step 12 — Observability from outside](#step-12--observability-from-outside-the-cluster)
16. [Step 13 — Add a dev cluster](#step-13--add-a-dev-cluster-supervised-by-this-one)
17. [Teardown](#teardown)
18. [Troubleshooting](#troubleshooting)
19. [Known gaps](#known-gaps)

---

## 1. What gets built

```
                      ansible-playbook playbook.yml
                                  │
          ┌───────────────────────┼───────────────────────┐
          ▼                       ▼                       ▼
        k3s                 cert-manager               Argo CD
   (+ Traefik by          (+ ClusterIssuer          (Helm, ingress
    default)              local-cluster-issuer)      on argocd.home.lab)
                                                          │
                                       applies 3 manifests│
                                                          ▼
                                   AppProject "tools"
                                   Secret   cluster-hub  (registers this cluster)
                                   AppSet   base-apps    ◄── the only
                                                          │    imperative step
                        generates one root app per registered cluster
                          base-apps-prod  (here)   [+ base-apps-dev, step 13]
                                                          │
                                 renders base-apps Helm chart
                                 (argocd-apps repo)
                                                          │
                      ┌───────────────────┴───────────────────┐
                      ▼                                       ▼
              values.charts (Helm)                    values.apps (git paths)
                      │                                       │
   ┌──────────┬───────┼───────┬──────────┐          ┌─────────┼─────────┐
   ▼          ▼       ▼       ▼          ▼          ▼         ▼         ▼
external-  kyverno  falco  argo-     kro, kargo  php-apache  ghost  kyverno-policy
 secrets   policy-        rollouts                                   (off by default)
           reporter
       (+ optional: keycloak, kube-green,
        dashboard, kube-prometheus-stack)
```

Then, applied separately from `04-ArgoCD/`:

| Manifest | Creates |
|---|---|
| `01-platforms.yml` | Application pulling kro ResourceGraphDefinitions from the `platform` repo |
| `02-teams.yml` | ApplicationSet — one app per directory in `team-apps/instances/*` |
| `04-kargo-app.yml` | ApplicationSet — `kargo-demo-{test,uat,prod}` |
| `05-fleet.yml` | ApplicationSet — one app per `apps/*/*` directory in `0-fleet-infra` |

---

## 2. Repositories involved

| Repo | Role |
|---|---|
| **myLab** (this one) | Provisioning + cluster-level manifests. The entry point. |
| **argocd-apps** | The `base-apps` Helm chart (platform catalog) and plain declarative apps. |
| **platform** | kro ResourceGraphDefinitions — the platform API. |
| **team-apps** | kro instances, one directory per team. |
| **0-fleet-infra** | Kustomize overlays per app and environment, driven by Kargo. |
| **kargo-demo** | Demo app whose stage branches Kargo writes to. |

Only **myLab** and **argocd-apps** are needed for steps 1–6. The rest come online
as you work through steps 7–9.

---

## 3. Prerequisites

**Target machine** (the node that becomes the cluster)

- Debian or Ubuntu — the role is guarded by `ansible_facts['os_family'] == "Debian"`
  and will silently skip everything on anything else.
- 4 vCPU / 8 GB RAM / 40 GB disk is comfortable once the security stack is on.
  Falco and kube-prometheus-stack are the hungry ones.
- SSH reachable, with a user that has passwordless `sudo`.
- `snapd` available (the role installs Helm as a snap).

**Control node** (your laptop)

- Ansible 2.15+, Python 3, `git`.
- Optional but useful: `kubectl`, `helm` — for inspecting and for rendering the
  chart locally before you push.

A Multipass VM works well:

```bash
multipass launch -n stormy -c 4 -m 8G -d 40G noble
multipass info stormy          # note the IPv4 address
```

---

## Step 1 — Prepare the target machine

If this is a fresh workstation-style box, `00-kubeSetup/scripts/starter.sh`
installs Docker, Multipass, VS Code, Ansible and a set of shell aliases. It is a
convenience for *your* machine, **not** a requirement for the cluster node.

```bash
# on the target, optional
bash 00-kubeSetup/scripts/starter.sh
```

The only hard requirements are SSH access and passwordless sudo:

```bash
ssh-copy-id youruser@<target-ip>
ssh youruser@<target-ip> 'sudo -n true && echo "passwordless sudo OK"'
```

---

## Step 2 — Prepare the control node

```bash
git clone https://github.com/josuecodjo/myLab.git
cd myLab/00-kubeSetup

python3 -m venv .venv && source .venv/bin/activate
pip install ansible

ansible-galaxy collection install -r collections/requirements.yml
```

`collections/requirements.yml` pins `kubernetes.core 6.6.0` (used for the Helm
installs) and `awx.awx 24.5.0` (only needed if you enable the AWX role).

---

## Step 3 — Configure inventory and variables

**3a. Point the inventory at your machine.** `hosts_global` declares one host
named `stormy` in the `linux` group:

```ini
[linux]
stormy
```

Edit `host_vars/stormy.yml` with the real address and user:

```yaml
---
ansible_host: 192.168.64.12     # <- your target's IP
ansible_user: youruser          # <- your SSH user
```

If you rename the host, rename `host_vars/stormy.yml` to match.

**3b. Set the cluster variables** in `vars/k8s.yml`. These are loaded by the
playbook's `pre_tasks` and override the role defaults:

```yaml
global_dns_name: home.lab       # ingress suffix -> argocd.home.lab
acme_mode: LOCAL                # LOCAL | AWS | Azure (case-sensitive!)
argocd_hostname: argocd
# argocd_env is superseded: the base-apps ApplicationSet picks
# values-<cluster>.yaml from each cluster's registration name (steps 6 and 13).
```

> `acme_mode` must exactly match a directory name under
> `roles/role-kube_init/templates/acme/` — `LOCAL`, `AWS` or `Azure`. This is
> case-sensitive on a Linux control node. The directory was tracked in git as
> `Local` while macOS reported it as `LOCAL`; git's `core.ignorecase` hid the
> mismatch. Both git and disk now say `LOCAL`, matching this variable.

`LOCAL` issues self-signed certificates — right for a homelab. `AWS` and `Azure`
use DNS-01 and need the credential fields in `vars/k8s.yml` filled in.

**3c. Add DNS entries** so the ingress hostnames resolve. `global_dns_name` is
the single suffix for the whole cluster — Ansible builds the Argo CD host from it
*and* hands it to the base-apps chart, which expands it into every component's
ingress host and TLS SAN. Change it once and everything follows.

```bash
# one line per component you enable
for h in argocd rollouts kargo kyverno grafana keycloak; do
  echo "<target-ip>  $h.home.lab" | sudo tee -a /etc/hosts
done
```

| Component | Host | Enabled by default |
|---|---|---|
| Argo CD | `argocd.<domain>` | yes |
| Argo Rollouts dashboard | `rollouts.<domain>` | yes |
| Kargo UI | `kargo.<domain>` | yes |
| Policy Reporter UI | `kyverno.<domain>` | with the `dev`/`qa`/`prod` overlay |
| Grafana | `grafana.<domain>` | no |
| Keycloak | `keycloak.<domain>` | no |
| Vault | `vault.<domain>` | no — enable deliberately, see step 11 |

A wildcard `*.home.lab` entry in your own resolver (dnsmasq, Pi-hole) saves
maintaining the list.

**3d. Check connectivity** before provisioning:

```bash
ansible -i hosts_global linux -m ping
```

---

## Step 4 — Run the playbook

```bash
cd 00-kubeSetup
ansible-playbook -i hosts_global playbook.yml
```

This takes roughly 5–10 minutes. The role is tag-gated, so you can run pieces of
it independently:

| Tag | What it does | Default |
|---|---|---|
| `k3s-traefik` | Installs k3s **with** Traefik | **on** |
| `k3s-neutral` | Installs k3s **without** Traefik | off (`never`) |
| `certmanager` | cert-manager + the ACME ClusterIssuer | on |
| `argocd` | Argo CD via Helm, then applies the bootstrap | on |
| `awx` | AWX operator + instance | off (`never`) |

```bash
# just re-run the Argo CD bootstrap
ansible-playbook -i hosts_global playbook.yml --tags argocd

# install k3s without Traefik instead of with it
ansible-playbook -i hosts_global playbook.yml --tags k3s-neutral

# include AWX
ansible-playbook -i hosts_global playbook.yml --tags awx
```

The `argocd` tag waits for the Argo CD deployment to roll out before applying
`tools-project.yml` and the rendered `bootstrap.yml`, so the bootstrap never
races the API server.

**Get a kubeconfig** on your laptop:

```bash
scp youruser@<target-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/mylab.yaml
sed -i '' "s/127.0.0.1/<target-ip>/" ~/.kube/mylab.yaml    # Linux: drop the ''
export KUBECONFIG=~/.kube/mylab.yaml
kubectl get nodes
```

---

## Step 5 — Reach Argo CD

Open **https://argocd.home.lab** (self-signed certificate — accept the warning).

Username `admin`. The password is set declaratively as a bcrypt hash in
`roles/role-kube_init/tasks/argocd/argocd.yml`, so the usual
`argocd-initial-admin-secret` is **not** created. To set your own:

```bash
# generate a hash
htpasswd -nbBC 10 "" 'your-new-password' | tr -d ':\n'
```

Put the result in `configs.secret.argocdServerAdminPassword` in that task file
and re-run `--tags argocd`.

> Keep real credentials out of git — use `ansible-vault encrypt_string` for that
> value rather than committing the hash.

No ingress? Port-forward instead:

```bash
kubectl port-forward svc/argo-cd-argocd-server -n argocd 8080:80
```

---

## Step 6 — Understand and drive the app-of-apps

The playbook applied exactly one Application, `base-apps`. It points at the
`base-apps` Helm chart in the **argocd-apps** repo, whose single template turns a
values catalog into one Argo CD Application per platform component.

```
base-apps/
├── templates/charts.yaml     # .Values.charts -> one Application per Helm chart
├── templates/apps.yaml       # .Values.apps   -> one Application per git path
├── templates/_helpers.tpl    # the syncPolicy both templates share
├── values.yaml               # THE CATALOG: chart repo, version, namespace, quirks
├── values-dev.yaml           # overrides only
├── values-qa.yaml            # overrides only
├── values-prod.yaml          # overrides only
└── app_charts/<name>/        # your values for each upstream chart

The catalog has two sections. `charts:` entries are upstream Helm charts;
`apps:` entries are plain manifest directories in this repo that Argo CD applies
with kustomize. Both render into Applications owned by the single root app, and
both honour the same `enabled` toggles and environment overlays.
```

### Enabling a component

Flip `enabled` in the catalog and push. Argo CD self-heals and the new
Application appears within three minutes (or hit **Refresh** on `base-apps`).

```yaml
# argocd-apps/base-apps/values.yaml
charts:
  kyverno:
    enabled: true          # <- that's the whole change
    namespace: kyverno
    serverSideApply: true
    helm:
      - repoURL: https://kyverno.github.io/kyverno
        targetRevision: 3.8.1
```

### Adding a plain-manifest app

Drop the manifests in `declarative/apps/<name>/` with a `kustomization.yml`,
then add four lines to the `apps:` section:

```yaml
# argocd-apps/base-apps/values.yaml
apps:
  my-thing:
    enabled: true
    path: declarative/apps/my-thing
    namespace: default
```

`php-apache` and `ghost` ship enabled, so they land in the cluster on the first
sync. `kyverno-policy` ships disabled — enable it only after the `kyverno` chart
is on, since its CRDs must exist first. Those policies are scoped to `tenant-*`
namespaces, so they will not block anything running in `default`.

> **Why not an ApplicationSet here?** A git *directories* generator exposes only
> `path` and `path.basename`, so you get no per-app namespace, no `enabled`
> toggle, and no per-environment differences — every directory becomes an app in
> every environment. ApplicationSets are the right tool when the set is
> open-ended and owned by someone else, which is why `02-teams.yml` and
> `05-fleet.yml` use them. If this folder ever becomes self-service, move it to
> an ApplicationSet with a git **files** generator (a small `config.yaml` inside
> each app directory), which keeps auto-discovery *and* per-app config.

### Tuning a component

Edit `base-apps/app_charts/<name>/values.yaml`. The chart wires it in through
Argo CD's multi-source `$values` reference, so upstream charts stay unvendored.

### Environment overlays

`values.yaml` is the catalog — it owns chart repos, versions and namespaces.
`values-dev|qa|prod.yaml` carry **only** differences, usually just `enabled`
toggles. Helm deep-merges maps, so an overlay entry keeps everything the catalog
declared.

Select one at provisioning time:

```yaml
# vars/k8s.yml
argocd_env: dev     # -> valueFiles: [values.yaml, values-dev.yaml]
```

```bash
ansible-playbook -i hosts_global playbook.yml --tags argocd
```

Leaving `argocd_env: ""` loads the catalog alone.

> **Caveat:** Helm *replaces* lists rather than merging them. To pin a different
> chart version in one environment, restate the whole `helm:` entry in that
> overlay.

### Preview before you push

```bash
cd ../argocd-apps
helm template base-apps base-apps -f base-apps/values.yaml
helm template base-apps base-apps -f base-apps/values.yaml -f base-apps/values-dev.yaml
```

### Changing the DNS domain

One variable drives every hostname:

```
vars/k8s.yml: global_dns_name
      │
      ├─► argocd_hostname + global_dns_name  ──► Argo CD ingress + TLS
      │
      └─► bootstrap.yml.j2 helm parameter `global.dnsName`
                 │
                 └─► base-apps chart ──► templatedValues ──► each component's
                                          ingress host + TLS SAN
```

To move a cluster to a different domain, set `global_dns_name`, re-run
`--tags argocd`, and update DNS. Nothing else changes — the certificates are not
pinned to a domain (see below), and no hostname is hardcoded in `app_charts/`.

Per-component subdomains live in the `templatedValues` block of each catalog
entry, because the five charts each use a different ingress schema
(`api.host`, `ingress.hostname`, `dashboard.ingress.hosts[]`,
`ui.ingress.hosts[].host`, `grafana.ingress.hosts[]`).

> **`extraValues` vs `templatedValues`** — `templatedValues` is rendered through
> Helm's `tpl`, so it can reference `{{ .Values.global.dnsName }}`.
> `extraValues` is passed through verbatim; keep anything containing literal Go
> template syntax (Alertmanager templates, Falco rules, Grafana dashboards)
> there, or `tpl` will try to evaluate it and fail.

### About the TLS certificates

The certificates are **not** tied to `home.lab`. The chain has no DNS name in it
anywhere — cert-manager's ingress-shim reads each Ingress's `tls[].hosts` and
mints a certificate with exactly those SANs. Change `global_dns_name`, re-run,
and you get new certificates for the new domain. The same chain works unchanged
on any other cluster.

`acme_mode: LOCAL` builds a **local certificate authority** rather than a pile of
unrelated self-signed certs:

```
selfsigned-bootstrap (ClusterIssuer)   signs only the CA below
         │
         ▼
homelab-ca (Certificate, isCA: true)   the lab root CA
         │                             -> secret homelab-ca-tls in cert-manager
         ▼
local-cluster-issuer (ClusterIssuer)   signs every component's certificate
```

Trust `homelab-ca` once on your workstation and every `*.<domain>` certificate in
the cluster is valid — no more per-hostname browser warnings. The final issuer
keeps the name `local-cluster-issuer`, so none of the
`cert-manager.io/cluster-issuer` annotations in `app_charts/` change.

The playbook writes the root CA to `00-kubeSetup/homelab-ca.crt` on your control
node and prints how to trust it:

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain homelab-ca.crt

# Debian / Ubuntu
sudo cp homelab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
```

Firefox keeps its own trust store: Settings → Privacy & Security → Certificates →
View Certificates → Authorities → Import.

The CA is valid for 10 years and renews a year before expiry, so trusting it is a
one-time action per workstation.

#### Migrating an existing cluster

If your cluster already ran the old self-signed `local-cluster-issuer`, switching
the issuer does **not** re-sign existing certificates — they stay valid until
their own renewal, so they keep showing browser warnings. Force a re-issue by
deleting the secrets of the certificates that use this issuer:

```bash
kubectl get certificates -A \
  -o jsonpath='{range .items[?(@.spec.issuerRef.name=="local-cluster-issuer")]}{.metadata.namespace}{" "}{.spec.secretName}{"\n"}{end}' \
| sed '/^$/d' | while read ns secret; do kubectl delete secret -n "$ns" "$secret"; done
```

cert-manager reissues each one within seconds, now signed by the lab CA. The
filter matters: it deliberately skips certificates owned by other issuers, such
as Kargo's internal `kargo-selfsigned-cert-issuer` webhook certs, which are part
of Kargo's own TLS and must not be touched.

Expect a few seconds of TLS errors per host while each secret is recreated.

### Per-app keys — `charts:`

| Key | Effect |
|---|---|
| `enabled` | Render this Application at all |
| `helm` | List of sources: `repoURL` + `targetRevision`, or `localChart: true` |
| `namespace` | Destination namespace (default: `dest_namespace`) |
| `project` | Argo CD AppProject (default: `dest_project`) |
| `chartName` | Chart name and `app_charts/` directory (default: the key) |
| `serverSideApply` | Adds `ServerSideApply=true` — needed for large CRDs |
| `autosync_enabled` | Set `false` to drop `syncPolicy` entirely |
| `extraValues` | Inline values merged over the `app_charts` file, verbatim |
| `templatedValues` | Same, but rendered with `tpl` first — use for `global.dnsName` |

> **OCI-hosted charts (kro, Kargo) use the bare host — no `oci://` scheme.**
> Argo CD has two modes. A bare host plus `chart` means "Helm chart in an OCI
> registry" and resolves as `<repoURL>/<chart>:<targetRevision>`. Adding `oci://`
> switches it to OCI-artifact mode, where `repoURL` is the *complete* reference
> and `chart` is ignored, so the chart segment never gets appended and you get:
>
> ```
> failed to resolve revision "1.12.5": cannot get digest for revision 1.12.5:
> HEAD "https://ghcr.io/v2/akuity/kargo-charts/manifests/1.12.5": 403 denied
> ```
>
> Note the missing `/kargo` in that URL. Verified on Argo CD v3.6.1.

### Per-app keys — `apps:`

| Key | Effect |
|---|---|
| `enabled` | Render this Application at all |
| `path` | Directory in the repo holding the manifests (**required**) |
| `repoURL` | Source repo (default: `spec.source.repoURL`) |
| `targetRevision` | Source revision (default: `spec.source.targetRevision`) |
| `namespace` | Destination namespace (default: `dest_namespace`) |
| `project` | Argo CD AppProject (default: `dest_project`) |
| `autosync_enabled` | Set `false` to drop `syncPolicy` entirely |

An entry that is `enabled` without a `path` fails the render with a clear
message rather than producing a broken Application.

---

## Step 7 — Deploy the ApplicationSets

```bash
kubectl apply -f 04-ArgoCD
```

This applies the platform Application and the three ApplicationSets listed in
[§1](#1-what-gets-built). `00-bootstrap.yml` in that directory is the same root
app Ansible already applied — harmless to re-apply, and useful if you ever
bootstrap a cluster by hand.

> **`00-bootstrap.yml` is no longer in this directory** — it moved to
> `04-ArgoCD/manual/`, and `kubectl apply -f` is not recursive, so applying
> `04-ArgoCD` can no longer touch the root app. It previously sat here, and
> applying the directory silently dropped the root app's `global.dnsName` Helm
> parameter: every ingress host reverted to the catalog default (`home.lab`)
> and cert-manager reissued every certificate for the wrong name. The root app
> belongs to Ansible — `--tags argocd` — which renders the parameter from
> `global_dns_name`. Use `manual/00-bootstrap.yml` only for a hand bootstrap,
> and set `global.dnsName` in it first.

> There is no `06-gitops.yml` any more. The apps it used to pull from
> `declarative/root/` are now entries in the catalog's `apps:` section, owned by
> the one root app. If you bootstrapped a cluster before that change, clean up
> the orphans once:
>
> ```bash
> kubectl delete application my-apps phpapache -n argocd --ignore-not-found
> ```
>
> The old `php-apache` Application was named `phpapache`; the catalog names it
> `php-apache` after its directory. Delete the old one or two Applications will
> fight over the same Deployment.

Each ApplicationSet needs its source repo to exist and be reachable; skip the
ones whose repos you haven't created.

```bash
kubectl get applications -n argocd
kubectl get applicationsets -n argocd
```

---

## Step 8 — kro abstractions

kro lets you publish a simplified API (a ResourceGraphDefinition) that expands
into many Kubernetes objects.

```bash
cd 03-kro

kubectl apply -f 00-abstract      # the RGDs (the platform API)
kubectl get rgd
kubectl get rgd application -o wide

kubectl apply -f 01-apps          # instances that consume those APIs
kubectl get applications.kro.run
```

Wait for each RGD to report `Active` before applying instances — the CRD it
generates must exist first.

In the full setup, `04-ArgoCD/01-platforms.yml` syncs the RGDs from the
`platform` repo and `02-teams.yml` syncs instances from `team-apps`, so this
manual step is the local-development shortcut.

---

## Step 9 — Kargo promotion pipeline

Kargo watches a container registry and promotes new images through
`test → uat → prod` by committing rendered manifests to stage branches, which
Argo CD then syncs.

**9a. Create a GitHub fine-grained PAT** — Settings → Developer settings →
Personal access tokens → Fine-grained tokens. Scope it to the single GitOps repo
and grant **Contents: Read and write**.

**9b. Export the values and apply:**

```bash
export GITOPS_REPO_URL=https://github.com/<you>/kargo-demo
export GITHUB_USERNAME=<you>
export GITHUB_PAT=<your-token>

envsubst < 05-kargo/kargo.yml | kubectl apply -f -
```

> `envsubst` ships with GNU gettext (`brew install gettext` on macOS). It expands
> `${GITOPS_REPO_URL}` and friends while leaving Kargo's own `${{ ... }}`
> expressions untouched.

`kargo.yml` creates the Project, the git credential Secret, the Warehouse
(subscribed to `public.ecr.aws/nginx/nginx`), the reusable PromotionTask, and the
three Stages.

For the multi-app fleet variant, apply `0-fleet.yml`, `1-promotion.yml`,
`3-java-fleet.yml` and `4-python-fleet.yml` in that order — and replace the
`YOUR_GITHUB_PAT` placeholder in `0-fleet.yml` first.

**9c. Watch it:**

```bash
kubectl get warehouses,stages,promotions -n kargo-demo
kubectl port-forward svc/kargo-api -n kargo 8081:80
```

> `how-kargo.md` is gitignored because it holds a live token. Never commit
> credentials — prefer External Secrets or a sealed secret for the Kargo
> credential Secret.

---

## Step 10 — Validate the security stack

Requires `kyverno`, `policy-reporter` and `falco` enabled (see step 6).

**Kyverno — admission policies**

```bash
cd 01-security

kubectl apply -f kyverno/policies/            # or let Argo CD sync them

kubectl apply -f kyverno/test-pods/good-pod.yaml   # succeeds
kubectl apply -f kyverno/test-pods/bad-pod.yaml    # FAILS: missing team label
kubectl run latest-pod --image=nginx:latest        # FAILS: :latest not allowed
kubectl run pinned-pod --image=nginx:1.25          # FAILS: missing team label

kubectl port-forward svc/policy-reporter-ui 8001:8080 -n policy-reporter
# -> http://localhost:8001
```

**Falco — runtime detection**

```bash
kubectl port-forward svc/falco-falcosidekick-ui 8000:2802 -n falco
# -> http://localhost:8000   (admin / admin)

# trigger a detection, then watch the Events tab
kubectl exec -it good-pod -- cat /etc/shadow
```

---

## Step 11 — Vault (optional, needs manual initialisation)

Vault ships `enabled: false` in the catalog because Argo CD can install it but
**cannot initialise it**. This step is the one place in the lab where GitOps
genuinely cannot finish the job.

**11a. Enable the two charts** in `argocd-apps/base-apps/values.yaml`:

```yaml
charts:
  vault:
    enabled: true                  # wave 3
  vault-secrets-operator:
    enabled: true                  # wave 0
```

Push, and wait for the `vault` Application to appear. It will sit **Progressing,
not Healthy** — that is expected. The chart's readiness probe is `vault status`,
which fails while Vault is sealed, so the pod never becomes Ready. Vault is in
the last sync wave precisely so this cannot stall anything else.

**11b. Initialise once per cluster:**

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=5 -key-threshold=3
```

> Save the 5 unseal keys and the root token **outside the cluster** now. There is
> no recovery path. Note also that `local-path` uses a `Delete` reclaim policy, so
> losing the PVC loses the data even if you still hold the keys.

**11c. Unseal — 3 of the 5 keys:**

```bash
for i in 1 2 3; do kubectl exec -ti -n vault vault-0 -- vault operator unseal; done
kubectl get pod -n vault vault-0        # now 1/1 Running, app goes Healthy
```

**11d. Enable Kubernetes auth** so VSO can authenticate without any stored
credential:

```bash
kubectl exec -ti -n vault vault-0 -- sh
  export VAULT_TOKEN=<root token>
  vault auth enable kubernetes
  vault write auth/kubernetes/config \
      kubernetes_host=https://kubernetes.default.svc

  vault policy write vso-demo - <<'EOF'
path "secret/data/demo" { capabilities = ["read"] }
EOF

  vault write auth/kubernetes/role/vso-demo \
      bound_service_account_names=vault-demo \
      bound_service_account_namespaces=vault-secrets-operator \
      policies=vso-demo ttl=1h

  vault kv put secret/demo message=hello
```

AppRole would have needed a role-id/secret-id pair planted in the cluster first —
a secret in order to fetch secrets. Kubernetes auth avoids that: Vault validates
VSO's ServiceAccount token via `TokenReview`, which is why the chart's
`server.authDelegator` must stay enabled.

**11e. Prove the chain**, by enabling `apps.vault-config` and syncing it by hand
(it has `autosync_enabled: false`, since it can only succeed after the steps
above):

```bash
argocd app sync vault-config          # or Sync in the UI
kubectl get secret vault-demo -n vault-secrets-operator \
  -o jsonpath='{.data.message}' | base64 -d        # -> hello
```

That confirms `VaultAuth` → Kubernetes auth → KV v2 → Kubernetes Secret. Delete
the demo `VaultStaticSecret` afterwards; it is scaffolding, not a fixture.

**After every reboot:** Vault re-seals, so repeat 11c. Until you do, the `vault`
app is Progressing and the root `base-apps` app shows not-Healthy — everything
else stays synced and unaffected. If that becomes tiresome, the alternative is
storing unseal keys in a Secret with a Job that unseals on start, which trades
away much of Vault's threat model.

---

## Step 12 — Observability from outside the cluster

A self-contained starter kit for someone learning to collect metrics and logs
from this lab using their **own** stack, running outside the cluster: see
[06-observability/README.md](06-observability/README.md).

It is built to be handed to someone else, so it states what is already reachable
rather than prescribing tools:

| | |
|---|---|
| Host metrics | already open — `http://<node>:9100/metrics`, no cluster change needed |
| Host logs | journald on the node (3.9 GB of history) and `/var/log` |
| Cluster metrics | kubelet `:10250` and the API `:6443` need a token — `06-observability/manifests/external-scraper.yaml` provides a read-only one |
| Load generator | `06-observability/scripts/load-test.sh --mode node\|hpa\|both` |

The load script saturates the host (verified: 16 cores to 99%) or drives the
`php-apache` HPA (verified: 1→10 replicas), with a hard duration cap, an opt-in
and capped memory option, and three independent stop mechanisms. Start with
`--dry-run`.

This is the rung below the practice's Phase 1 target architecture: understand the
collection targets from outside before building the in-cluster OpenTelemetry
pipeline.

---

## Step 13 — Add a dev cluster, supervised by this one

A second k3s cluster on another machine, with **no Argo CD and no Grafana of its
own**: this cluster becomes the hub for both. See
[argocd-apps README §9](https://github.com/josuecodjo/argocd-apps#9-multi-cluster-hub-and-spoke)
for how the catalog targets several clusters.

### 13a. The cutover on the hub — read this first

The platform used to be driven by one root Application called `base-apps`. It is
now driven by an **ApplicationSet** that generates one root app per registered
cluster, so the hub's becomes `base-apps-prod`. The children keep identical names,
so the new parent adopts them — **but only if the old parent is removed without
pruning**.

> `kubectl delete app base-apps` cascades through `resources-finalizer` and
> **deletes the entire platform** — Vault, Kargo, everything. The finalizer must
> come off first.

```bash
# 1. prove the only change is the new cluster label (nothing else moves)
cd ../argocd-apps
helm template b base-apps -f base-apps/values.yaml --set global.dnsName=prod.lab > /tmp/before.yaml
helm template b base-apps -f base-apps/values.yaml -f base-apps/values-prod.yaml > /tmp/after.yaml
diff /tmp/before.yaml /tmp/after.yaml      # expect ONLY externalLabels: cluster: prod

# 2. strip the finalizer so deletion cannot prune the children
kubectl patch app base-apps -n argocd --type=merge -p '{"metadata":{"finalizers":null}}'

# 3. delete the old root; the nine children keep running, briefly unmanaged
kubectl delete app base-apps -n argocd
kubectl get app -n argocd                  # the nine must still be listed

# 4. hand over to the ApplicationSet
ansible-playbook -i hosts_global playbook.yml --tags argocd

# 5. adoption, not recreation: the children's ages must PREDATE the cutover
kubectl get app -n argocd -o custom-columns=\
NAME:.metadata.name,AGE:.metadata.creationTimestamp,SYNC:.status.sync.status
```

The playbook also asserts that Argo CD's implicit `in-cluster` entry did **not**
also match the generator's label selector — a `base-apps-in-cluster` would render
children colliding with the hub's. If that task fails, set
`cluster.inClusterEnabled: "false"` in `argocd-cmd-params-cm`; it is safe because
the hub is now registered explicitly via `04-ArgoCD/manual/cluster-hub.yaml`.

### 13b. Provision the dev host

Add the machine to `00-kubeSetup/hosts_global` and give it a
`host_vars/<name>.yml` with its `ansible_host` and `ansible_user`, plus
`global_dns_name: dev.lab` so its hostnames never collide with `*.prod.lab`.

Then install **k3s and cert-manager only** — deliberately not `argocd`:

```bash
ansible-playbook -i hosts_global playbook.yml --limit dev --tags k3s-traefik,certmanager
```

cert-manager is still wanted there: it issues the certificate for the Prometheus
ingress the hub reads.

> Dev mints its **own** lab CA, so browsing dev UIs means trusting a second root
> on your workstation. The hub's Grafana sidesteps this by querying dev over
> plain http.

### 13c. Register dev with the hub

```bash
# on DEV: create the identity the hub will use
kubectl --context dev apply -f 04-ArgoCD/manual/argocd-manager.yaml

# on the HUB: register it, which is all the ApplicationSet needs
ansible-playbook -i hosts_global playbook.yml --tags argocd \
  -e spoke_cluster_enabled=true \
  -e spoke_name=dev \
  -e spoke_cluster_api=https://<dev-ip>:6443 \
  -e spoke_kube_context=dev
```

A `base-apps-dev` root app should appear with no extra manifest. Its children all
carry a `-dev` suffix and target the dev cluster.

### 13d. Let the hub's Grafana see dev

Grafana runs in a **pod**, so it resolves hostnames through CoreDNS — the node's
`/etc/hosts` is irrelevant to it. Edit `<dev-ip>` into
`04-ArgoCD/manual/coredns-custom.yaml`, then:

```bash
kubectl apply -f 04-ArgoCD/manual/coredns-custom.yaml
kubectl rollout restart deploy/coredns -n kube-system

kubectl exec -n monitoring deploy/kube-prometheus-stack-grafana -c grafana -- \
  wget -qO- 'http://prometheus.dev.lab/api/v1/query?query=up' | head -c 120
```

The `Prometheus-dev` datasource is already declared in the catalog, so it appears
in Grafana once the name resolves. Prove both clusters are distinguishable:

```bash
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/label/cluster/values'
# ["prod"]  -- and the Prometheus-dev datasource answers ["dev"]
```

Finally, `06-observability/scripts/load-test.sh` run against dev should show the
spike in the hub's Grafana through that datasource.

---

## Teardown

```bash
# remove the GitOps layer but keep the cluster
kubectl delete -f 04-ArgoCD
kubectl delete application base-apps -n argocd

# nuke the cluster entirely (on the target machine)
ssh youruser@<target-ip> 'sudo /usr/local/bin/k3s-uninstall.sh'
```

`base-apps` and its children carry the `resources-finalizer` finalizer, so
deleting the root Application cascades to everything it created. Give it a
minute before uninstalling k3s.

---

## Troubleshooting

**The playbook does nothing.** The whole role is wrapped in
`when: ansible_facts['os_family'] == "Debian"`. On RHEL, Alpine or macOS every
task is skipped without error.

**`template not found` on the ACME issuer.** `acme_mode` doesn't match a
directory under `templates/acme/`. It must be `LOCAL`, `AWS` or `Azure` —
case-sensitive on a Linux control node.

**Argo CD app stuck `Unknown` with `failed to resolve revision` on kro or Kargo.**
The `repoURL` has an `oci://` scheme. Remove it — use the bare host
(`ghcr.io/akuity/kargo-charts`) so Argo CD appends `chart` and resolves
`<repoURL>/<chart>:<targetRevision>`. With `oci://`, `chart` is ignored and the
chart segment never makes it into the request, which ghcr.io answers with
`403 denied` (it does not distinguish "no such repository" from "no access").
Confirm the real reference resolves first:

```bash
helm show chart oci://ghcr.io/akuity/kargo-charts/kargo --version 1.12.5
helm show chart oci://registry.k8s.io/kro/charts/kro    --version 0.10.0
```

The app can report `Healthy` while sync is `Unknown`: health describes the
resources already in the cluster, so a fresh app with nothing deployed looks
healthy even though the comparison is failing. Check
`kubectl get app -n argocd <name> -o jsonpath='{.status.conditions}'`.

**CRD too large / annotation size errors.** Set `serverSideApply: true` on that
entry in `values.yaml`. Already set for `kyverno` and `kube-prometheus-stack`.

**A component won't go away after `enabled: false`.** The root app prunes, but
check the child Application's finalizer actually ran:
`kubectl get application <name> -n argocd -o yaml`.

**Every hostname suddenly reverted to `home.lab`.** Something overwrote the root
`base-apps` Application without its `global.dnsName` Helm parameter — most likely
applying a stale bootstrap manifest by hand. Check it:

```bash
kubectl get app base-apps -n argocd -o jsonpath='{.spec.source.helm}'
# must contain: {"name":"global.dnsName","value":"<your domain>"}
```

Fix by re-running `ansible-playbook -i hosts_global playbook.yml --tags argocd`.
Children re-render within two reconciles and cert-manager reissues each
certificate for the corrected SAN automatically. Note `argocd.<domain>` itself
is unaffected, because that ingress comes from the Argo CD Helm release rather
than from base-apps — so Argo CD staying reachable on the right host is *not*
evidence the rest is fine.

**Ingress hostname doesn't resolve.** Add `<target-ip> <host>.home.lab` to
`/etc/hosts` for each component you enabled (step 3c), or port-forward (step 5).

**`acme_mode: AWS` doesn't give you Let's Encrypt.** `templates/acme/AWS/global/issuer.yaml.j2`
is a bare `selfSigned` ClusterIssuer — it never had a DNS-01 solver, and it did
not get the CA chain that LOCAL now has. Only the `awx/` variants carry real
DNS-01 config. `acme_mode: Azure` fails outright: the task looks for
`acme/Azure/global/issuer.yaml.j2` and only `acme/Azure/issuer.yaml.j2` exists.
Treat LOCAL as the only working mode until those are filled in.

**Browser still warns after enabling the CA.** Two causes. Either you haven't
trusted `homelab-ca.crt` yet (step 6), or the certificate predates the switch —
existing certs are not re-signed automatically; see *Migrating an existing
cluster*. Check which issuer signed what with
`kubectl get certificate -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ISSUER:.spec.issuerRef.name`.

**`local-cluster-issuer` never becomes Ready.** It is a `ca` issuer now, so it
needs the `homelab-ca-tls` secret in cert-manager's cluster-resource-namespace.
That namespace follows cert-manager's own (`cert-manager`) unless you changed
`--cluster-resource-namespace`. Check the CA first:
`kubectl describe certificate homelab-ca -n cert-manager`.

**Changes don't appear.** Argo CD reconciles every 2 minutes
(`timeout.reconciliation: 120s`). Click **Refresh** on the `base-apps` app, or
`argocd app get base-apps --refresh`.

---

## Known gaps

Honest list of what this setup does *not* do yet:

- **The `tools` AppProject allows everything** — `sourceRepos: ['*']`,
  all destinations, all cluster resources. It enforces no guardrails today.
- **`04-ArgoCD/` is applied imperatively.** Those ApplicationSets aren't owned by
  any Application, so they drift and never prune. Folding them into the
  `base-apps` chart would close the loop.
- **Secrets are in plaintext** in the Ansible vars, the Kargo manifests, and
  `app_charts/kargo/values.yaml` (admin password hash + token signing key) and
  `app_charts/keycloak/values.yaml` (admin/admin). Use `ansible-vault` and
  External Secrets.
- **`acme_mode` AWS and Azure are not wired up.** Only LOCAL builds a real
  chain (self-signed bootstrap → lab CA → issuer). AWS is still a bare
  `selfSigned` ClusterIssuer and Azure has no `global/` template at all. See
  Troubleshooting.
- **The hub is a single point of failure for deployments** once a second cluster
  is registered (step 13). A spoke keeps serving if the hub dies; it just cannot
  be changed.
- **Each cluster mints its own lab CA**, so browsing a spoke's UIs means trusting
  a second root on your workstation. Sharing one CA needs a spoke variant of the
  issuer template that skips the `homelab-ca` Certificate and points the CA
  ClusterIssuer at a copied secret.
- **The spoke Grafana datasource is plain http and unauthenticated.** Acceptable
  LAN-internal in a lab; not beyond one.
- **Single node per cluster, no backups.** No etcd snapshots, no PV backup
  strategy.
