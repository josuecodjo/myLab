# Apply Security


## Kyverno

### Apply configurations

```sh
kubectl apply -f kyverno/policies/disallow-latest-tag.yaml
```

### Test Scenarios

```sh
kubectl apply -f kyverno/test-pods/good-pod.yaml  # should succeed
kubectl apply -f kyverno/test-pods/bad-pod.yaml   # should FAIL (missing team label)
kubectl run latest-pod --image=nginx:latest       # should FAIL (no latest tag allowed)

kubectl run pinned-pod --image=nginx:1.25    # should FAIL (needs label team)

kubectl get pod test-pod -o jsonpath='{.metadata.labels}'

kubectl port-forward svc/policy-reporter-ui 8001:8080 -n policy-reporter

```
open browser at localhost:8001

https://kyverno.home.lab/#/

## Falco

### Test Scenarios

```sh
kubectl port-forward svc/falco-falcosidekick-ui 8000:2802 -n falco
```
open webbrowser at localhost:8000 connect with admin/admin

check the event tabs and do

```sh
kubectl exec -it good-pod -- cat /etc/shadow

or

kubectl exec -it $(kubectl get pods --selector=team=devops -o name) -- cat /etc/shadow

```