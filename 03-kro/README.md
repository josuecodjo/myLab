```bash
kubectl apply -f 00-abstract

kubectl get rgd application -o wide

kubectl apply -f 01-apps

kubectl get applications.kro.run
```