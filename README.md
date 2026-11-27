# myLab — a reproducible GitOps homelab

A single-node k3s cluster, provisioned by Ansible, that bootstraps itself into a
full GitOps platform: Argo CD manages every component, Kyverno and Falco enforce
and watch security, kro provides application abstractions, and Kargo promotes
releases across stages.

Everything after the Ansible run is declarative. You apply **one** Application;
Argo CD creates the rest.

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
14. [Teardown](#teardown)
15. [Troubleshooting](#troubleshooting)
16. [Known gaps](#known-gaps)

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
                                       applies 2 manifests│
                                                          ▼
                                            AppProject "tools"
                                            Application "base-apps"  ◄── the only
                                                          │               imperative step
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
argocd_env: ""                  # "" | dev | qa | prod  (see step 6)
```

> `acme_mode` must exactly match a directory name under
> `roles/role-kube_init/templates/acme/` (`LOCAL`, `AWS`, `Azure`). The value was
> previously `Local`, which only resolved on case-insensitive filesystems like
> macOS and broke on a Linux control node.

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

The certificates are **not** tied to `home.lab`. `local-cluster-issuer` is a
`selfSigned` ClusterIssuer — it contains no DNS name at all. cert-manager's
ingress-shim reads each Ingress's `tls[].hosts` and mints a certificate with
exactly those SANs, so a new domain just produces new certificates on the next
sync. The same issuer works unchanged on any other cluster.

The trade-off is that `selfSigned` makes every certificate its own root, so each
hostname throws a separate browser warning and there is nothing you can trust
once. For a lab that serves several UIs, a local CA is nicer: bootstrap a CA
certificate from the self-signed issuer, then issue everything from a `ca`
ClusterIssuer and trust that single root on your laptop.

```yaml
# a sketch - replaces templates/acme/LOCAL/global/issuer.yaml.j2
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: "{{ global_dns_name }} local CA"
  secretName: homelab-ca-tls
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: selfsigned-bootstrap, kind: ClusterIssuer }
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-cluster-issuer     # same name, so no ingress annotation changes
spec:
  ca:
    secretName: homelab-ca-tls
```

Keeping the name `local-cluster-issuer` means none of the
`cert-manager.io/cluster-issuer` annotations in `app_charts/` need to change.

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

OCI-hosted charts (kro, Kargo) must use the `oci://` scheme in `repoURL`.

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

**Argo CD app stuck `Unknown` / repo errors on kro or Kargo.** OCI chart repos
need the `oci://` scheme in `repoURL`. Bare `ghcr.io/...` only works if the
repository was registered separately with `enableOCI: true`.

**CRD too large / annotation size errors.** Set `serverSideApply: true` on that
entry in `values.yaml`. Already set for `kyverno` and `kube-prometheus-stack`.

**A component won't go away after `enabled: false`.** The root app prunes, but
check the child Application's finalizer actually ran:
`kubectl get application <name> -n argocd -o yaml`.

**Ingress hostname doesn't resolve.** Add `<target-ip> <host>.home.lab` to
`/etc/hosts` for each component you enabled (step 3c), or port-forward (step 5).

**`acme_mode: AWS` doesn't give you Let's Encrypt.** `templates/acme/AWS/global/issuer.yaml.j2`
is byte-identical to the LOCAL one — both are `selfSigned`. Only the `awx/`
variants carry real DNS-01 solvers. `acme_mode: Azure` fails outright: the task
looks for `acme/Azure/global/issuer.yaml.j2` and only `acme/Azure/issuer.yaml.j2`
exists. Treat LOCAL as the only working mode until those are filled in.

**Changes don't appear.** Argo CD polls every 3 minutes. Click **Refresh** on the
`base-apps` app, or `argocd app get base-apps --refresh`.

---

## Known gaps

Honest list of what this setup does *not* do yet:

- **No sync waves.** Every child Application syncs concurrently, so CRD-before-CR
  ordering relies on Argo CD's retries rather than explicit
  `argocd.argoproj.io/sync-wave` annotations. The `apps.kyverno-policy` entry is
  the clearest case: its ClusterPolicies need the `charts.kyverno` CRDs to exist
  first, which is why it ships disabled and you enable it as a second step.
- **The `tools` AppProject allows everything** — `sourceRepos: ['*']`,
  all destinations, all cluster resources. It enforces no guardrails today.
- **`04-ArgoCD/` is applied imperatively.** Those ApplicationSets aren't owned by
  any Application, so they drift and never prune. Folding them into the
  `base-apps` chart would close the loop.
- **Secrets are in plaintext** in the Ansible vars, the Kargo manifests, and
  `app_charts/kargo/values.yaml` (admin password hash + token signing key) and
  `app_charts/keycloak/values.yaml` (admin/admin). Use `ansible-vault` and
  External Secrets.
- **`acme_mode` AWS and Azure are not wired up** — AWS is a copy of the
  self-signed LOCAL issuer and Azure has no `global/` template. See
  Troubleshooting.
- **`local-cluster-issuer` is `selfSigned`,** so every hostname gets its own
  untrusted root. A `ca` ClusterIssuer bootstrapped from it would let you trust
  one local CA instead (sketch in step 6).
- **Single node, no backups.** No etcd snapshots, no PV backup strategy.
