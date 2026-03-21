# Journal d'Avancement - Phase 3 : Configuration & Infrastructure as Code : corrections techniques et décisions architecturales

Le code Ansible a été conçu il y a plusieurs mois, sans une réelle volonté de compréhension des concepts. Le code s'est donc retrouvé négligé, sans véritable logique de fond, laissant apparaître certaines incohérences techniques et des problèmes d'architecture pouvant empêcher le code de produire le résultat voulu.

## 1. Corrections techniques : Revue en profondeur du code Ansible

- **Correction des typos :** Plusieurs erreurs s'étaient introduites dans le code, le rendant inefficace. Parmi elles : **~/.cube/config**, situé dans le fichier `main` à la racine du projet. Cette erreur empêchait la connexion au cluster; la typo a donc été fixée -> **~/.kube/config**.

- **Réorganisation des modules :** Les modules du noyau **overlay** et **br_netfilter** ont été déplacés du rôle **os_hardening** vers **containerd**. La responsabilité était mal assignée : ces modules sont des prérequis du container runtime, pas de l'OS de base.

- **Optimisation de kubeadm init :**
  - ~~**--skip-phases=addon/kube-proxy** ajouté à **kubeadm init**. Cilium remplace kube-proxy, il ne doit jamais être installé. Cela permet d'éviter de potentiels conflits et assure une meilleure gestion des ressources au sein du cluster.~~ **advertiseAddress: "{{ ansible_default_ipv4.address }}"** & **podSubnet: "{{ kubernetes_pod_network_cidr }}"** ont été déplacé dans le fichier template de kubernetes **kubeadm-config**. En effet, la commande kube init ne peut pas prendre certains paramètre en flags comme **mode: "disabled"** pour désactiver kube-proxy, qui est essentiel ici. Conservation du flag **--config** afin de pointer vers le fichier template à la création du master.

  - ~~**apiserver-advertise-address={{ ansible_default_ipv4.address }}** ajouté à **kubeadm init**. Cela est nécessaire pour que Cilium sache sur quelle interface l'API serveur écoute.~~ _voir note du dessus_

- **Gestion dynamique des utilisateurs :** **ansible_env.HOME** a été remplacé par **ansible_facts.getent_passwd[ansible_user][4]**. Le kubeconfig atterrissait dans **/root/.kube** au lieu du home de l'utilisateur **alexandre**. **ansible_env.HOME** retourne le HOME de l'utilisateur de la session en cours (**root** dans ce cas), ce qui ne correspond pas à l'utilisateur qui va opérer kubectl au quotidien.

- **Idempotence :** **changed_when: false** ajouté sur **kubeadm token create**. C'est une commande en lecture seule qui ne modifie pas l'état du système.

- **Swapoff :** Ajout de **changed_when** à la suite de **when** pour une meilleure tracabilité des évènements. **when** contrôlait seulement si la task s'éxecutait. L'ajout de **changed_when** permet une meilleure tracabilité et contôle comment le résultat est rapporté.

- **Nettoyage :** **playbooks/setup-k8s.yml** supprimé. Résidu de refactoring, **site.yml** à la racine est le point d'entrée conventionnel d'Ansible.

## 2. Décisions architecturales

- **host_key_checking = True** conservé. Protection contre le MITM et le server spoofing. Je dois encore pré-enregistrer les clés SSH via **ssh-keyscan** avant de lancer Ansible.

- **deprecation_warnings = True** conservé. Permet de s'adapter aux évolutions d'Ansible et d'anticiper les changements qui pourraient affecter le cluster.

- **UFW désactivé :** Documenté comme une **dette technique** justifiée en phase de développement pour éviter les conflits avec Cilium, mais à adresser en phase de sécurité via les Network Policies Cilium et une configuration UFW stricte sur les ports Kubernetes critiques (6443, 2379-2380, 10250, 10257, 10259).

**Suppression d'outils par défaut :** En accord avec les objectifs de mon homelab, j'ai décidé de restreindre les outils installés de base. J'ai donc supprimé de la liste **git**, **wget**, **curl**, **vim**, **htop** et **apt-transport-https**.

- **apt-transport-https** : Le support HTTPS est désormais géré nativement par les versions récentes d'APT, ce paquet est donc devenu superflu.

- **Sécurité** : Concernant les autres outils, bien qu'utiles, ils représentent des vecteurs d'attaque ou des outils d'énumération potentiels pour un attaquant ayant réussi à s'introduire dans un conteneur ou sur un nœud.

## 3. Concepts appris

- **overlay** et **br_netfilter** : Leurs rôles respectifs dans la stack conteneur et pourquoi ils appartiennent à **containerd**.

- **kubeadm init** : Initialise le control plane sur le nœud master, génère les CA auto-signées et écrit les kubeconfig dans **/etc/kubernetes**.

- **Taints NoSchedule** sur le control plane : Pourquoi le master ne schedule pas de workloads par défaut en production.

- **Cilium vs kube-proxy** : Remplacement de iptables séquentiel par des maps eBPF en $O(1)$.

- **changed_when: false** : Évite les faux positifs "changed" sur les commandes en lecture seule, essentiel pour la lisibilité des rapports Ansible.

- **creates dans ansible.builtin.command** : Mécanisme d'idempotence, la tâche est ignorée si le fichier existe déjà.

- **ansible.builtin.getent** : Interroge **/etc/passwd** pour récupérer les informations d'un utilisateur système de façon dynamique.

- **ssh-keyscan** : Pré-enregistrement des clés SSH des nœuds avant de lancer Ansible, alternative propre à la désactivation de **host_key_checking**.

- **Révision syntaxe Jinja2** : Pas de `{{ }}` imbriqués, guillemets obligatoires quand la valeur YAML commence par `{{`.
