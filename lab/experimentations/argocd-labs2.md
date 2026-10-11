# Projet-Himmel — Labs Argo CD et Kubernetes

J'ai décidé de séparer les trois premiers labs afin de continuer à apprendre le fonctionnement d'Argo CD. Le but des prochains labs est d'aller un peu plus en profondeur sur le fonctionnement d'Argo CD. L'objectif est d'observer un maximum de choses à travers cinq labs. L'organisation des labs est la suivante :

- Lab 4 — Sync manuel vs auto-sync

  Prochaine étape

  Modifier une valeur dans Git et observer la différence entre détection d’un écart et application de la modification.

- Lab 5 — Refresh et boucle de réconciliation

  Observer quand Argo CD actualise sa connaissance de Git, quand le diff est calculé et comment le statut évolue.

- Lab 6 — Webhook vs rafraîchissement périodique

  Vérifier si ton forge Git notifie Argo CD après un push et distinguer notification, refresh et synchronisation.

- Lab 7 — Rollback GitOps

  Déployer une modification, revenir à un état Git antérieur et vérifier la convergence du cluster.

- Lab 8 — Organisation par environnement

  Concevoir une base commune et des configurations distinctes pour dev, staging et prod, par exemple avec Kustomize.

Le lab 8 comptera comme lab bonus : je n'ai pas encore touché à Kustomize, et le but ici n'est pas d'apprendre de nouvelles choses, mais de me concentrer sur Argo CD.

---

# Lab 4 - Sync manuel vs auto-sync

## État des lieux

Afin de ne plus malmener mon application Nginx, j'ai décidé de déployer rapidement un déploiement de test dans un namespace de test.

Nous commençons donc avec ceci :

```bash

➜  manifests git:(main) ✗ kubectl get deployment test-deployment -n test-ns \\

  -o jsonpath='{.spec.replicas}{" replicas\n"}'

2 replicas

```

Comme lors des tests précédents, notre namespace est surveillé par une application mère (App of Apps) avec les Sync Policies suivantes :

```yaml
syncPolicy:
  automated:
    prune: true

    selfHeal: true
```

## Hypothèse initiale

Dans l'état actuel des choses, si je supprime un manifeste de mon cluster, il sera supprimé rapidement (webhook... ?) (cf. labs précédents). Afin d'essayer d'observer au mieux l'évolution des statuts (Synced / OutOfSync et Healthy / Progressing), je vais désactiver l'auto-sync, le self-heal et le pruning dans mon application mère. L'objectif est de voir si Argo CD peut lui-même observer un drift et demander la suppression d'un pod... Nous allons essayer de suivre les événements en temps réel.

## Observations

J'ai volontairement passé les champs `prune` et `selfHeal` en "false" afin de ne pas être pressé par les prises de décisions automatiques

```yaml
syncPolicy:
  automated:
    prune: false

    selfHeal: false
```

L'application mère est initialement fonctionnelle :

```bash

monitoring       Synced        Healthy

```

J'ai ensuite supprimé le manifeste de mon déploiement de test de Git et j'ai poussé le changement.

J'ai chronométré le temps entre mon push et la détection du drift par Argo CD : il s'est écoulé exactement 2 minutes.

Après ces deux minutes, le statut de synchronisation de mon application a changé :

```bash

monitoring       OutOfSync     Healthy

```

De cette ligne, nous pouvons déjà conclure quelque chose : une application `OutOfSync` (drift détecté entre le cluster et GitHub) peut très bien fonctionner. Ici, mon déploiement n'est pas supprimé, car j'ai désactivé `prune`. Mon application a donc détecté un drift : une ressource est encore présente sur le cluster alors qu'elle ne figure plus sur GitHub. Pour autant, mon déploiement continue de fonctionner et n'a en rien été perturbé :

```bash

➜  manifests git:(main) ✗ kubectl get pods -n test-ns -w

NAME                               READY   STATUS    RESTARTS   AGE

test-deployment-7bdbd79794-cbn7s   1/1     Running   0          17m

test-deployment-7bdbd79794-h2977   1/1     Running   0          17m

```

