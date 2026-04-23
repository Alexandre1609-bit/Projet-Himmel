````md
# Journal d'avancement - Déploiement de la stack d'observabilité : Problèmes rencontrés, résolution et avancement du cluster

Je me suis penché sur le déploiement de la stack d'observabilité après avoir déployé ArgoCD. Lors du déploiement, j'ai rencontré pas mal de problèmes de version avec les charts Helm, avec ArgoCD et les CRDs. Tout cela a pris plus de temps que prévu mais s'est avéré très instructif. Je vais ici détailler les problèmes rencontrés ainsi que les solutions apportées. Enfin, je me pencherai sur l'état final cluster après le déploiement de la stack d'observabilité.

## 1. Problèmes rencontrés et résolutions

- **ArgoCD v2.0.1 :** J'avais déployé une ancienne version d'_ArgoCD_, la **2.0.1** au lieu de la version **3.x**. Le problème est que la chart du repository **"argoproj.github.io/argo-helm"** déployait ArgoCD version **2.0.1**, une version ancienne datant de 2021. Le bon repository est **"argo/argo-cd"** avec la chart version **9.5.4** qui déploie une version plus récente d'ArgoCD, la **3.3.8**. Afin d'apporter les modifications nécessaires, j'ai dû mettre à jour le module Terraform d'ArgoCD en y mettant la bonne version ainsi que le bon repository.

- **Helm template et Kubernetes :** Helm template utilise Kubernetes version **1.20.0**. ArgoCD passait la version **1.20.0** à **helm template** au lieu de la vraie version du cluster (**1.31.14**). Cela bloquait toutes les charts avec une contrainte **"kubeVersion >= 1.25"**. Cela a donné lieu à différentes tentatives infructueuses afin de résoudre le problème : **kubeVersion** dans le manifest (champ invalide en **2.0.1**), **configs.cm.kube-version** sur Terraform (mauvais chemin). En ultime solution, j'ai décidé d'effectuer une mise à jour vers ArgoCD version **3.3.8** qui gère correctement la version Kubernetes.

- **CRDs ArgoCD :** Les **CRDs** d'ArgoCD bloquaient la mise à jour de la chart ArgoCD. Les **CRDs** existantes bloquaient le déploiement avec l'erreur **"invalid ownership metadata"**. Pour pallier ce problème, j'ai dû supprimer manuellement les **CRDs** avant de relancer **terraform apply**.

```bash
kubectl delete crd applications.argoproj.io appprojects.argoproj.io
terraform apply
```
````

- **Applications perdues après réinstallation d'ArgoCD :** La suppression des **CRDs** a effacé toutes les ressources **Application**. La solution trouvée a été d'effectuer une réapplication manuelle de mon manifest **root-app.yaml**.

```bash
kubectl apply -f k8s/apps/root-app.yaml
```

- **Version inexistante de Kyverno :** J'avais renseigné la version **3.7.2** de **Kyverno** dans son manifest, or cette version **n'existait pas** dans le repository. J'ai donc mis à jour la version vers la **3.7.1**.

- **OutOfSync permanent sur Kyverno :** Kyverno modifie ses propres CRDs après installation. De ce fait, ArgoCD détecte en permanence une dérive. L'affichage d'**OutOfSync** me paraissait suspect alors même que les logs me disaient que tout allait bien.

```bash
kubectl get pods -n kyverno
NAME                                             READY   STATUS      RESTARTS   AGE
kyverno-admission-controller-b469db77f-k62zd     1/1     Running     0          5m36s
kyverno-background-controller-6674dc69f5-dkdb5   1/1     Running     0          5m36s
kyverno-cleanup-controller-5bb56f66f4-m6bb8      1/1     Running     0          5m36s
kyverno-migrate-resources-nflcr                  0/1     Completed   0          4m32s
kyverno-reports-controller-647dd56678-qvtdw      1/1     Running     0          5m36s
➜  homelab-k8s git:(main) kubectl get application -n argocd
NAME          SYNC STATUS   HEALTH STATUS
app-of-apps   Synced        Healthy
falco         Synced        Healthy
grafana       Synced        Healthy
kyverno       OutOfSync     Healthy
prometheus    Synced        Healthy
```

Après m'être renseigné, j'ai constaté que ce comportement était connu et documenté. J'ai ajouté **ignoreDifferences** sur les **CRDs** en guise de solution partielle. L'**OutOfSync** persiste mais tous les pods sont en statut **Running/Healthy**.

- **Cache ArgoCD corrompu :** Après correction des manifests, ArgoCD continuait d'utiliser l'ancienne erreur en cache. Pour combler cela, j'ai dû redémarrer **argocd-repo-server** et **argocd-redis** puis effectuer un **refresh** forcé.

```bash
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl rollout restart deployment argocd-redis -n argocd
kubectl annotate application app-of-apps -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

- **Cluster instable lors du déploiement :** Le déploiement des quatre manifests a surchargé le master. Les services **SSH** et l'**API** sont devenus inaccessibles. C'était un problème mineur que j'ai pu corriger en redémarrant le master et en attendant que la synchronisation se fasse correctement.

- **IP réassignée temporairement :** Pendant la période d'instabilité, les nœuds se sont vu assigner de nouvelles adresses IP, les rendant **inaccessibles**. En effectuant un **nmap** sur le master, il était indiqué **iphone-5.home**. La cause était située à la **layer 1** : l'uplink WiFi était déconnecté. J'ai juste eu à débrancher et rebrancher l'uplink afin de redonner un accès internet au cluster, qui a ensuite récupéré ses IP.

## 2. Concepts appris

- **CRDs :** _Custom Resource Definitions_, extensions de l'API Kubernetes. ArgoCD installe les siennes **(Application, AppProject)** pour ajouter ses propres types de ressources.

- **Comportement de Kyverno avec ArgoCD :** Kyverno auto-modifie ses **CRDs**, créant une dérive permanente. C'est un comportement documenté, pas une erreur.

- **Cache ArgoCD :** ArgoCD stocke les résultats de **helm template** dans **Redis**. Un cache corrompu peut persister après correction des manifests.

- **Versioning des charts Helm :** Le numéro de version d'une chart Helm n'est pas le numéro de version de l'application : **argo-cd 3.3.5** est différent d'**ArgoCD v3.3.5**.

## 3. Commandes apprises

- **kubectl get pods -A :** liste tous les pods de tous les namespaces

- **kubectl describe application <name> -n argocd :** détails complets d'une application ArgoCD incluant les erreurs

- **kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite :** force ArgoCD à relire le repository Git immédiatement

- **kubectl rollout restart deployment <name> -n <namespace> :** redémarre un déploiement proprement

- **kubectl rollout status deployment <name> -n <namespace> :** attend la fin d'un rollout

- **kubectl delete crd <name> :** supprime une CRD et toutes les ressources associées

- **kubectl get application -n argocd -o yaml :** affiche le manifest complet d'une application ArgoCD

- **nmap -Pn -p 22,6443 <ip> :** vérifie si des ports sont ouverts sur un hôte

- **helm search repo <chart> --versions :** liste toutes les versions disponibles d'un chart

- **helm show values <chart> --repo <url> :** affiche les _values_ disponibles d'une chart

## 4. État final

Les applications suivantes : app-of-apps, falco, grafana, prometheus sont toutes **Synced** et **Healthy**. Kyverno affiche toujours **OutOfSync** de manière permanente et **Healthy**, mais comme dit avant c'est un problème connu et documenté, tous ses pods sont bien **Running/Healthy**.
