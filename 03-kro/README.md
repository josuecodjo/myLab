```bash
kubectl apply -f 00-abstract

kubectl get rgd application -o wide

kubectl apply -f 01-apps/app.yml

kubectl get applications.kro.run
```