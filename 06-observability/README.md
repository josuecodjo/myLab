# 06 — Observability: collect from outside the cluster first

A starter kit for building an observability stack **outside** this cluster and
pointing it inward. Host first, then the cluster.

You pick the tools. This directory tells you what is already reachable, what
isn't, what decisions you need to make, and how to put real load on the box when
you want to see your graphs move.

Context: this maps to **Phase 1 — Standardize telemetry** in the practice's
*Observability & Self-Healing* deck (storage layer: Prometheus/Mimir for metrics,
Loki for logs). The deck's lab-track ask is the in-cluster OTel Collector pipeline;
this is the rung below it, so you understand the targets before you instrument them.

---

## The lab you are pointing at

One node, k3s, running its own control plane.

| | |
|---|---|
| Node | one k3s host, 16 CPU / 31 GB |
| Ingress | Traefik, hosts resolve via your `/etc/hosts` (`*.prod.lab`) |
| TLS | cert-manager with a local CA — see `myLab/README.md` step 6 to trust it |
| Already deployed | Prometheus + Grafana + Alertmanager (kube-prometheus-stack), Argo CD, Vault, Kargo, kro |

The lab already has its own in-cluster Prometheus. **That is not your stack** — it
is one of the things you are learning to collect from. Leave it alone; use it to
check your own numbers against.

### Set this first

Every command below assumes two variables. `K3S_HOST` is the **IP of the k3s host
machine** — the box running the cluster, which is also the address its ingress and
host-level endpoints answer on. `K3S_USER` is the SSH user on that host (the
`ansible_user` from `00-kubeSetup/host_vars/<host>.yml`).

```bash
export K3S_HOST=10.0.0.10        # <- your k3s host machine's IP
export K3S_USER=youruser         # <- SSH user on that host
```

Find them with, respectively, `kubectl get nodes -o wide` (the `INTERNAL-IP`
column) and `grep ansible_ 00-kubeSetup/host_vars/*.yml`.

---

## What is already reachable from outside — verified

| Target | Endpoint | Auth | Status |
|---|---|---|---|
| Host metrics | `http://$K3S_HOST:9100/metrics` | none | **works today** — node-exporter runs with `hostNetwork: true` |
| Host logs | journald on the node, `/var/log` | ssh | **3.9 GB** of real history waiting |
| Container logs | `/var/log/pods/` on the node | ssh | 40 pod directories, readable as files |
| kubelet / cAdvisor | `https://$K3S_HOST:10250/metrics/cadvisor` | **bearer token** | reachable, returns `401` |
| Kubernetes API | `https://$K3S_HOST:6443` | **bearer token** | reachable, returns `401` |
| kube-state-metrics | ClusterIP only | — | **not reachable** — needs the API proxy or an ingress |
| In-cluster Prometheus | ClusterIP only | — | **not reachable** — needs an ingress to federate |

Check the two free ones before you build anything:

```bash
curl -s "http://$K3S_HOST:9100/metrics" | head -5
ssh "$K3S_USER@$K3S_HOST" 'sudo journalctl -n 5 --no-pager'
```

---

## The path

Four steps. **The first two need no changes to this cluster at all** — that is
deliberate, and it is why you start there.

### Step 1 — Host metrics, from outside

Stand up your metrics stack wherever you like (your laptop, a second VM) and
scrape the k3s host on `$K3S_HOST:9100`.

**Done when:** a host CPU graph is rendering in *your* Grafana, not the lab's.

> **Decide, and write down why.** Those host metrics come from a *container* that
> borrows the host's network namespace and mounts its `/proc` and `/sys`. Is that
> "outside the cluster"? A purist installs `node_exporter` as a systemd unit on the
> host and owns the host layer independently of k3s — right now
> `systemctl is-active node_exporter` returns `inactive`, there is no host service.
> Both answers are defensible. The reasoning is the exercise.

### Step 2 — Host logs, from outside

journald has 3.9 GB of history and `/var/log` is right there. Your agent runs on
the host, or pulls over syslog.

**Done when:** you can search for a journald line from the host — try a `k3s` or
`sshd` message — in your own log backend.

> Note the volume. 3.9 GB of journal on a lab box is a useful early lesson in
> retention and in dropping noise at the source rather than after storage.

### Step 3 — Cluster metrics, from outside

