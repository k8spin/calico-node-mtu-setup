# Calico Node. MTU Setup at GKE

This repository contains a quick and dirty fix to those GKE clusters having
[GKE Sandbox](https://cloud.google.com/kubernetes-engine/sandbox/) and
[Network Policies](https://cloud.google.com/kubernetes-engine/docs/how-to/network-policy)
addons enabled.

## TL;DR

```bash
$ kubectl create cm calico-node-mtu-setup --from-file=mtu.sh=mtu.sh -n kube-system
$ kubectl apply -f rbac.yaml
$ kubectl apply -f daemonset.yaml
```

## Background

During a GKE cluster upgrade: from kubernetes 1.13.10 -> 1.14.x -> 1.15.4 we faced a connectivity
problem only on GKE Sandbox enabled node pool.

The problem was while uploading an image to the telegram API from a pod running on a gVisor sandbox.
The same pod/container/image doing the same operation in a different node in the cluster
*(without gVisor sandboxing)* worked as expected.

We opened an issue to the [gVisor github repository](https://github.com/google/gvisor/issues/1515)
and after a couple of days debuging, [Bhasker Hariharan @hbhasker](https://github.com/hbhasker) found
the issue, MTU wrong configuration when GKE Sandbox and Network Policy addons are enable.

## First approach

As Network Policy addon (aka managed calico) has problems and we can not wait for a GKE fix,
we found an alternative CNI to deploy on top of GKE. As GKE is a managed service, there are
not a lot of alternatives:

- Cilium: [Looks promising in its documentation](https://docs.cilium.io/en/v1.6/gettingstarted/k8s-install-gke/):
  But, we encountered more problems. Seems like the 
  [COS GKE node image does not have enabled required kernel modules](https://github.com/cilium/cilium/issues/9556)

### Solution

As [Fabricio Voznika @fvoznika](https://github.com/fvoznika) mention:

> Since you may not be able to move away from Calico, you can change CNI configuration in 
  /etc/cni/net.d/10-calico.conflist to add "mtu": 1460. The caveat is that the configuration
  is overwritten every time the node is restarted, and any pod created will use MTU 1500 
  until the configuration is changed again.

### Hands on

**ALERT**: The solution is quick and dirty, but works. Any improvement is always welcomed in form of PR.

The solution is to implement some kind of mechanism that updates a configuration file on every host on every reboot.

But... Why not to just modify the `calico-node` daemonset adding the MTU configuration?
Because it's somekind of inmutable deployment. Every yaml change is reverted by GKE.

A new daemonset is created to setup this configuration. The `calico-node-mtu-setup` daemonset uses [a
`kubectl` image with `jq` installed](https://gitlab.com/k8spin-open/container-images/kubectl/blob/master/Dockerfile).

A [quick and dirty script](./mtu.sh) is mounted into the pod to add the missing MTU configuration.

The script is in charge of:

- Look for MTU configuration inside the calico configuration file.
- If MTU configuration is not present:
    - The script set the MTU to the correct size
    - Restarts *(`kubectl delete pod`)* every pod running in the node but those startig with `calico-node-`

## Running

Deploy it:

```bash
$ kubectl create cm calico-node-mtu-setup --from-file=mtu.sh=mtu.sh -n kube-system
$ kubectl apply -f rbac.yaml
$ kubectl apply -f daemonset.yaml
```

Check:

```
$ kubectl get pods -l k8s-app=calico-node-mtu-setup -n kube-system
NAME                          READY   STATUS    RESTARTS   AGE
calico-node-mtu-setup-4m8nf   1/1     Running   0          31m
calico-node-mtu-setup-6wz7g   1/1     Running   0          31m
calico-node-mtu-setup-8wdnn   1/1     Running   0          31m
calico-node-mtu-setup-kk9gp   1/1     Running   0          25m
calico-node-mtu-setup-ltjnz   1/1     Running   0          31m
calico-node-mtu-setup-vfdv4   1/1     Running   0          31m
```

Logs should looks like:

```bash
kubectl logs -f calico-node-mtu-setup-4m8nf
Sun Jan 12 17:03:50 UTC 2020 MTU Configuration not found
Sun Jan 12 17:03:50 UTC 2020 Applying MTU Configuration
Sun Jan 12 17:03:50 UTC 2020 Restarting node Pods
pod "probe-b8855955f-lsztx" deleted
pod "echo-7b5b58ffdb-hc7vg" deleted
Sun Jan 12 17:04:58 UTC 2020 Calico Pod must not be restarted
Sun Jan 12 17:04:58 UTC 2020 Calico Pod must not be restarted
pod "ip-masq-agent-9mxzn" deleted
pod "kube-proxy-gke-dev-clients-fallbac-ab79423e-d83l" deleted
Sun Jan 12 17:05:06 UTC 2020 Restarted
```

## Test Network Policies

Based on the 
[connectivity check provided by cilium repository](https://raw.githubusercontent.com/cilium/cilium/v1.6/examples/kubernetes/connectivity-check/connectivity-check.yaml), 
a modified version can be found inside the [`connectivity-check`](./connectivity-check) directory.

It deploys:

- Probes inside the default namespace:
  - `probe` to `echo` service
  - `probe-gvisor` to `probe-gvisor` service.
- Echo services inside a new `isolated` namespace:
  - `echo` service
  - `echo-gvisor` service
  - default deny-all network policy.

```
$ kubectl get pods -n isolated
NAME                           READY   STATUS    RESTARTS   AGE
echo-7b5b58ffdb-ckt49          1/1     Running   0          35m
echo-7b5b58ffdb-cxjwf          1/1     Running   0          35m
echo-7b5b58ffdb-dff6x          1/1     Running   0          35m
echo-7b5b58ffdb-z9jsg          1/1     Running   0          35m
echo-gvisor-8695f776d5-8z4p8   1/1     Running   0          36m
echo-gvisor-8695f776d5-ql5qr   1/1     Running   0          29m
```

All echo services are running.

```bash
$ kubectl get pods -n default
NAME                            READY   STATUS    RESTARTS   AGE
probe-b8855955f-599vm           0/1     Running   0          36m
probe-b8855955f-9nf76           0/1     Running   0          36m
probe-b8855955f-h8drr           0/1     Running   0          36m
probe-b8855955f-jft6m           0/1     Running   0          36m
probe-gvisor-78ff45b9f8-92fdl   0/1     Running   0          36m
probe-gvisor-78ff45b9f8-wk72w   0/1     Running   0          29m
```

Probe pods are running but not healthy. It demonstrates network policies are working properly.

## Test MTU

Enter on any `echo-gvisor` pod:

```bash
$ kubectl exec -it echo-gvisor-8695f776d5-8z4p8 /bin/bash -n isolated
root@echo-gvisor-8695f776d5-8z4p8:/# dmesg
[    0.000000] Starting gVisor...
[    0.317280] Daemonizing children...
[    0.320144] Creating bureaucratic processes...
[    0.538464] Reticulating splines...
[    0.578611] Committing treasure map to memory...
[    0.601664] Searching for socket adapter...
[    0.844805] Consulting tar man page...
[    1.004640] Creating process schedule...
[    1.082413] Gathering forks...
[    1.546173] Generating random numbers by fair dice roll...
[    1.737052] Letting the watchdogs out...
[    2.233946] Ready!
root@echo-gvisor-8695f776d5-8z4p8:/# apt-get update && apt-get install -y net-tools
root@echo-gvisor-8695f776d5-8z4p8:/# ifconfig  | grep mtu
eth0: flags=65<UP,RUNNING>  mtu 1460
lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536
root@echo-gvisor-8695f776d5-8z4p8:/# curl https://www.google.com/images/branding/googlelogo/2x/googlelogo_color_92x30dp.png --output googlelogo_color_92x30dp.png
root@echo-gvisor-8695f776d5-8z4p8:/# curl -X POST "https://api.telegram.org/bot990060833:I_CAN_SEND_YOU_THE_TOKEN/sendPhoto" -F chat_id=334621642 -F photo="@googlelogo_color_92x30dp.png" 
{"ok":false,"error_code":401,"description":"Unauthorized"}
```

After the `calico-node-mtu-setup` daemonset fix the last curl command failed
with `curl: (56) OpenSSL SSL_read: SSL_ERROR_SYSCALL, errno 104`
