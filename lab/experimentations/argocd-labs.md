# Projet-Himmel — Premiers labs Argo CD et Kubernetes

Dans l'optique d'en apprendre plus sur ArgoCD j'ai décider de passer par des labs :trois expériences explorant la réconciliation Argo CD et l’auto-réparation Kubernetes : modification du nombre de répliques, suppression manuelle d’un Pod et ajout manuel d’une annotation au Deployment. Les deux premières montrent des comportements attendus (`selfHeal` et contrôleur ReplicaSet); la troisième reste inconclusive et mérite une investigation ciblée. Ce compte-rendu de mes 3 labs est une première approche non "appronfie" d'ArgoCD afin de commencer par ce que je juge être les bases.

## Contexte commun

- Cluster Kubernetes géré avec Argo CD.
- Application enfant associée au Deployment `nginx-deployment`, dans le namespace `nginx`.
- Configuration `syncPolicy` observée sur l’application :

  ```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
  ```

- Deployment souhaité dans Git : `spec.replicas: 1`.
- Image utilisée par les Pods : `nginx:1.14.2`.

**Distinction importante :**

- `selfHeal` permet à Argo CD de corriger les écarts de l’état du cluster par rapport à l’état désiré, lorsque les conditions de réconciliation le permettent.
- `prune` autorise Argo CD à supprimer les ressources suivies qui ne figurent plus dans l’état désiré lors d’une synchronisation appropriée.
- Les contrôleurs Kubernetes maintiennent eux-mêmes les objets dont ils ont la charge, par exemple un ReplicaSet qui maintient le nombre de Pods voulu.

---

# Lab 1 — Modifier manuellement le nombre de réplicas

## Hypothèse initiale

Si le Deployment est modifié directement dans le cluster pour passer de 1 à 3 réplicas alors que Git déclare toujours `replicas: 1`, Argo CD devrait détecter un écart et, grâce à `selfHeal: true`, ramener le Deployment à l’état désiré.

## Doute à vérifier

Est-ce Argo CD qui supprime directement les Pods excédentaires, ou corrige-t-il le Deployment en laissant Kubernetes faire respecter le nombre de réplicas ?

## Expérience

Modifier le nombre de réplicas depuis le cluster :

```bash
kubectl scale deployment nginx-deployment -n nginx --replicas=3
```

Observer le statut de l’application Argo CD, puis vérifier le nombre de réplicas :

```bash
kubectl get deployment nginx-deployment -n nginx \
  -o jsonpath='{.spec.replicas}{" desired / "}{.status.replicas}{" current / "}{.status.readyReplicas}{" ready\n"}'
```

## Résultat attendu

1. Argo CD détecte une différence entre Git et le cluster.
2. L’application passe temporairement à `OutOfSync`.
3. `selfHeal` ramène le champ `spec.replicas` à `1`.
4. Le contrôleur Kubernetes réduit ensuite le nombre de Pods pour correspondre à la spécification du Deployment.

## Résultat observé

Les statuts ont évolué comme suit :

```text
Synced / Healthy
→ OutOfSync / Progressing
→ Synced / Progressing
→ Synced / Healthy
```

État final observé :

```text
1 desired / 1 current / 1 ready
```

Des Pods ont été créés temporairement, puis terminés pendant le retour à l’état désiré.

## Interprétation

L’observation est cohérente avec le fonctionnement de `selfHeal` : Argo CD a ramené la spécification du Deployment à `replicas: 1`. Le contrôleur du Deployment et le ReplicaSet ont ensuite convergé vers ce nombre de Pods.

Le fait que des Pods excédentaires disparaissent ne signifie pas que `prune` a été utilisé. Ils sont gérés par les contrôleurs Kubernetes à partir de la valeur de `spec.replicas`.

Les seuls statuts et l’état final ne constituent toutefois pas une trace complète de chaque action interne. Pour confirmer précisément la séquence, on pourrait corréler les événements Kubernetes, l’historique de l’application et les journaux Argo CD.

## Conclusion

