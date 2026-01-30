# Kubernetes with MicroK8s

[MicroK8s](https://canonical.com/microk8s) is a lightweight Kubernetes distribution focused on simplicity and low resource consumption. It is an open source system for automating the deployment, scaling, and management of containerized applications. MicroK8s provides the essential features of Kubernetes in a compact installation, and can be used on a single node or in high-availability clusters for production.

This guide is based on examples from [Getting started](https://canonical.com/microk8s/docs/getting-started) and other topics from the official [MicroK8s documentation](https://canonical.com/microk8s/docs).

## Install microk8s

MicroK8s installs a minimal, lightweight version of Kubernetes that you can run on almost any machine. It can be installed via snap:

```
sudo snap install microk8s --classic --channel=1.35
```

To check available channels, use `snap info microk8s`.
For more information about choosing the `--channel`, see https://canonical.com/microk8s/docs/setting-snap-channel.

## Join the microk8s group

MicroK8s creates a group to allow the use of commands that require admin privileges. To add your current user to the group and get access to the `.kube` cache directory, run the following three commands:

```
sudo usermod -a -G microk8s $USER
mkdir -p ~/.kube
chmod 0700 ~/.kube
```

**Restart your computer** to ensure any new terminal and MicroK8s instance loads the updated permissions.

## Check status

MicroK8s has a built-in command to display its status. During installation, you can use the `--wait-ready` flag to wait for Kubernetes services to initialize:

```
microk8s status --wait-ready
```

## Installing add-ons

MicroK8s uses the minimum components to keep Kubernetes lightweight. However, many extra features are available via "add-ons" — packaged components that provide additional capabilities to your Kubernetes.

To start, it is recommended to enable DNS management to facilitate service communication. For applications that need storage, the `hostpath-storage` add-on provides space in a directory on the host. `helm3` is required for kustomize to work with helm, which is used by the tools in the **tools** folder of this repository. These features are easy to configure:

```
microk8s enable dns hostpath-storage helm3
```

For **clusters with more than one node**, it is recommended to use [rook-ceph](https://canonical.com/microk8s/docs/how-to-ceph) for more advanced storage.

### Load Balancer

If needed, you can use the [MetalLB LoadBalancer](https://canonical.com/microk8s/docs/addon-metallb).

MetalLB is a network load balancer implementation that aims to "just work" on bare-metal clusters.

When enabling this add-on, you will be prompted to provide an IP address pool that MetalLB will distribute:

```
microk8s enable metallb
```
