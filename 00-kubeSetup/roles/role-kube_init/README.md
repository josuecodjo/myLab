Role kube_init
=========

- Deploy kuberentes
- Deploy certmanager
- Deploy awx
- Deploy argocd

Requirements
------------

An Ubuntu machine

Role Variables
--------------

```
# defaults vars

v_k3s_version: v1.31.4+k3s1
v_awx_chart_version: 2.19.1
v_certmanager_chart_version: 1.14.5
v_awx_install_path: /opt/k8s
v_global_install_path: /opt/kubeinit
v_argocd_chart_version: 8.0.17

# Global configs
global_dns_name: home.lab

# Acme mode
acme_mode: Local # AWS, Azure

# Azure_config
subscriptionid: ""
esourcegroupname: ""
hostedzonename: ""
tenantid: ""
clientid: ""
client_secret: ""

# AWX Config
awx_hostname: awx
admin_password: mySuperPass
postgres_storage: 8Gi
web_replicas: 1
task_replicas: 1
postgres_password: awxpostgrespass
awx_projects_storage: 2Gi

# ArgoCD
argocd_hostname: argocd
```

Dependencies
------------

- collection kubernetes.core


Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - hosts: servers
      roles:
         - role-kube_init

License
-------

BSD

Author Information
------------------

Josue Codjo
