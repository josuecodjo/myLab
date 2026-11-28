#!/usr/bin/env bash
#
# load-test.sh - put temporary, bounded load on the lab, then stop.
#
# Two modes:
#   node  stress the HOST: saturate CPU and drive disk I/O. Shows up on the
#         "Nodes" / "Node Exporter" dashboards and in whatever log pipeline you
#         have collecting from the host.
#   hpa   stress the CLUSTER: hammer the php-apache Service so its HPA
#         (cpu 50%, 1->10 replicas) scales out. Shows pod churn and the
#         autoscaling loop.
#   both  run them together, to watch them interact.
#
# SAFETY - this is a SINGLE-NODE cluster that also runs its own control plane.
#   * CPU saturation is safe: things get slow, nothing dies.
#   * MEMORY saturation is NOT. Exhausting RAM OOM-kills the control plane and
#     takes the API server with it. --mem is therefore opt-in and hard-capped.
#   * Load is stopped three independent ways, so a script that dies, a lost SSH
#     session, or a Ctrl-C can never leave load running:
#       1. `stress --timeout`                 (the process stops itself)
#       2. `activeDeadlineSeconds` on the Job (the cluster stops it)
#       3. an EXIT/INT/TERM trap              (cleans up the namespace)
#     (2) is the one that matters: it survives this script being killed.
#
# Usage:
#   ./load-test.sh --mode node --duration 180 --cpu 16
#   ./load-test.sh --mode hpa  --duration 300 --workers 5
#   ./load-test.sh --mode both --duration 240 --yes
#
set -euo pipefail

MODE=node
DURATION=120
CPU=0                 # 0 = autodetect all allocatable cores
IO=4
MEM_GB=0              # 0 = memory stress OFF (see SAFETY above)
WORKERS=5
NS=loadtest
ASSUME_YES=0
DRY_RUN=0

MEM_CAP_GB=4          # hard ceiling for --mem, regardless of what is asked
MAX_DURATION=1800     # hard ceiling for --duration

# php-apache: the HPA target that already exists in this lab
TARGET_SVC=${TARGET_SVC:-php-apache.default.svc.cluster.local}
TARGET_PORT=${TARGET_PORT:-80}

STRESS_IMAGE=${STRESS_IMAGE:-polinux/stress:latest}
BUSYBOX_IMAGE=${BUSYBOX_IMAGE:-busybox:1.37}

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --mode node|hpa|both   what to stress                  (default: $MODE)
  --duration SECONDS     how long to run, max $MAX_DURATION    (default: $DURATION)
  --cpu N                CPU workers, 0 = all cores       (default: autodetect)
  --io N                 I/O workers                      (default: $IO)
  --mem GB               memory stress, 0 = off, max $MEM_CAP_GB   (default: off)
  --workers N            concurrent HTTP loops in hpa mode (default: $WORKERS)
  --namespace NAME       namespace to create and delete   (default: $NS)
  --dry-run              print what would be created, change nothing
  --yes                  skip the confirmation prompt
  -h, --help             this text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)      MODE="${2:?}"; shift 2 ;;
    --duration)  DURATION="${2:?}"; shift 2 ;;
    --cpu)       CPU="${2:?}"; shift 2 ;;
    --io)        IO="${2:?}"; shift 2 ;;
    --mem)       MEM_GB="${2:?}"; shift 2 ;;
    --workers)   WORKERS="${2:?}"; shift 2 ;;
    --namespace) NS="${2:?}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1 (try --help)" ;;
  esac
done

[[ "$MODE" =~ ^(node|hpa|both)$ ]] || die "--mode must be node, hpa or both"
[[ "$DURATION" =~ ^[0-9]+$ ]]      || die "--duration must be an integer"
[[ "$MEM_GB"   =~ ^[0-9]+$ ]]      || die "--mem must be an integer (GB)"
[[ "$CPU"      =~ ^[0-9]+$ ]]      || die "--cpu must be an integer"
(( DURATION > 0 )) || die "--duration must be > 0"

if (( DURATION > MAX_DURATION )); then
  warn "--duration $DURATION exceeds the $MAX_DURATION s ceiling; clamping"
  DURATION=$MAX_DURATION
fi
if (( MEM_GB > MEM_CAP_GB )); then
  warn "--mem ${MEM_GB}G exceeds the ${MEM_CAP_GB}G safety cap; clamping (see SAFETY in this script)"
  MEM_GB=$MEM_CAP_GB
fi

command -v kubectl >/dev/null || die "kubectl not found"
kubectl cluster-info >/dev/null 2>&1 || die "cannot reach the cluster - check KUBECONFIG"

# Autodetect cores from the node itself, so --cpu 0 saturates whatever it finds.
if (( CPU == 0 )); then
  CPU=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || echo 2)
  CPU=${CPU%%m*}                       # "16" or "15800m" -> strip milli-suffix
  [[ "$CPU" =~ ^[0-9]+$ ]] || CPU=2
  (( CPU > 0 )) || CPU=2