On aurait pu s'attendre à ce que notre déploiement soit supprimé par Kubernetes lui-même mais en fait non. Cela est dû au fait que Kubernetes et ses composants (kubelet, controller-manager...) ne se soucient pas de notre manifeste supprimé de GitHub. Notre déploiement est sur le cluster et répond aux exigences attendues : 2 répliques, dans tel namespace... Argo CD, qui n'a pas l'option `prune` activée, ne va pas envoyer de requête HTTPS au `kube-apiserver` pour demander la suppression des ressources orphelines.

Nous pouvons aussi nous demander ce qui va se passer si l'on teste une sync manuelle depuis l'interface d'Argo CD.

Résultat attendu : rien ne va changer. Argo CD a une boucle de réconciliation qui, par défaut, agit toutes les 2 à 3 minutes afin de repérer les éventuels drifts. Ici, la boucle a déjà parcouru plusieurs fois mon application mère et repéré le drift, sans pour autant rien supprimer. Nous pouvons donc nous attendre à ce qu'une sync manuelle n'ait pas vraiment d'impact.

Résultat : Comme attendu, le sync manuel n'a rien supprimé. L'interface affiche « Last Sync OK », car Argo CD a réussi à appliquer les manifestes restants dans Git sans erreur technique lors des appels à l'API Kubernetes. Cependant, l'état global reste "OutOfSync" : ayant l'interdiction de détruire des ressources (`prune` désactivé), Argo CD laisse le déploiement orphelin sur le cluster, maintenant ainsi la différence entre l'état désiré (Git) et l'état réel (Cluster).

Je vais maintenant relancer un Sync depuis l'UI mais cette fois-ci avec l'option `prune` activée. Normalement notre déploiement devrait se faire supprimer et l'état devrait passer de nouveau en Synced / Healthy !

Comme attendu après avoir lancé le sync manuel avec `prune` d'activée notre application retrouve son état initial:

```bash

monitoring       Synced        Healthy

```

---

# Lab 5 - Refresh et boucle de réconciliation

Dans ce lab, nous commencerons avec les mêmes ressources que dans le lab précédent : notre déploiement de test ainsi que son namespace. J'aimerais ici essayer d'observer la boucle de réconciliation, de comprendre comment le cache fonctionne (refresh, hard refresh) et de voir comment Argo CD articule tout cela via les logs de ses pods : trouver le pod qui gère le tout, comprendre ce qu'il se passe réellement et essayer d'avoir en tête un schéma du « flow » d'Argo CD...

## Hypothèse initiale

