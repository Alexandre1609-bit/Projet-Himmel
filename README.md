# Projet Himmel

Projet Himmel is a bare metal Kubernetes platform designed to simulate real-world cloud infrastructure constraints without relying on managed services.

The goal is to deeply understand how modern cloud platforms operate under the hood by building, breaking, and securing a production-like environment from scratch.

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

```text
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

| Tool                 | Role                          | Why                                                                                                                                            |
| -------------------- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ansible**          | Node provisioning (Day-1)     | Idempotent configuration of OS, container runtime, and Kubernetes binaries across all nodes                                                    |
| **Terraform**        | Cluster configuration (Day-2) | Declarative management of CNI, GitOps tooling, and observability stack with full state tracking                                                |
| **Kubernetes v1.31** | Container orchestration       | Core platform version pinned for exam alignment (CKA/CKS)                                                                                      |
| **Cilium**           | CNI + kube-proxy replacement  | eBPF-based networking for kernel-level packet processing, L7 policies, and native observability via Hubble. No sidecars.                       |
| **ArgoCD**           | GitOps controller             | Git as a single source of truth. App of Apps pattern for declarative application management                                                    |
| **Prometheus**       | Metrics collection            | Scraping application metrics and managing alerts                                                                                               |
| **Grafana**          | Metrics visualization         | Dynamic dashboards and providing visual analytics for cluster observability                                                                    |
| **Falco**            | Runtime security              | Kernel-level intrusion detection and real-time monitoring of system calls                                                                      |
| **Kyverno**          | Policy enforcement            | Kubernetes-native admission controller for security compliance and custom policy enforcement                                                   |
| **HashiCorp Vault**  | Secrets management            | Currently using Bitnami Sealed Secrets for encrypted GitOps workflows. A migration to HashiCorp Vault is planned for advanced dynamic secrets. |

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

```text
homelab-k8s/
├── ansible/                    # Node provisioning (Day-1)
│   ├── group_vars/
│   ├── inventory/
│   ├── playbooks/
│   └── roles/
│       ├── containerd/         # Container runtime configuration
│       │   ├── handlers/
│       │   ├── tasks/
│       │   └── templates/
│       ├── kubernetes/         # kubeadm, kubelet, kubectl installation and cluster init
│       │   ├── defaults/
│       │   ├── tasks/
│       │   └── templates/
│       └── os-hardening/       # System updates, swap, UFW, base packages
│           └── tasks/
├── docs/                       # Architecture decisions and progress logs
│   └── images/
│       ├── hardware/
│       └── system/
├── k8s/                        # GitOps manifests (watched by ArgoCD)
│   ├── apps/                   # App of Apps: ArgoCD Application definitions
│   │   ├── helm-values/
│   │   └── secrets/
│   └── manifests/              # Per-application Kubernetes manifests
│       ├── cilium/
│       ├── falco/
│       ├── grafana/
│       ├── kyverno/
│       └── prometheus/
├── local-secrets/              # Local keys and temporary secrets
└── terraform/                  # Cluster configuration (Day-2)
    └── modules/
        ├── argocd/             # GitOps controller deployment via Helm
        └── cilium/             # CNI deployment via Helm
```

## Roadmap

| Phase                | Status     | Description                                                    |
| -------------------- | ---------- | -------------------------------------------------------------- |
| Hardware setup       | ✅ Done    | 3x Lenovo M720q received and configured                        |
| Ansible provisioning | ✅ Done    | OS hardening, containerd, Kubernetes                           |
| Terraform init       | ✅ Done    | Cilium CNI + ArgoCD deployed                                   |
| Physical deployment  | ✅ Done    | Cluster running, all nodes Ready                               |
| GitOps — ArgoCD      | ✅ Done    | App of Apps pattern                                            |
| Observability        | ✅ Done    | Prometheus + Grafana + Loki                                    |
| CI security pipeline | ✅ Done    | Trivy (IaC misconfig + CVEs), Gitleaks, Semgrep SAST, yamllint |
| Runtime security     | ⏳ WIP     | Falco + Kyverno + Network Policies                             |
| Secrets management   | ⏳ Planned | HashiCorp Vault                                                |

## DevLogs

Detailed progress logs documenting technical decisions, bugs encountered, and concepts learned.

| Log                                                                               | Description                                                                                        |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| [01 — Hardware Prep](docs/01-hardware-prep.md)                                    | Hardware selection, BIOS configuration, OS choice                                                  |
| [02 — Network Plan](docs/02-network-plan.md)                                      | Network architecture and IP addressing                                                             |
| [03 — Phase 1](docs/03-devlog-phase1.md)                                          | Ansible role structure and OS hardening                                                            |
| [04 — Phase 2](docs/04-devlog-phase2.md)                                          | Containerd, Kubernetes roles, Terraform init                                                       |
| [05 — Ansible Review](docs/05-devlog-phase3.md)                                   | Deep code review, corrections, and architectural decisions                                         |
| [06 — Terraform & Cilium](docs/06-devlog-phase4.md)                               | Terraform module structure, Cilium deployment                                                      |
| [07 — Cluster Bootstrap](docs/07-cluster-bootstrap.md)                            | Physical deployment, bugs encountered, and resolved                                                |
| [08 — ArgoCD Deployment](docs/08-argocd-deployment.md)                            | ArgoCD deployment, architectural decisions, and corrections                                        |
| [09 — Observability Stack Step 1](docs/09-observability-stack-deployment.md)      | Observability stack deployment, layer 1 failure, and master overloaded                             |
| [10 — Observability Stack Step 2](docs/10-observability-stack-deployment-2.md)    | Prometheus connection, first Grafana dashboard deployment, and key steps                           |
| [11 — Observability Stack Step 3](docs/11-Dashboards-import-and-dashboard-fix.md) | Dashboard JSON fix, sidecar, and ConfigMap deployment                                              |
| [12 — Observability Stack Step 4](docs/12-Final-dashboards-fix.md)                | Last dashboard fixes, PromQL query issues, and finalization of observability stack deployment      |
| [13 — Security Implementation Step 1](docs/13-Security-implementation-01.md)      | Alertmanager and Slack deployment, introduction of Bitnami Sealed Secrets, and first Kyverno rules |
| [14 — Security Implementation Step 2](docs/14-Security-implementation-02.md)      | Multiple issues with Kyverno rules, debugging, and learning                                        |

And more in the /docs folder !

---

_Built with patience. Documented with intent._
