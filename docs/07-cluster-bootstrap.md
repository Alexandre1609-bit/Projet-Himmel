# Journal d'Avancement - Déploiement physique du cluster : rencontre de bugs, résolution et mise à jour de code déprécié

Le cluster voit enfin le jour avec le déploiement physique réalisé aujourd'hui. Les trois nœuds (un master et deux workers) sont branchés, connectés et initialisés, le tout configuré via SSH et mes rôles _Ansible_. Je vais revenir ici sur les différents problèmes rencontrés, comment j'ai pu les résoudre et ce que j'ai pu en tirer.

## 1. Problèmes rencontrés & corrections

- **Utilisateur Ansible incorrect :** Ansible utilisait par défaut l'utilisateur **alex**, _l'utilisateur de ma machine principale_, au lieu d'**Alexandre** (l'utilisateur sur les nœuds). Ceci était dû à un problème d'initialisation : en effet, je lançais _Ansible_ depuis la racine de mon projet et non depuis le sous-dossier _Ansible_. En lançant l'initialisation depuis le bon dossier, _Ansible_ a pu trouver et utiliser correctement mes fichiers _ansible.cfg_ et _group_vars/all.yml_.

- **Dossier container inexistant :** Quand _Containerd_ est installé via apt, il ne crée pas son dossier de configuration automatiquement. J'ai dû ajouter une task _ansible.builtin.file_ afin de créer le dossier **/etc/containerd** avant de déployer le template.

- **"Restart-containerd introuvable" :** Ici il s'agissait d'une simple erreur d'inattention mais assez sérieuse pour bloquer l'initialisation du cluster. En effet, le nom de mon **handler** et celui du **notify** étaient différents, j'avais mis un **"-"** en trop. Le problème a été corrigé en l'enlevant.

- **Conntrack manquant :** J'ai appris que **kubeadm init** vérifie la présence de **conntrack** en tant que prérequis réseau. Je ne l'avais pas installé et le cluster ne pouvait donc pas s'initialiser. J'ai donc ajouté **conntrack** à la liste des binaires requis dans mon rôle **os-hardening**.

- **Remplacement de code déprécié :** Dans mon fichier de configuration **kubeadm-config.yaml.j2**, j'utilisais **"apiVersion: kubeadm.k8s.io/v1beta3"**. Cependant, cette version est dépréciée pour la version de _Kubernetes_ que j'utilise. J'ai donc migré vers **"v1beta4"** dans mon fichier de configuration. La ligne de code **ansible_swaptotal_mb** qui se trouvait dans mon fichier **os-hardening** était dépréciée. Elle a été remaplcée par sa nouvelle version : **ansible_facts["swaptotal_mb"]**

- **Permission du kubeconfig :** Dans _Ansible_, **become: yes** fait tourner les tasks en tant que **root**. Le dossier **.kube** et le fichier **config** appartenaient à **root** au lieu d'**Alexandre**. Le problème a été corrigé manuellement via la commande **sudo chown -R alexandre:alexandre ~/.kube**. C'est aussi à corriger dans le code avec **owner** et **group** dans les tasks **file** et **copy**.

- **Problème lors de l'installation de Cilium :** Problème de démarrage circulaire **"dial tcp 10.96.0.1:443: i/o timeout"**. _Cilium_, sur les workers, essayait de contacter l'"API server" via l'IP virtuelle du service _Kubernetes_ (10.96.0.1) qui n'était pas encore routable car _Cilium_ n'était pas démarré. Afin de pallier ce problème, j'ai dû ajouter **"k8sServiceHost"** et **"k8sServicePort"** dans le module _Terraform_ de _Cilium_ afin de pointer directement vers l'IP physique du master _(192.168.x.x:6443)_.

- **Redémarrage nécessaire après Ansible :** Suite à des mises à jour système, _Ubuntu_ avait besoin de redémarrer. Afin de garantir le bon fonctionnement de l'infrastructure, j'ai redémarré le master pour stabiliser le cluster.

## 2. Concepts appris

- **ssh-keyscan :** J'ai utilisé la commande **ssh-keyscan** sur mes nœuds avant d'utiliser _Ansible_ afin d'éviter les prompts interactifs.

- **ssh-copy-id :** Avec cette commande, j'ai pu copier ma clé SSH publique sur un nœud distant afin de permettre l'authentification automatique.

- **scp :** Commande utilisée pour copier la configuration **kube-config** de mon master vers ma machine. Cela m'a permis de copier des fichiers entre deux machines via _SSH_.

- **crictl ps :** J'ai dû utiliser cette commande _containerd_ pour inspecter mes conteneurs sur mes nœuds afin de diagnostiquer les problèmes rencontrés avec _Cilium_.

- **Kubectl describe pod :** Encore une commande utilisée pour le diagnostic des problèmes rencontrés ; elle m'a permis d'afficher les détails complets d'un pod, en y incluant les événements.

- **Kubectl logs --previous :** Pareil que les deux commandes précédentes, utilisée pour le diagnostic. Cette commande m'a permis de récupérer les logs du conteneur précédent quand un pod redémarre.

- **Helm uninstall :** J'ai dû utiliser cette commande afin de supprimer ma release _Helm_ de mon cluster car _Terraform_ ne parvenait pas à le faire via la commande **terraform destroy**.

- **Démarrage circulaire de Cilium :** Lorsque nous "enlevons" **kube-proxy** via **kubeProxyReplacement=true**, _Cilium_ a besoin du réseau pour contacter l'API server, mais le réseau dépend de _Cilium_, donc c'est impossible. Pour ce faire, j'ai dû pointer directement vers l'IP physique du master.

## 3. État final à ce jour (05/02/26)

Les trois nœuds sont marqués **Ready** par **kubectl** et le cluster est déployé sur la version 1.19.1 de _Cilium_. **Hubble** est aussi activé par défaut, le cluster est donc opérationnel sur bare metal.