This is where it stops being free: everything except node-exporter is ClusterIP,
and kubelet and the API return `401`. Two routes — understand both, pick one.

**a) Scrape directly with a token.** Apply the read-only identity in this
directory:

```bash
kubectl apply -f manifests/external-scraper.yaml
TOKEN=$(kubectl get secret external-scraper -n monitoring -o jsonpath='{.data.token}' | base64 -d)

# kubelet + cAdvisor, straight from outside
curl -sk -H "Authorization: Bearer $TOKEN" "https://$K3S_HOST:10250/metrics/cadvisor" | head -3

# ClusterIP services, through the API server proxy
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$K3S_HOST:6443/api/v1/namespaces/monitoring/services/kube-prometheus-stack-kube-state-metrics:8080/proxy/metrics" | head -3
```

Then put that token in your Prometheus `bearer_token` and, if you want real
discovery rather than static targets, use `kubernetes_sd_configs` — the
ClusterRole already allows it.

**b) Federate.** Point your Prometheus at the in-cluster one's `/federate` with a
curated `match[]` list. Less RBAC, and worth doing once to understand federation,
but it couples you to the lab's scrape config. Needs the in-cluster Prometheus
exposed — `prometheus.prod.lab`, see "Optional ingress" below.

**Done when:** at least one *cluster* metric — `container_cpu_usage_seconds_total`
or `kube_pod_status_phase` — is in your stack, collected from outside.

### Step 4 — Cluster logs, from outside

`/var/log/pods/` is readable from the host, so the agent from Step 2 can pick up
container logs with **nothing running in the cluster**. Try it.

Then look at what labels you actually have. The path encodes only
`<namespace>_<pod>_<uid>/<container>/N.log`. You can parse that, but you will not
get the workload name, the controller, the node's labels, or anything that changes
after the pod starts — for that you have to talk to the Kubernetes API.

**That wall is the point of this step.** It is exactly why in-cluster agents exist,
and why the deck's Phase 1 pattern is an *Agent Collector DaemonSet per node that
adds Kubernetes metadata*. Hitting it yourself is worth more than being told.

**Done when:** you can explain, in a paragraph, what host-only log collection
cannot give you — and that becomes the justification for the in-cluster pipeline.

---

## Decisions to make — and defend

No recommended answers here on purpose. Write down what you chose and why.

| Decision | Candidates | What to weigh |
|---|---|---|
| Metrics backend | Prometheus, VictoriaMetrics, Mimir | footprint for one node, retention, what the deck names |
| Log backend | Loki, Elastic, VictoriaLogs | deck names Loki, but also "Elastic where the client has it" |
| Log agent | OTel Collector, Grafana Alloy, Vector, Fluent Bit | see the note below |
| Where your stack runs | docker-compose on your laptop, a second VM, systemd | reachability to the k3s host, and what survives a reboot |
| Host-only vs in-cluster collection | host agent vs DaemonSet | Step 4 is designed to expose the limits of host-only |

> **Agent choice, with one caveat.** The deck's Phase 1 standard is the
> **OpenTelemetry Collector** — one pipeline, OTLP in, k8s metadata added at the
> agent. Loki 3.x accepts OTLP natively at `/otlp/v1/logs`, so an OTel Collector
> can ship to Loki with no intermediate exporter. Alloy is the quickest path and
> has `loki.source.journal` built in for Step 2. **Promtail is end-of-life** —
> Grafana has stopped supporting it; don't invest time there.
>
> The real checkpoint: *does your choice put you on or off the path to the
> Collector pipeline Phase 1 needs?* Diverging is allowed. Diverging by accident
> is not.

---

## Putting load on it

`scripts/load-test.sh` creates temporary, bounded load and cleans up after itself.

```bash
./scripts/load-test.sh --help
./scripts/load-test.sh --mode node --duration 180 --dry-run   # see the plan first
./scripts/load-test.sh --mode node --duration 180 --yes       # saturate the host
./scripts/load-test.sh --mode hpa  --duration 300 --yes       # drive the HPA
./scripts/load-test.sh --mode both --duration 240 --yes
```

- `--mode node` — saturates all 16 cores plus disk I/O. Watch the **Nodes**
  dashboard, and your own.
