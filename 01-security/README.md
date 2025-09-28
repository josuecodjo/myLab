# Apply Security


## Kyverno

### Apply configurations

```sh
kubectl apply -f kyverno/policies/
```

### Test Scenarios

```sh
kubectl apply -f kyverno/test-pods/good-pod.yaml  # should succeed
kubectl apply -f kyverno/test-pods/bad-pod.yaml   # should FAIL (missing team label)
kubectl run latest-pod --image=nginx:latest       # should FAIL (disallowed tag)

kubectl run latest-pod --image=nginx:latest  # should FAIL
kubectl run pinned-pod --image=nginx:1.25    # should PASS
kubectl apply -f policies/mutate-namespace-default.yaml
kubectl run test-pod --image=nginx
kubectl get pod test-pod -o jsonpath='{.metadata.labels}'

```

## Falco

### Test Scenarios

```sh
kubectl exec -it good-pod -- sh
# inside container:
echo "hacked" > /etc/passwd

```