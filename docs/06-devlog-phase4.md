# Journal d'Avancement - Phase 4 : Configuration & Infrastructure as Code - Initialisation de la partie Terraform

J'ai choisi de faire la configuration de mon cluster via Terraform pour plusieurs raisons : l'idempotence et l'apprentissage. Mes premiers choix s'étaient portés vers des solutions open-source comme Flannel pour l'adressage réseau. Cependant, dans une démarche d'apprentissage, le meilleur choix était d'essayer de tout produire soi-même.

## 1. Décisions techniques : Choix d'architecture

- **Local supprimé :** Lors de la première version de mon code, j'avais créé la ressource **local** dans le main. Je pensais que cette dernière allait m'aider à manipuler les fichiers système, mais elle est devenue obsolète après réflexion.

- **Pod_cidr :** J'ai fait ici le choix de ne pas mettre de valeur par défaut à ma variable **pod_cidr**. Cela permet de mettre en pratique le concept de **fail fast** car le **pod_cidr** est déjà configuré dans mon rôle **Ansible** _Kubernetes_. Cela nous permet de générer une erreur explicite plutôt qu'un bug réseau silencieux si les valeurs divergent. Cependant, la **version** de _Cilium_ a droit à sa variable afin de laisser le libre choix à l'utilisateur de sélectionner une version qui correspond à ses besoins.

## 2. Corrections effectuées

- **Terraform.lock :** À la création de ce projet, j'avais ajouté le fichier **.terraform.lock.hcl** à mon fichier **.gitignore**. J'ai décidé de le retirer car il est important de le commit. En effet, ce fichier contient toutes les clés chiffrées de mes fournisseurs (providers), nécessaires à la bonne initialisation du cluster et à la reproductibilité de l'environnement.

- **Correction de typo :** Comme dans le précédent devlog _05-devlog-phase3_, j'ai encore commis la même faute de frappe sur le chemin de configuration kubeconfig. J'avais tapé `~/.cube/config` au lieu de `~/.kube/config`. La typo a été corrigée.

- **Syntaxe du provider Helm :** Plusieurs petits pépins s'étaient glissés dans la syntaxe de mon bloc provider _Helm_, ce qui nuisait au bon fonctionnement du fichier. La version a correctement été initialisée via `~>` afin de n'accepter que les patchs mineurs et non les mises à jour majeures. Différentes typos ont été fixées, comme l'utilisation de `:` à la place de `=`.

## 3. Architecture du module Cilium

- **Module dédié :** Le choix de créer un module fut naturel. Afin de ne pas polluer le main à la racine et de permettre une meilleure organisation et gestion de _Cilium_, le module dédié a été créé.

- **Responsabilité :** Le module est divisé en trois fichiers. Un fichier _main_ qui installe Cilium via une **chart** _Helm_. C'est ici que tout est créé : le _namespace_ **kube-system**, la gestion de la **version** et le répertoire **cilium** récupéré via **Helm**. Le fichier _outputs_ permet de récupérer les **metadata** de la _release Helm_. Enfin, un fichier **variables** nous permet d'initialiser nos variables, ici la _version de Cilium_ et le _pod_cidr_.

- **Yamlencode :** Le bloc _values_ dans la _release Helm_ attend une liste de données YAML. Pour ce faire, j'ai eu recours à la fonction _yamlencode_ afin de transformer mes données (ici le _pod_cidr_ et _kubeProxyReplacement_) en format yaml que _helm_ peut interpréter.

## 4. Workflow

- **Flux de l'initialisation :** Lors du branchement physique du cluster, les opérations ne devront pas être effectuées dans un ordre aléatoire. Je vais commencer par installer Ubuntu via ma clé USB flashée sous _Ventoy_. Ensuite, j'initialiserai les nœuds via _Ansible_. Puis viendra la partie _scp kubeconfig_ (Secure Copy Protocol) qui me permettra de copier les fichiers, ici ceux de Kubernetes, entre mes différents nœuds et ma machine principale via _SSH_. Enfin, on lancera l'initialisation de _Terraform_ pour l'adressage IP (à venir) avec la configuration de Cilium et Kubernetes.

- **Terraform avant Ansible ?** Terraform ne peut pas tourner avant qu'_Ansible_ ait été initialisé sur le cluster. Cela serait impossible car _Terraform_ ne disposerait pas des fichiers de configuration nécessaires (`kube.config`, `pod_cidr`, etc.).

## 5. Concepts appris

- **Providers et plugins :** Les providers sont les agents qui permettent à Terraform de communiquer avec les API distantes (Helm, Kubernetes, Cloud Providers). Ils sont téléchargés lors du `terraform init`.

- **State Terraform et idempotence Ansible :** Le state _Terraform_ est fondamentalement différent de l'idempotence d'_Ansible_. En effet, _Ansible_ s'assure que l'état voulu est appliqué sur le moment. _Terraform_, au contraire, mémorise l'état de l'infrastructure dans un fichier de "State". S'il y a une différence entre le code et la réalité, il planifie exactement les modifications nécessaires pour synchroniser les deux.

- **terraform.tfvars :** La priorité des valeurs sur _Terraform_ suit un circuit précis. Les variables peuvent être initialisées via le fichier _terraform.tfvars_. S'il n'est pas présent ou si des variables n'y figurent pas, les valeurs par défaut précisées dans le code seront appliquées. Enfin, si aucune valeur par défaut n'est définie, Terraform demandera interactivement à l'utilisateur de fournir les informations manquantes.

- **Version :** J'avais effectué une erreur en passant **version** à mon provider **helm**. Cependant, cela était différent de **cilium_version**. Une petite erreur d'étourderie qui, en me renseignant m'aura appris beaucoup. **Version** est un argument réservé dans un bloc **module** et non dans un **provider**
