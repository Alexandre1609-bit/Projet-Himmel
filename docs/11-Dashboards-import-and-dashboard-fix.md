# Journal d'avancement - Import des dashboards Falco et Hubble, fix et exploration des dashboards

Pour faire suite au déploiement de la stack d'observabilité et du dashboard Prometheus via Grafana, j'ai décidé d'ajouter deux dashboards supplémentaires, ceux de _Falco_ & _Cilium_. Dans ce devlog numéro 11, je reviendrai principalement sur les problèmes que j'ai pu rencontrer avec le dashboard de _Falco_. Je finirai par les concepts révisés et appris.

## 1. Problèmes rencontrés et solutions apportées

_Contexte : Le dashboard Falco importé via `gnetId: 24354` dans la chart Helm de Grafana n'affichait aucune métrique, uniquement "No Data", malgré un scraping correct de Prometheus._

- **Variables non définies :** Le dashboard utilisé contenait deux variables : **${DS_PROMETHEUS}** et **${PROMETHEUS-DATA-SOURCE}**. Le problème était que ces variables n'étaient pas définies dans la section **templating** du JSON. À cause de cela, le dashboard n'avait pas accès à la **datasource** de Prometheus et ne pouvait pas récupérer les métriques. Étant donné que j'importe le dashboard depuis la chart Helm de Grafana et que Grafana ne résout pas les variables automatiquement lors d'un import via **gnetId**, je ne pouvais pas sauvegarder les changements manuels (injection des variables dans **templating**) directement depuis le portail Grafana. Afin de sauvegarder les changements apportés, j'ai dû supprimer l'import via **gnetId** dans la chart Helm et utiliser un **ConfigMap** personnalisé à la place. Ce **ConfigMap** reprend le JSON d'origine du dashboard 24354 mais intègre les changements apportés dans la section **templating**.

- **Métrique inexistante :** En explorant le dashboard, j'ai constaté qu'il récupérait la métrique **"falcosecurity_falco_rules_matches_total"** mais qu'elle n'était pas scrapée par Prometheus lors d'une query sur son API. J'avais pourtant ajouté `metrics: enabled: true` dans mon application Falco. En consultant la documentation officielle de Falco sur la page _"metrics"_, j'ai découvert qu'il fallait également ajouter `rules_counters_enabled: true` dans la configuration de l'application. En activant uniquement les métriques, Falco génère ses règles mais il n'expose pas les compteurs de déclenchement. Ces compteurs ne sont créés que lorsqu'une règle Falco se déclenche suite à un comportement suspect détecté.

- **Double scraping :** En enquêtant sur les problèmes du dashboard, je me suis rendu compte que Prometheus scrapait deux fois les mêmes métriques. Deux **ServiceMonitors** étaient actifs simultanément : **"serviceMonitor/falco/falco"** et **"serviceMonitor/prometheus/falco"**, tous les deux ciblant les mêmes pods. Cela était dû à la création d'un manifest **ServiceMonitor** dans mon application Falco, qui s'ajoutait à celui de la chart Helm. Ce doublon faisait office de dead code, ne respectait pas le principe **DRY** et compromettait la sécurité du cluster. Afin de supprimer ce doublon, j'ai décidé de retirer le manifest présent dans **"k8s/manifest/falco/servicemonitor.yaml"** et de conserver uniquement celui de la chart Helm, rendant ainsi l'ensemble plus cohérent.

## 2. Concepts révisés et appris

- **ConfigMap :** Les ConfigMaps sont des objets Kubernetes qui stockent des fichiers de configuration et sont injectés dans les pods sous forme de volumes. _Comparable à des variables d'environnement, mais pour des fichiers entiers._

- **Sidecar pattern :** Un sidecar est un conteneur secondaire qui se trouve dans le même pod qu'un conteneur principal et qui effectue une tâche auxiliaire. (Dans mon cas : surveiller les ConfigMaps et les monter dans Grafana.)

- **Provisioning Grafana :** Un dashboard provisionné — c'est-à-dire déployé automatiquement via une configuration déclarative (ConfigMap, fichier YAML, etc.) plutôt que manuellement depuis l'UI — ne peut pas être modifié depuis l'interface Grafana. La "source de vérité" est toujours **Git**.

- **Variables de template Grafana :** `${NOM}` doit être défini dans **templating.list**, sans quoi aucun panel ne peut résoudre sa datasource.

- **Stale metrics :** Des métriques périmées provenant d'anciennes instances, qui expirent automatiquement dans Prometheus.

- **DaemonSet :** Une ressource Kubernetes qui garantit exactement un pod par nœud.

  ### Commandes
  - **`kubectl rollout restart daemonset/deployment <name> -n <namespace>`** : Redémarre proprement un Deployment ou un DaemonSet sans supprimer manuellement les pods.

  - **`kubectl get pods -n <namespace>`** : Liste les pods dans un namespace donné.

  - **`kubectl exec -n <namespace> <pod> -- <commande>`** : Exécute une commande directement dans un pod situé dans un namespace donné.

  - **`kubectl logs -n <namespace> <pod> -c <container>`** : Affiche les logs d'un conteneur situé dans un pod et un namespace donnés.

  - **`kubectl get servicemonitor -n <namespace>`** : Affiche les ServiceMonitors d'un namespace donné. Un ServiceMonitor est une ressource Kubernetes (introduite par l'opérateur Prometheus) qui définit comment Prometheus doit scraper les métriques d'un service.