**Hypothèse globalement confirmée.** La modification directe du nombre de réplicas crée un écart que `selfHeal` peut corriger. Argo CD corrige la spécification désirée ; les contrôleurs Kubernetes ajustent ensuite les Pods. `prune` n’est pas le mécanisme responsable de la suppression des Pods excédentaires dans ce scénario.

---

# Lab 2 — Supprimer manuellement un Pod géré par un Deployment

## Hypothèse initiale

Si un Pod appartenant au ReplicaSet d’un Deployment est supprimé manuellement, Kubernetes devrait créer un Pod de remplacement sans nécessiter une synchronisation Argo CD.

## Doute à vérifier

Quel composant prend la décision de recréer le Pod ? Est-ce Argo CD, le Deployment controller, le ReplicaSet controller, le scheduler ou le kubelet ?

## Expérience

Supprimer un Pod du Deployment, puis observer les événements :

```bash
kubectl delete pod <nom-du-pod> -n nginx
kubectl get pods -n nginx -o wide
kubectl get events -n nginx --sort-by=.metadata.creationTimestamp
```

Le nom exact du Pod supprimé n’est pas conservé dans le résumé du lab; les événements observés sont reproduits ci-dessous.

## Résultat attendu

Le ReplicaSet constate que le nombre de Pods existants est inférieur au nombre désiré et demande la création d’un Pod de remplacement. Le Pod doit ensuite être démarré sur un nœud.

## Résultat observé

Événements observés :

```text
Normal Killing pod/nginx-deployment-b995944fb-8v6jb
  Stopping container nginx

Normal SuccessfulCreate replicaset/nginx-deployment-b995944fb
  Created pod: nginx-deployment-b995944fb-mw689

Normal Pulled pod/nginx-deployment-b995944fb-mw689
  Container image "nginx:1.14.2" already present on machine

Normal Created pod/nginx-deployment-b995944fb-mw689
  Created container: nginx

Normal Started pod/nginx-deployment-b995944fb-mw689
  Started container nginx
```

Le Pod de remplacement présentait également :

```yaml
spec:
  nodeName: node3
```

L’image `nginx:1.14.2` était déjà présente sur le nœud.

## Interprétation

La recréation du Pod est cohérente avec la réconciliation effectuée par le ReplicaSet controller. Le Deployment controller gère les ReplicaSets; le ReplicaSet controller veille au nombre de Pods attendu.

La chaîne conceptuelle à retenir est :

1. Le ReplicaSet controller constate qu’il manque un Pod et demande sa création via l’API Kubernetes.
2. L’API Server valide et traite la modification de l’objet; etcd conserve l’état persistant du cluster.
3. Le scheduler choisit un nœud si le Pod n’en a pas déjà un d’assigné.
4. Le kubelet du nœud concerné prend en charge le Pod et demande au runtime de créer et démarrer le conteneur.

Dans cette observation, `spec.nodeName: node3` indique que le Pod était déjà associé à `node3` : il ne faut donc pas conclure que le scheduler a choisi ce nœud lors de cette recréation. Le fait que l’image soit déjà présente explique pourquoi un téléchargement de l’image n’était pas nécessaire.

Argo CD n’a pas besoin de recréer chaque Pod individuellement : Kubernetes maintient le nombre de Pods défini par le Deployment/ReplicaSet.

## Conclusion

**Hypothèse confirmée par les observations.** La suppression d’un Pod est compensée par le contrôleur ReplicaSet. Ce comportement relève de l’auto-réparation des contrôleurs Kubernetes, et non d’un prune Argo CD. Le scheduler n’est impliqué dans le choix du nœud que si le Pod doit encore être planifié.

---

# Lab 3 — Ajouter une annotation directement sur le Deployment

## Hypothèse initiale

Si une annotation est ajoutée manuellement au Deployment dans le cluster, mais qu’elle n’existe pas dans le manifeste désiré de Git, Argo CD pourrait détecter l’écart et le corriger grâce à `selfHeal: true`.

## Doute à vérifier

