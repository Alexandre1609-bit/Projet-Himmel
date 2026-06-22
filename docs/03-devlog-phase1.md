# Journal d'Avancement - Phase 1 : Préparation & Infrastructure as Code

## État des Lieux

* **Matériel :** 3 nœuds physiques (Lenovo ThinkCentre) réceptionnés. Configuration BIOS effectuée (VT-x activé, C-States désactivés pour la performance).
* **Réseau :** En attente du matériel de connectivité (Switch & Répéteur).
* **Approche :** Développement en mode "Offline" (Dry Run). Rédaction du code d'automatisation (Ansible) en amont de la connexion physique.

## Refactoring Ansible : Passage aux "Rôles"

Initialement parti sur des Playbooks simples, j'ai pivoté vers une structure basée sur les rôles Ansible pour respecter les standards de l'industrie.

### Pourquoi ce choix ?

L'approche monolithique (un seul gros fichier YAML) me semblait ingérable sur le long terme. L'architecture en rôles va me permettre :

1. **L'Atomicité :** Chaque rôle a une responsabilité unique (faire une chose et la faire bien).
2. **La Réutilisabilité :** Le rôle `os-hardening` pourra être réutilisé sur d'autres projets Linux non-Kubernetes.
3. **La Clarté :** Séparation nette entre les Tâches (`tasks`), les Fichiers de config (`templates`) et les Réactions (`handlers`).

## Défis Techniques & Solutions

### 1. La Gestion du Swap (System Hardening)

**Problème :** Kubernetes ne supporte pas la mémoire Swap. Si elle est active, le `kubelet` refuse de démarrer.
**Solution Ansible :**
J'ai implémenté une double sécurité dans le rôle `os-hardening` :

* **Live :** Désactivation immédiate via `swapoff -a`.
* **Persistant :** Modification du fichier `/etc/fstab` via le module `replace` pour commenter la ligne de swap. Cela garantit que le swap ne revient pas au reboot.

### 2. Configuration du Runtime (Containerd)

**Problème :** Je suis tombé sur différentes templates containerd, mais elles étaient souvent obsolète et incompatible avec les dernières version de Kubernetes.

**Points critiques identifiés :**

* Conflit de gestion des ressources entre Systemd et Cgroupfs.
* Utilisation d'images "Sandbox" dépréciées (`k8s.gcr.io`).

**Solution Architecturée :**

* Création d'un Template Jinja2 (`config.toml.j2`) contrôlé et versionné.
* Forçage du paramètre `SystemdCgroup = true` pour aligner le gestionnaire de conteneur sur le gestionnaire de services d'Ubuntu (Systemd).
* Mise en place d'un Handler Ansible : Le service Containerd ne redémarre que si la configuration a été modifiée, garantissant l'idempotence.

### 3. La Persistance des Modules Noyau

**Problème :** Les modules nécessaires au réseau K8s (`overlay`, `br_netfilter`) chargés via `modprobe` disparaissent au redémarrage.
**Solution :**
Utilisation conjointe de deux méthodes dans Ansible :

1. Chargement immédiat via `community.general.modprobe`.
2. Création d'un fichier dans `/etc/modules-load.d/` pour assurer le chargement automatique au boot.

## Prochaines Étapes

1. **Finalisation du Code :** Développement du dernier rôle Ansible `kubernetes` (installation de Kubeadm, Kubelet, Kubectl) avec gestion complexe des dépôts.
2. **Hardware :** Réception et branchement du Switch et du Répéteur Wifi.
3. **Concrétisation :** Premier lancement réel du playbook complet sur les machines physiques.
4. **Ajout des documentations :** Créer un fichier "sources" regroupant l'ensemble des sources utilisées lors de mes recherches.
