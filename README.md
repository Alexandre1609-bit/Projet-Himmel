# Projet Himmel

> Projet Himmel is a bare metal Kubernetes platform designed to simulate real-world cloud infrastructure constraints without relying on managed services.

> The goal is to deeply understand how modern cloud platforms operate under the hood by building, breaking, and securing a production-like environment from scratch.

## Overview

Projet Himmel is a bare metal Kubernetes homelab running on three physical nodes. It is built as a long-term learning platform targeting enterprise DevSecOps and cloud security standards, with a focus on understanding every component from the ground up rather than relying on managed abstractions.

The project serves a dual purpose: a technical playground for breaking and fixing infrastructure, and a portfolio demonstrating real-world engineering decisions. Everything is versioned, documented, and justified.

**Target certifications:** CKA · CKS · Terraform Associate · CCNA

## Hardware & Network Architecture

| Component       | Model                    | Role                                 |
| --------------- | ------------------------ | ------------------------------------ |
| Node 1 (master) | Lenovo ThinkCentre M720q | Kubernetes control plane             |
| Node 2 (worker) | Lenovo ThinkCentre M720q | Workload node                        |
| Node 3 (worker) | Lenovo ThinkCentre M720q | Workload node                        |
| Switch          | TP-Link TL-SG108E        | Layer 2 managed switch (VLAN 802.1Q) |
| Uplink          | TP-Link RE605X           | WiFi 6 bridge to home network        |

```
Internet
    │
[TP-Link RE605X] ── WiFi 6 bridge
    │
[TP-Link TL-SG108E] ── Layer 2 managed switch
    ├── node01 (master)  192.168.1.50
    ├── node02 (worker)  192.168.1.51
    └── node03 (worker)  192.168.1.52
```

**OS:** Ubuntu Server 24.04 LTS — minimal install, no Snap packages, official Kubernetes binaries only.

## Tech Stack

| Tool                 | Role                          | Why                                                                                                                      |
| -------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| **Ansible**          | Node provisioning (Day-1)     | Idempotent configuration of OS, container runtime, and Kubernetes binaries across all nodes                              |
| **Terraform**        | Cluster configuration (Day-2) | Declarative management of CNI, GitOps tooling, and observability stack with full state tracking                          |
| **Kubernetes v1.31** | Container orchestration       | Core platform — version pinned for exam alignment (CKA/CKS)                                                              |
| **Cilium**           | CNI + kube-proxy replacement  | eBPF-based networking for kernel-level packet processing, L7 policies, and native observability via Hubble. No sidecars. |
| **ArgoCD**           | GitOps controller             | Git as single source of truth — App of Apps pattern for declarative application management                               |
| **Prometheus**       | Metrics collection            | _(planned)_                                                                                                              |
| **Grafana**          | Metrics visualization         | _(planned)_                                                                                                              |
| **Falco**            | Runtime security              | _(planned)_ — kernel-level intrusion detection                                                                           |
| **Kyverno**          | Policy enforcement            | _(planned)_ — admission controller for security policies                                                                 |
| **HashiCorp Vault**  | Secrets management            | _(planned)_                                                                                                              |

## Prerequisites

The following tools must be installed on the management machine before deploying:

```bash
ansible --version    # >= 2.15
terraform --version  # >= 1.14
kubectl version      # aligned with cluster version (v1.31)
helm version         # >= 3.x
```

Required Ansible collections:

```bash
ansible-galaxy collection install ansible.posix community.general
```

## Deployment

Operations must be performed in strict order.

**Step 1 — Register node SSH keys**

```bash
ssh-keyscan 192.168.1.50 192.168.1.51 192.168.1.52 >> ~/.ssh/known_hosts
ssh-copy-id alexandre@192.168.1.50
ssh-copy-id alexandre@192.168.1.51
ssh-copy-id alexandre@192.168.1.52
```

**Step 2 — Provision nodes with Ansible**

```bash
cd ansible
ansible-playbook site.yml --ask-become-pass
```

**Step 3 — Retrieve kubeconfig**

```bash
mkdir -p ~/.kube
scp alexandre@192.168.1.50:~/.kube/config ~/.kube/config
```

**Step 4 — Deploy cluster configuration with Terraform**

```bash
cd terraform
terraform init
terraform apply
```

This deploys Cilium as the CNI and ArgoCD as the GitOps controller.

## Repository Structure

```
homelab-k8s/
├── ansible/                    # Node provisioning (Day-1)
│   ├── roles/
│   │   ├── os-hardening/       # System updates, swap, UFW, base packages
│   │   ├── containerd/         # Container runtime configuration
│   │   └── kubernetes/         # kubeadm, kubelet, kubectl installation and cluster init
│   ├── inventory/
│   ├── group_vars/
│   └── site.yml                # Main entrypoint
│
├── terraform/                  # Cluster configuration (Day-2)
│   ├── modules/
│   │   ├── cilium/             # CNI deployment via Helm
│   │   └── argocd/             # GitOps controller deployment via Helm
│   ├── main.tf
│   ├── variables.tf
│   └── versions.tf
│
├── k8s/                        # GitOps manifests (watched by ArgoCD)
│   ├── apps/                   # App of Apps — ArgoCD Application definitions
│   └── manifests/              # Per-application Kubernetes manifests
│       ├── prometheus/
│       ├── grafana/
│       └── falco/
│
└── docs/                       # Architecture decisions and progress logs
    └── images/
```

## Roadmap

| Phase                | Status         | Description                             |
| -------------------- | -------------- | --------------------------------------- |
| Hardware setup       | ✅ Done        | 3x Lenovo M720q received and configured |
| Ansible provisioning | ✅ Done        | OS hardening, containerd, Kubernetes    |
| Terraform init       | ✅ Done        | Cilium CNI + ArgoCD deployed            |
| Physical deployment  | ✅ Done        | Cluster running, all nodes Ready        |
| GitOps — ArgoCD      | 🔄 In progress | App of Apps pattern                     |
| Observability        | ⏳ Planned     | Prometheus + Grafana + Loki             |
| Runtime security     | ⏳ Planned     | Falco + Kyverno + Network Policies      |
| Secrets management   | ⏳ Planned     | HashiCorp Vault                         |

## Dev Logs

Detailed progress logs documenting technical decisions, bugs encountered, and concepts learned.

| Log                                                    | Description                                               |
| ------------------------------------------------------ | --------------------------------------------------------- |
| [01 — Hardware Prep](docs/01-hardware-prep.md)         | Hardware selection, BIOS configuration, OS choice         |
| [02 — Network Plan](docs/02-network-plan.md)           | Network architecture and IP addressing                    |
| [03 — Phase 1](docs/03-devlog-phase1.md)               | Ansible role structure and OS hardening                   |
| [04 — Phase 2](docs/04-devlog-phase2.md)               | Containerd, Kubernetes roles, Terraform init              |
| [05 — Ansible Review](docs/05-devlog-phase3.md)        | Deep code review, corrections and architectural decisions |
| [06 — Terraform & Cilium](docs/06-devlog-phase4.md)    | Terraform module structure, Cilium deployment             |
| [07 — Cluster Bootstrap](docs/07-cluster-bootstrap.md) | Physical deployment, bugs encountered and resolved        |

---

_Built with patience. Documented with intent._