Argo CD compare-t-il et corrige-t-il cette annotation dans la configuration actuelle ? Si elle persiste, cela prouve-t-il qu’Argo CD ignore les annotations ?

## Expérience

Ajouter une annotation au Deployment :

```bash
kubectl annotate deployment nginx-deployment -n nginx \
  lab-test=modified --overwrite
```

Inspecter les annotations du **Deployment lui-même** :

```bash
kubectl describe deployment nginx-deployment -n nginx
```

Vérifier aussi le statut de l’application dans Argo CD.

## Résultat attendu

Si l’annotation ne figure pas dans le manifeste rendu depuis Git et si elle est prise en compte par la comparaison Argo CD, on s’attend à voir un écart. Selon la configuration de l’application, la réconciliation devrait ensuite retirer l’annotation ajoutée manuellement.

## Résultat observé

L’annotation était toujours présente sur le Deployment :

```text
Annotations:
  argocd.argoproj.io/tracking-id: monitoring:apps/Deployment:nginx/nginx-deployment
  deployment.kubernetes.io/revision: 1
  lab-test: modified
```

L’application parente et les applications examinées étaient affichées comme `Synced / Healthy`. L’annotation a finalement été supprimée manuellement :

```bash
kubectl annotate deployment nginx-deployment -n nginx lab-test-
```

## Interprétation

**Résultat inconclusif.** L’expérience n’a pas montré la correction attendue, mais elle ne suffit pas à prouver qu’Argo CD ignore les annotations.

Avant de tirer une conclusion, il faudrait vérifier notamment :

- que l’application enfant surveille bien le manifeste qui définit ce Deployment;
- que `lab-test` est absent du manifeste **rendu** depuis Git, après éventuel traitement Helm/Kustomize;
- que l’application concernée a bien `selfHeal: true` et que la synchronisation automatique est active;
- si une règle de personnalisation ou d’ignorance des différences (`ignoreDifferences`, options de comparaison ou configuration similaire) intervient;
- les détails du diff et les événements/journaux Argo CD autour de l’ajout.

Le statut `Synced` signifie que, selon les règles de comparaison actives, Argo CD ne signale pas de différence détectée. Il ne suffit pas, à lui seul, à expliquer pourquoi l’annotation est restée présente.

## Conclusion

**Hypothèse non confirmée ; investigation à poursuivre.** L’annotation manuelle a persisté alors que l’application était affichée `Synced / Healthy`. Il faut déterminer si le manifeste désiré, le suivi de l’application ou les règles de comparaison expliquent ce résultat avant d’affirmer qu’Argo CD ignore ce champ.

---

# Bilan des trois labs

| Lab                          | Résultat                                                             | Notion principale                                                  |
| ---------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ |
| 1. Mise à l’échelle manuelle | Cohérent avec l’auto-réparation attendue                             | `selfHeal` corrige la spécification ; Kubernetes ajuste les Pods   |
| 2. Suppression d’un Pod      | Recréation observée dans les événements                              | Le ReplicaSet controller maintient le nombre désiré de Pods        |
| 3. Ajout d’une annotation    | Inconclusif : annotation persistante, application `Synced / Healthy` | Vérifier le manifeste rendu, le suivi et les règles de comparaison |

## Résultats et questions ouvertes

Les deux premiers labs illustrent deux mécanismes distincts : la réconciliation GitOps pilotée par Argo CD et la réconciliation des objets Kubernetes par leurs contrôleurs. Le troisième rappelle qu’un statut `Synced` dépend de ce qu’Argo CD compare réellement et des règles de comparaison configurées.

Questions à reprendre dans les prochains labs :

- Distinguer **refresh**, calcul du diff, état `OutOfSync` et **Sync**.
- Comparer une synchronisation manuelle avec `automated` et comprendre le rôle de `selfHeal`.
- Tester le `prune` sur une ressource suivie retirée de Git, puis étudier les politiques de propagation de suppression.
- Vérifier le comportement des webhooks par rapport au rafraîchissement périodique.
