# Ansible: rolling Kubernetes node upgrade

`playbooks/k8s-rolling-node-upgrade.yml` upgrades kubeadm-managed worker nodes one at a time: cordon, drain
(respecting PodDisruptionBudgets), upgrade kubeadm, kubelet and kubectl, restart, wait for Ready, confirm the
version, uncordon. A failure stops the run and leaves the node cordoned.

It is a reference pattern for the on-premises Kubernetes in this repository (`on-prem/`), written for
Debian-family nodes and the pkgs.k8s.io package repository. Hostnames in the example inventory are
placeholders. It has been checked with `ansible-playbook --syntax-check` and `ansible-lint` in CI; it has
not been run against a real cluster from this repository, so rehearse it in a non-production cluster first.

```bash
cd ansible
ansible-playbook playbooks/k8s-rolling-node-upgrade.yml -e target_version=1.31.4 --check   # dry run
ansible-playbook playbooks/k8s-rolling-node-upgrade.yml -e target_version=1.31.4           # upgrade
```

Order of operations for a full upgrade: etcd snapshot, control plane (`kubeadm upgrade apply`, one node at a
time), then this playbook for the workers, then validate networking and workloads before the next minor version.
Kubernetes supports one minor version at a time.