- `--mode hpa` — hammers the `php-apache` Service, whose HPA scales 1→10 at 50%
  CPU. Watch `kubectl get hpa -n default -w` and the pod count. Verified: a
  5-worker run drove it to `194%/50%` and 10/10 replicas in about a minute.
  **It will sit at 10 replicas for ~5 minutes after the load stops** — that is the
  HPA's scale-down stabilization window, not a stuck deployment.
- `--mode both` — run them together and see them interact.

### Driving memory up

`--mem GB` is opt-in and off by default. It is capped at **50% of the node's own
allocatable memory** — resolved from the node at runtime, not hardcoded, because
this script gets run against more than one machine. The run summary prints the
resolved cap, and asking for more clamps with a warning:

```bash
./scripts/load-test.sh --mode node --mem 8 --duration 180 --yes
#   memory stress   : 8G held (request 8Gi, limit 9Gi)
#   memory cap      : 15G  (50% of the node's 30G)
```

Verified on this lab: that run took the node from 18% to **44%** memory, with the
pod holding the full 8.2 GB.

> **Why `--vm-hang 0` is in there.** Plain `stress --vm` loops
> malloc/memset/free. Measured here, a requested 3 GB reached only ~0.9 GB of
> steady-state RSS *while burning a whole CPU core* — a noisy memory graph that
> also pollutes the CPU signal. With `--vm-hang 0` the worker allocates once and
> holds: a clean 3.0 GB plateau at ~0m CPU. If you want memory to *look* high,
> you want it held, not churned.

**Safety, because this node also runs the control plane:**

- CPU saturation is safe — things get slow, nothing dies.
- **Memory is the risky one**, so the stress container carries two independent
  protections:
  - a **memory request**, so the *scheduler* refuses an impossible ask — you get
    a Pending pod rather than a dead API server;
  - a **memory limit** 1 GiB above what it will hold, so the *cgroup* kills only
    that container on overshoot. Verified: a container told to hold 3 GB under a
    1 GiB limit came back `OOMKilled` / exit 137 while the API server stayed
    `readyz: ok`.
  
  Those two are what make a large `--mem` safe to ask for at all.
- Load stops three independent ways: `stress --timeout`, `activeDeadlineSeconds`
  on the Job, and a cleanup trap. The Job deadline is the one that matters — it
  survives the script being killed or your SSH session dropping. Ctrl-C is safe.

> **Expect gaps in your graphs during `--mode node`.** At full CPU saturation
> scrape intervals stretch and series develop holes. That is not a broken
> dashboard — it is what monitoring under saturation looks like, and it is one of
> the more useful things this exercise shows you. `kubectl top` lags too:
> metrics-server aggregates over ~15–60 s, so short runs under‑report. Trust
> `/proc/loadavg` on the node for ground truth.

---

## Optional: expose the in-cluster Prometheus

Only needed for the federation route in Step 3. Six lines on the existing
`kube-prometheus-stack` entry in `argocd-apps/base-apps/values.yaml`:

```yaml
    templatedValues:
      prometheus:
        ingress:
          enabled: true
          ingressClassName: traefik
          hosts: ['prometheus.{{ .Values.global.dnsName }}']
          tls:
            - secretName: prometheus-tls
              hosts: ['prometheus.{{ .Values.global.dnsName }}']
```

Then add `$K3S_HOST prometheus.prod.lab` to `/etc/hosts` (the literal IP —
`/etc/hosts` does not expand variables).

> This is **unauthenticated** — anyone who can reach the host can read every
> metric in the cluster. Fine behind `/etc/hosts` in a lab; never do it anywhere
> else without auth in front.

---

## Cleaning up

```bash
kubectl delete -f manifests/external-scraper.yaml   # remove the read-only identity
kubectl delete namespace loadtest                   # only if a run was interrupted
```

The load script deletes its own namespace on exit, so the second line is just a
safety net.

---

## Where this goes next

Once Steps 1–4 are done and you can articulate the Step 4 wall, the next milestone
is the deck's actual lab-track ask: the **in-cluster** pipeline — OTel Collector as
a DaemonSet, Loki, and Tempo — deployed through this lab's GitOps catalog rather
than by hand. `argocd-apps/README.md` §3 covers how to add a chart to the catalog,
and §7 covers the sync waves you would need (a collector is a wave-0 CRD/agent
layer; its config is a later wave).

Traces are deliberately not in this kit: they need an instrumented application,
which is its own exercise.
