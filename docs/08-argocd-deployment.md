# Journal d'Avancement - Déploiement d'ArgoCD et mise en place du système "App of Apps" : décisions techniques et concepts appris

Le déploiement d'ArgoCD s'est effectué dans la continuation du déploiement physique du cluster. ArgoCD marque une étape majeure dans la vie du cluster avec la mise en place d'"app of apps" qui surveillera le repo GitHub en permanence. Je vais revenir dans ce devlog sur les décisions techniques prises, les diverses corrections effectuées ainsi que sur les différents concepts appris.

## 1. Décisions techniques

- **Déploiement d'ArgoCD :** Afin de rester le plus cohérent possible avec l'architecture existante, j'ai décidé de déployer _ArgoCD_ via _Terraform_ par un module dédié. Cela permet une meilleure cohérence et offre une meilleure traçabilité dans le state _Terraform_ comparé au déploiement via **kubectl apply**.

- **Service type NodePort :** Le **Service Type** d'_ArgoCD_ choisi est **NodePort** et écoute sur les ports **30443/30080**. Cela me semblait essentiel comparé à **LoadBalancer** car je ne dispose pas de **cloud provider** pour utiliser l'option du **LoadBalancer** en bare metal. Cependant, une option d'utilisation de **MetalLB** est envisagée dans le futur. Cela me permettrait d'avoir un cloud provider local.

- **Bootstrapping manuel :** J'ai dû déployer exceptionnellement mon manifest "app of apps" "root-app.yaml" via la commande **kubectl apply** car ArgoCD doit être informé de lui-même une première fois. Cela sera la seule exception au **GitOps**.

## 2. Corrections effectuées

- **Repository Helm :** Le repository Helm que j'avais utilisé au départ s'est avéré erroné ; il ne s'agissait pas du repository officiel mais de celui de _Bitnami_. J'ai donc corrigé et remplacé l'ancien repository par l'officiel **https://argoproj.github.io/argo-helm**.

- **Nom du chart :** Je m'étais trompé dans la typographie du nom de la chart. En effet, j'avais écrit **argocd** au lieu d'**argo-cd**. L'erreur est maintenant corrigée et le déploiement s'est effectué avec succès.

- **Syntaxe "set {}" :** Lors de mes recherches, je me suis rendu compte que le provider **Helm v3** ne supportait pas la syntaxe **"set {}"**. En me renseignant, j'ai découvert que la syntaxe correcte était **"set = [{}]"**.

- **server.service.type :** **server.service.type** n'étant pas appliqué via **yamlencode**, j'ai dû migrer son application via **set = [{}]**.

- **Path erroné :** Je m'étais trompé lors de la saisie du path de mon dossier apps. J'avais écrit au début **"/k8s/apps"** sauf que le chemin doit être relatif et non absolu. Le chemin a été corrigé en **"k8s/apps"**.

## 3. Concepts appris

- **GitOps :** **Git** sert de _source de vérité_ unique. **ArgoCD** synchronise le cluster avec l'état décrit dans le repository.

- **App of Apps :** Le pattern où une application **ArgoCD** parente surveille un dossier **Git** contenant des manifests **Application**. Chaque fichier ajouté dans ce dossier déclanche automatiquement le déploiement d'une nouvelle application.

- **Ressource Application :** Il s'agit d'une ressource personnalisée (CRD) installée par **ArgoCD**. ArgoCD surveille toutes les ressources **Application** dans son **namespace**.

- **Prune: true :** Utilisé dans mon manifest _"root-app.yaml"_, j'ai appris que **"prune: true"** supprimait automatiquement les ressources qui n'existent plus dans **Git**.

- **selfHeal: true :** Utilisé dans mon manifest _"root-app.yaml"_, j'ai appris que _"selfHeal: true"_ détectait et corrigeait les dérives manuelles sur le cluster.

- **Namespaces :** C'est une séparation logique des ressources dans le cluster. Chaque application vit dans son propre **namespace**.

- **NodePort vs LoadBalancer :** **NodePort** expose un service sur un port fixe de chaque nœud physique. **LoadBalancer** nécessite un **cloud provider** ou **MetalLB** en **bare metal**.

- **Bootstrapping :** **ArgoCD** est la seule exception **GitOps**. Il doit être configuré manuellement une première fois via **kubectl apply**.

## 4. État final

**ArgoCD** est déployé via **Terraform**, accessible sur **"https://192.168.1.50:30443"**. L'application **"app-of-apps"** est créée et en état **"Synced / Healthy"**. Le pattern **"App of Apps"** est en place et prêt à recevoir les applications enfants.