De ce que je comprends d'Argo CD et de ce que j'ai pu observer jusqu'à présent, je pense que la réconciliation a lieu à intervalles réguliers, par défaut toutes les 2 à 3 minutes ? J'aimerais essayer d'observer cela en laissant l'auto-heal et le prune désactivés et en ajoutant des réplicas à mon déploiement afin d'observer au bout de combien de temps le drift sera détecté. J'aimerais aussi comprendre les refresh et distinguer les refresh des sync, par exemple. Je pense qu'une sync correspond à une détection de drift, alors que les refresh permettent d'actualiser ce qu'Argo CD connaît de l'état du cluster (stocké via l'Application Controller ?). Pour cela, je reprendrai ma première expérience et j'essaierai de faire un refresh en espérant observer une détection « prématurée ».

## Observations

Comme dit ci-dessus, nous partons avec notre déploiement de 2 pods. Je vais augmenter son nombre de réplicas à 3, chronométrer et voir ce qu'il se passe ensuite :

```bash

7s Normal ResourceUpdated application/monitoring Updated sync status: Synced -> OutOfSync

│17s Normal ResourceUpdated application/monitoring Update

│d health status: Healthy -> Progressing

│16s Normal ResourceUpdated application/monitoring Update

│d health status: Progressing -> Healthy

```

Le changement de statut de mon application s'est fait en l'espace de quelques secondes, en moins de dix secondes. L'application est passée en OutOfSync comme attendu (`selfHeal` et `prune` désactivés) et elle est passée de Healthy à Progressing (création de la réplique) et de Progressing à Healthy (réplique créée et non supprimée).

Comparé à notre expérience précédente, le temps de détection est beaucoup plus court, presque instantané, contre 2 minutes (minimum observé, peut-être plus) pour le drift via GitHub.

On peut dégager deux hypothèses intéressantes :

1\. Dans le premier cas, Argo CD n'a détecté le drift qu'au bout de 2 minutes au minimum après la suppression du manifeste de GitHub. Cela pourrait laisser penser qu'Argo CD procède à une actualisation périodique de sa connaissance de GitHub.

2\. Le deuxième cas, lui, nous montre une détection presque instantanée, de l'ordre de moins de 10 secondes après la création d'une réplique supplémentaire. Cela pourrait nous amener à penser qu'Argo CD déclenche une actualisation lorsqu'un changement de ressource Kubernetes a lieu.

Il me semble important de noter qu'avec seulement quelques expériences, nous ne pouvons pas affirmer quoi que ce soit quant au fonctionnement général d'Argo CD.

Cependant, rien ne nous empêche d'établir le schéma théorique suivant :

```text

Git - état désiré

      |

      |

Application controller

Compare état désiré <-> état réel

      |

      |

Synced / OutOfSync (selon état observé)

      |

      |

Sync pour appliquer l'état désiré

```

Dans ce schéma, j'affirme que l'Application Controller se charge de la comparaison entre Git et le cluster. J'ai pu observer cela dans les logs :

```bash

time="2026-10-11T18:00:55Z" level=info msg="Comparing app state (cluster: https://Kubernetes.default.svc, namespace: grafana)" app-namespace=argocd application=grafana project=default

```

L'Application Controller se charge aussi de la boucle de réconciliation, qui semble avoir lieu toutes les 3 minutes dans le cas de mon cluster (temps par défaut ?).

J'en conclus cela, encore une fois, à partir des logs. Une première réconciliation a été lancée à 17 h 57 et une seconde à 18 h.

Maintenant, pour ce qui est du refresh, je vais mener une autre expérience. Actuellement, nous avons un drift : 3 réplicas au lieu de 2 sont présents sur le cluster. Je vais donc supprimer la réplique en trop et lancer un refresh. Je m'attends à ce que cela mette à jour les connaissances d'Argo CD sur l'état du cluster sans avoir à attendre les 3 minutes pour la boucle de réconciliation.

Nous obtenons les logs suivants :

```md
time="2026-10-11T18:08:37Z" level=info msg="Refreshing app status (comparison expired, requesting refresh. reconciledAt: 2026-10-11 18:05:46 +0000 UTC, expiry: 2m0s), level (2)" app-namespace=argocd application=monitoring project=default

time="2026-10-11T18:08:37Z" level=info msg="Ignore status for all objects"

time="2026-10-11T18:08:37Z" level=info msg="Comparing app state (cluster: https://Kubernetes.default.svc, namespace: argocd)" app-namespace=argocd application=monitoring project=default

time="2026-10-11T18:08:38Z" level=info msg="GetRepoObjs stats" app-namespace=argocd application=monitoring build_options_ms=0 manifests_ms=777 plugins_ms=0 project=default repo_ms=0 time_ms=777

time="2026-10-11T18:08:38Z" level=info msg="Updated sync status: OutOfSync -> Synced" application=monitoring dest-namespace=argocd dest-server="https://Kubernetes.default.svc" reason=ResourceUpdated type=Normal

time="2026-10-11T18:08:38Z" level=info msg="Update successful" app-namespace=argocd application=monitoring project=default

time="2026-10-11T18:08:38Z" level=info msg="Reconciliation completed" app-namespace=argocd app_status_update_ms=0 application=monitoring auto_sync_ms=0 compare_app_state_ms=877 comparison-level=2 comparison_with_nothing_ms=0 dedup_ms=2 dest-name= dest-namespace=argocd dest-server="https://Kubernetes.default.svc" diff_ms=90 git_ms=778 health_ms=3 live_ms=1 normalize_application_ms=1 patch_ms=58 persist_app_status_ms=68 process_finalizers_ms=0 project=default refresh_app_conditions_ms=0 set_app_managed_resources_ms=46 setop_ms=0 settings_ms=1 sync_ms=0 time_ms=994

time="2026-10-11T18:08:38Z" level=info msg="Refreshing app status (controller refresh requested), level (1)" app-namespace=argocd application=monitoring project=default

time="2026-10-11T18:08:38Z" level=info msg="Ignore status for all objects"

time="2026-10-11T18:08:38Z" level=info msg="Comparing app state (cluster: https://Kubernetes.default.svc, namespace: argocd)" app-namespace=argocd application=monitoring project=default

time="2026-10-11T18:08:39Z" level=info msg="GetRepoObjs stats" app-namespace=argocd application=monitoring build_options_ms=0 manifests_ms=62 plugins_ms=0 project=default repo_ms=0 time_ms=62

time="2026-10-11T18:08:39Z" level=info msg="No status changes. Skipping patch" app-namespace=argocd application=monitoring project=default

time="2026-10-11T18:08:39Z" level=info msg="Reconciliation completed" app-namespace=argocd app_status_update_ms=0 application=monitoring auto_sync_ms=0 compare_app_state_ms=79 comparison-level=1 comparison_with_nothing_ms=0 dedup_ms=2 dest-name= dest-namespace=argocd dest-server="https://Kubernetes.default.svc" diff_ms=3 git_ms=63 health_ms=6 live_ms=1 normalize_application_ms=3 patch_ms=0 persist_app_status_ms=1 process_finalizers_ms=0 project=default refresh_app_conditions_ms=0 set_app_managed_resources_ms=33 setop_ms=0 settings_ms=1 sync_ms=0 time_ms=117
```

Les logs obtenus sont très intéressants. Déjà, contrairement à ce à quoi je m'attendais, le refresh s'est lancé seul, ici aussi quelques secondes seulement après avoir réduit le nombre de répliques. Nous pouvons déjà voir une première demande de refresh. Ce refresh correspond à notre boucle de réconciliation. On peut voir que la dernière réconciliation datait de 18 h 05. Trois minutes plus tard, à 18 h 08, Argo CD demande un refresh et détecte que notre drift n'est plus présent en effectuant la comparaison « Comparing app state ». Notre application passe donc de `OutOfSync` à `Synced`. Ensuite, nous pouvons voir un deuxième refresh, mais cette fois-ci demandé par le contrôleur. En l'état des choses, je ne sais pas pourquoi le contrôleur a demandé un refresh (à investiguer). Peut-être parce que notre application a changé d'état et que ce refresh demandé explicitement sert de garde-fou ?

> **N. B. :** Le délai de 3 minutes entre chaque réconciliation est spéculatif. Je n'ai actuellement aucune preuve concrète, hormis mes observations dans les logs ; cela reste donc une piste à creuser dans les prochains labs.

Nous pouvons conclure qu'Argo CD a bien observé l'état du cluster. En ramenant moi-même le nombre de réplicas au nombre voulu, j'ai permis à Argo CD de constater que l'application était de nouveau conforme à l'état désiré. Il est également essentiel de noter que `Sync` n'est pas équivalent à `Refresh`. Malheureusement, je n'ai pas pu vraiment le prouver par ces expériences. Cependant, nous pouvons établir un tableau récapitulatif (j'essaierai, dans de futurs labs, de vérifier tout cela !) :

| Mécanisme | Rôle                                                                                                                                                                 |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Refresh   | Actualiser ou recalculer l'état connu par Argo CD, récupérer les manifests désirés si nécessaire, comparer l'état désiré à l'état réel et mettre à jour les statuts. |
| Sync      | Appliquer les changements nécessaires au cluster pour rapprocher les ressources réelles des manifests désirés.                                                       |
| Auto-sync | Déclencher une synchronisation automatiquement lorsque les conditions sont réunies et que l'application est `OutOfSync`.                                             |
| Self-heal | Permettre à l'auto-sync de corriger les écarts dus aux modifications faites directement dans le cluster, sous les conditions prévues par Argo CD.                    |
| Prune     | Autoriser la suppression des ressources suivies qui ne sont plus présentes dans la configuration désirée, lorsque la synchronisation le prévoit.                     |

(_Note: l'ensemble des labs annoncés au départ ne sera pas présent dans un seul document, mais plutôt dans une série de documents postés au fil des jours... et surtout si j'ai le temps !_)
