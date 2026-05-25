# Journal d'avancement - Fix et prise en main des dashboards : dashboards Cilium et Kubernetes View

Ce douzième devlog marque la fin de la phase "dashboard" du cluster. Les devlogs précédents _(nb : 09 à 11)_ traitaient du déploiement de la stack d'observabilité, ainsi que de l'import et de la configuration des dashboards. Il y a actuellement trois dashboards déployés sur le cluster : Falco, Cilium et Kubernetes View. Importer les dashboards n'était que le début; j'ai rencontré pas mal de problèmes de datasource ainsi que des erreurs de type "no data". Je revenais sur ces problèmes dans le dernier devlog (numéro 11) dédié à Falco. Ce devlog-ci traitera les problèmes rencontrés pour l'affichage des métriques de Cilium récupérées via Prometheus, ainsi que de la correction de deux panels (CPU et memory usage) du dashboard Kubernetes View.

## 1. Fix des deux panels du dashboard Kubernetes View

- **CPU et Memory usage :** Le dashboard utilisé (gnetId : 15757) exploitait les métriques `container_cpu_usage_seconds_total{id="/"}` et `container_memory_working_set_bytes{id="/"}`. Après investigation, j'ai appris que ces métriques provenaient de **cAdvisor** et ciblaient le cgroup racine. Le cgroup racine étant absent, cela empêchait les métriques de fonctionner et générait des **"no data"** sur mon dashboard. Afin de pallier cela, j'ai dû remplacer ces métriques par des métriques **node-exporter** compatibles : `node_cpu_seconds_total{mode!="idle"}` ainsi que `node_memory_MemTotal_bytes` et `node_memory_MemAvailable_bytes`. Une fois le remplacement effectué, les métriques apparaissent normalement dans le dashboard Kubernetes View.

- **Migration gnetId vers ConfigMap :** Afin de garder une architecture homogène, j'ai décidé de remplacer l'importation du dashboard via gnetId par une importation par **ConfigMap** _(cf. devlog 11 : mode d'importation du dashboard Falco)_. J'ai donc supprimé le gnetId et le provisionnement du dashboard dans mon application Grafana ArgoCD afin de le remplacer par un ConfigMap dans `"k8s/manifests/grafana/dashboard_prometheus.yaml"`. Le dashboard est ensuite provisionné via un sidecar se trouvant dans l'application ArgoCD de Grafana.

## 2. Fix du dashboard Cilium

- **Migration vers ConfigMap :** Comme pour les dashboards de Falco et de Kubernetes View, j'ai décidé de supprimer l'importation via gnetId et de privilégier l'importation via ConfigMap. J'ai utilisé le même procédé que pour les deux autres dashboards en créant un manifeste Cilium situé dans `"k8s/manifests/grafana/cilium-dashboard.yaml"`.

- **Patch du JSON :** Le dashboard utilisé est celui portant le gnetId "16611". Lors de l'analyse du dashboard, je me suis rendu compte que de nombreux panels étaient dupliqués. Une fois le nettoyage effectué, j'ai dû procéder à d'autres modifications comme le remplacement des `uid: ...` par `uid: *PBFA97CFB590B2093` afin de résoudre le problème "no datasource were found". De plus, il y avait beaucoup de caractères orphelins (ex : `{`, `]`...). À cause de cela, Grafana rejetait silencieusement le fichier. J'ai pu détecter tout cela via la commande `kubectl logs`, qui m'a remonté de nombreuses erreurs de type `invalid character '}' after array element`. J'ai ensuite localisé les éléments défectueux précis avec la commande `python3 -c "import json; json.load(...)"` qui me retournait le numéro de ligne exact.

- **Problème de "no data" persistant :** Bien que le JSON était patché, les métriques n'apparaissaient toujours pas et les **"no data"** persistaient. Après investigation, je me suis rendu compte que les requêtes (_queries_) de mes panels pointaient vers `k8s_app="cilium"`. Cependant, mes métriques Cilium n'avaient pas ce label, ce qui rendait impossible leur récupération. J'ai remplacé, via une commande `sed`, l'entièreté des occurrences de `k8s_app="cilium"` par `job="prometheus/cilium-agent"` dans mon fichier JSON. Une fois cette modification faite, les métriques se sont correctement affichées sur le dashboard, confirmant que la récupération s'effectue correctement.

## 3. Concepts appris

- **Cgroup (Control Group) :** Gère l'allocation et la limitation des ressources (CPU, mémoire, etc.) pour les différents processus.

- **rate() (PromQL) :** Transforme un compteur monotone en un taux par seconde calculé sur une fenêtre temporelle (ex : `[5m]`).

- **-o (flag kubectl) :** `--output`, permet de changer le format de sortie (`wide`, `yaml`, `json`, `jsonpath`). Attention, ces formats sont exclusifs (un seul format à la fois).

- **Deployment vs DaemonSet vs StatefulSet :**
  - _Deployment_ : pods stateless et mobiles.
  - _DaemonSet_ : garantit la présence d'un pod par nœud.
  - _StatefulSet_ : pods avec une identité et un stockage stables.

- **Application ArgoCD vs ressource Kubernetes :** L'Application ArgoCD est l'abstraction et le modèle de déploiement (GitOps), tandis que le _Deployment_/_DaemonSet_/_StatefulSet_ représente les ressources réelles qui s'exécutent sur le cluster.

- **sed (Stream Editor) :** Outil en ligne de commande pour le traitement de texte. La commande utilisée était **"sed -i 's|k8s_app=\\"cilium\\"|job=\\"prometheus/cilium-agent\\"|g' cilium-dashboard.yaml"**. Cette commande m'a permis de modifier un fichier en place avec le flag **-i** (ici _cilium-dashboard.yaml_). L'utilisation du délimiteur **"|"** à la place de **"/"** m'a permis d'inclure facilement les chaînes contenant des slashes (comme _prometheus/cilium-agent_) dans le texte de remplacement sans casser la syntaxe. Le flag **g** final applique le remplacement à toutes les occurrences de chaque ligne.