fi

# activeDeadlineSeconds: the backstop. Slightly longer than the stress timeout
# so a healthy run ends by itself and this only fires if something hangs.
DEADLINE=$(( DURATION + 60 ))

STRESS_ARGS="--cpu ${CPU} --io ${IO} --timeout ${DURATION}s"
STRESS_ARGS_YAML="\"--cpu\", \"${CPU}\", \"--io\", \"${IO}\", \"--timeout\", \"${DURATION}s\""
if (( MEM_GB > 0 )); then
  STRESS_ARGS="${STRESS_ARGS} --vm 1 --vm-bytes ${MEM_GB}G"
  STRESS_ARGS_YAML="${STRESS_ARGS_YAML}, \"--vm\", \"1\", \"--vm-bytes\", \"${MEM_GB}G\""
fi

cat <<EOF

  mode            : $MODE
  duration        : ${DURATION}s   (job deadline ${DEADLINE}s)
  namespace       : $NS            (created now, deleted on exit)
EOF
if [[ "$MODE" == node || "$MODE" == both ]]; then
  cat <<EOF
  node stress     : stress $STRESS_ARGS
  memory stress   : $( (( MEM_GB > 0 )) && echo "${MEM_GB}G  <-- opt-in" || echo "off (recommended)" )
EOF
fi
if [[ "$MODE" == hpa || "$MODE" == both ]]; then
  cat <<EOF
  hpa target      : http://${TARGET_SVC}:${TARGET_PORT}
  hpa load        : $WORKERS concurrent request loops
EOF
fi
echo

if (( DRY_RUN )); then
  info "dry run - nothing was created"
  exit 0
fi

if (( ! ASSUME_YES )); then
  read -r -p "This will load the cluster for ${DURATION}s. Continue? [y/N] " ans
  [[ "$ans" == [yY] ]] || { info "aborted"; exit 0; }
fi

cleanup() {
  local rc=$?
  echo
  info "cleaning up namespace $NS"
  kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
  exit $rc
}
trap cleanup EXIT INT TERM

info "creating namespace $NS"
kubectl create namespace "$NS" >/dev/null 2>&1 || true

if [[ "$MODE" == node || "$MODE" == both ]]; then
  info "starting host stress: ${CPU} CPU workers, ${IO} I/O workers"
  kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: node-stress
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${DEADLINE}
  template:
    metadata:
      labels:
        app: node-stress
    spec:
      restartPolicy: Never
      containers:
        - name: stress
          image: ${STRESS_IMAGE}
          # `command` is required, not optional. This image has no ENTRYPOINT and
          # only Cmd: ["/usr/local/bin/stress"]. In Kubernetes `args` overrides
          # Cmd, so passing args alone replaces the binary itself and the kubelet
          # tries to exec "--cpu" -> StartError, with empty logs. This is why the
          # upstream Kubernetes docs also set command: ["stress"].
          command: ["/usr/local/bin/stress"]
          args: [${STRESS_ARGS_YAML}]
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
EOF
fi

if [[ "$MODE" == hpa || "$MODE" == both ]]; then
  info "starting HPA load: $WORKERS loops against $TARGET_SVC"
  kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: hpa-load
spec:
  backoffLimit: 0
  completions: ${WORKERS}
  parallelism: ${WORKERS}
  activeDeadlineSeconds: ${DEADLINE}
  template:
    metadata:
      labels:
        app: hpa-load
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: ${BUSYBOX_IMAGE}
          command: ["/bin/sh", "-c"]
          args:
            - |
              end=\$(( \$(date +%s) + ${DURATION} ))
              while [ \$(date +%s) -lt \$end ]; do
                wget -q -O /dev/null http://${TARGET_SVC}:${TARGET_PORT}/ || true
              done
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
EOF
fi

cat <<EOF

  Watch it land:
    kubectl top node
    kubectl get pods -n $NS -w
EOF
if [[ "$MODE" == hpa || "$MODE" == both ]]; then
  echo "    kubectl get hpa -n default -w        # php-apache-hpa should scale up"
fi
cat <<EOF
    Grafana -> "Nodes" dashboard          (host CPU, load, I/O)
    Grafana -> "Kubernetes / Compute Resources / Node"
    your own stack                        (this is the point of the exercise)

EOF

info "running for ${DURATION}s - Ctrl-C is safe, the Job deadline stops it regardless"
SLEPT=0
while (( SLEPT < DURATION )); do
  STEP=10
  (( SLEPT + STEP > DURATION )) && STEP=$(( DURATION - SLEPT ))
  sleep "$STEP"
  SLEPT=$(( SLEPT + STEP ))
  printf '    %3ds / %ds   node cpu: %s\n' "$SLEPT" "$DURATION" \
    "$(kubectl top node --no-headers 2>/dev/null | awk '{print $2" ("$3")"}' | head -1)"
done

info "load finished"
