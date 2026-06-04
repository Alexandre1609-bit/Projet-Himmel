# Devlog 13: Implémentation de la sécurité (partie 1)

La stack d'observabilité étant en grande partie déployée, j'ai décidé de m'attaquer à la sécurité et de commencer à appliquer les principes _shift-left_ ainsi que le zéro privilège. Dans ce devlog, je vais revenir sur l'implémentation d'Alertmanager, de Slack, de la gestion des secrets, des règles Kyverno, et sur des choix techniques auxquels j'ai été confronté. Ce devlog marque le début de la phase de "sécurité" du cluster et en constitue la première partie.

## 1. Alertmanager

Alertmanager était déjà implémenté dans le cluster via la stack **kube-prometheus-stack** et n'attendait qu'à être configuré. Cela s'est fait naturellement après la fin du déploiement de la stack d'observabilité. Afin de mieux comprendre **Alertmanager**, j'ai décidé de créer une chaîne d'alerte. Cette chaîne est définie de la manière suivante :

Métriques **Prometheus** -> Règles **Alertmanager** -> Alerte détectée -> Canal **Slack** dédié.

Dans l'optique de comprendre le principe même d'Alertmanager, j'ai créé un canal Slack dédié aux alertes.
J'ai commencé par définir deux règles simples : l'une vérifie le taux d'utilisation de la mémoire et l'autre le taux d'utilisation du CPU.
Ces règles sont écrites en **PromQL**, le langage de requête de Prometheus. La syntaxe m'apparaît assez intuitive, mais les noms des métriques sont parfois complexes et difficiles à retenir. Voici un exemple d'une de mes règles :

```yaml
- name: check-memory-usage
  rules:
    - alert: HighMemoryUsage
      expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 60
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Memory usage > 60% detected"
```

Cette règle surveille si le taux d'utilisation de la mémoire de mes nœuds n'excède pas 60 %. Si l'utilisation est supérieure à 60 % pendant au moins 2 minutes, une alerte est déclenchée. L'alerte est ensuite récupérée par Prometheus (_via ses CRDs_). Le fichier de configuration d'**Alertmanager** se trouve dans mon fichier **prometheus-values** (_k8s/apps/helm-values_), qui est lui-même injecté dans mon application **ArgoCD** via **valueFiles**. Ce fichier fait office de configuration des alertes et contient diverses informations, dont les **receivers**.

Les **receivers** définissent la destination d'envoi de l'alerte (mail, Slack, Teams, Discord...). Dans mon cas, j'ai décidé d'opter pour des alertes envoyées sur Slack, car cela me semble être le choix le plus courant et pertinent en entreprise. Autrement dit, j'essaie de m'adapter et d'utiliser les technologies du monde professionnel afin d'assimiler les _best practices_ dès le début.

Mon **receiver** Slack se présente de la manière suivante :

```yaml
receivers:
  - name: "null"

  - name: "slack"
    slack_configs:
      - api_url_file: /etc/alertmanager/secrets/slack-whook/api_url
        channel: "#alerts"
        send_resolved: true
```

Plusieurs points sont intéressants ici. Tout d'abord, les alertes sont envoyées dans le channel **"#alerts"**. Nous y retrouverons toutes les alertes de sévérité **critical**. J'ai fait ce choix pour ne pas polluer le channel avec des alertes "non dangereuses". De plus, l'URL du webhook Slack n'est pas codée en dur (hardcodée) ; elle est passée via un volume de type _secret_ monté dans le conteneur.

Voici un extrait de mon canal **"#alerts"** Slack :

```text
[FIRING:3] HighCpuUsage (prometheus/prometheus-kube-prometheus-prometheus critical)[14 h 41]
[FIRING:3] HighMemoryUsage (node-exporter http-metrics node-exporter prometheus prometheus/prometheus-kube-prometheus-prometheus prometheus-prometheus-node-exporter critical)[14 h 41]
[FIRING:1] KubeProxyDown (kube-proxy prometheus/prometheus-kube-prometheus-prometheus critical)
```

Comme nous pouvons le voir ici, les alertes ont bien atteint **Slack** et sont bien des alertes **critical**, comme établi dans mon manifeste.

_(Nb : L'alerte KubeProxyDown est tout à fait normale. KubeProxy est désactivé sur mon cluster, comme recommandé pour l'installation du CNI Cilium)._

## 2. Bitnami Sealed Secrets

Je me suis retrouvé confronté à un problème de taille : **comment commiter du code sensible sur Git sans l'exposer publiquement ?** J'y ai réfléchi et j'ai dégagé 3 approches différentes :

- **Approche 1 :** La première consistait à commiter la valeur hardcodée. Le cluster (et par extension ce projet) étant personnel et non dédié au grand public, cela semblait envisageable. Le compte Slack et les _credentials_ utilisés sont d'ailleurs "jetables". Cependant, cette approche me dérangeait car elle ne correspond ni à la rigueur que je souhaite m'imposer, ni aux standards professionnels. J'ai donc abandonné cette idée.

- **Approche 2 :** Une solution plus cohérente consistait à gérer les secrets via un second fichier. Pour ce faire, je définissais des variables `${}` dans le fichier à commiter, et je conservais un second fichier non commité (inclus dans le `.gitignore`) contenant les valeurs réelles. Cette approche est tout à fait viable, et j'ai longuement hésité, car elle demande très peu de ressources et semble cohérente pour un _homelab_ d'apprentissage. Toutefois, ce n'est toujours pas la direction professionnelle que je souhaite donner à ce laboratoire. J'ai donc également écarté cette option.

- **Approche 3 :** L'approche la plus robuste que j'ai trouvée en me renseignant est **Bitnami Sealed Secrets**. À première vue, cela me paraissait complexe à implémenter, mais après avoir lu la documentation et visionné quelques tutoriels, cela s'est avéré plus simple que prévu, en plus d'être extrêmement fiable. **Sealed Secrets** permet la création d'une ressource `kind: SealedSecret` encodée, plus précisément via **un chiffrement asymétrique** (_la clé publique sert à chiffrer le secret, tandis que la clé privée est uniquement détenue par le contrôleur sur le cluster_). Ce fichier, qui contient la donnée sensible chiffrée, peut ensuite être poussé dans nos manifestes et monté (dans mon cas via `api_url_file: /etc/alertmanager/secrets/slack-whook/api_url`). Grâce à cette méthode, je peux commiter mon fichier secret chiffré sur Git sans aucune crainte. Le secret est ensuite déchiffré localement sur le cluster par le contrôleur Sealed Secrets. J'ai adopté cette approche car elle est robuste et parfaitement alignée avec le niveau technique que je souhaite atteindre.

- **Approche 4 (Piste de réflexion) :** L'idée de passer par un outil externe comme **Vault** m'a aussi traversé l'esprit. Vault permet une gestion des secrets externe au cluster et apporte une couche de sécurité supplémentaire. Le petit bémol avec Sealed Secrets est que je dois conserver localement un fichier non commité avec mes secrets en clair (_du moins encodés en base64_) pour générer les secrets scellés. Bien que robuste, cela ne me satisfait pas encore à 100 %. L'implémentation de Vault étant pour le moment trop complexe et chronophage, j'ai décidé de la mettre de côté pour y revenir plus tard, lorsque le cluster sera plus mature.

## 3. Règles Kyverno

Dans la continuité, je me suis attaqué à **Kyverno**. Jusqu'à présent, Kyverno était installé sur le cluster mais ne possédait aucune règle définie. J'ai implémenté 5 règles de base afin de durcir la sécurité.

J'ai rencontré divers obstacles lors de l'implémentation. En effet, Kyverno a récemment subi une modification majeure de sa syntaxe YAML. De nombreuses ressources d'apprentissage, ainsi qu'une partie de la documentation et des tutoriels, utilisaient encore l'ancienne ressource dépréciée `ClusterPolicy`. Fort heureusement, la documentation officielle, globalement à jour, m'a accompagné dans la rédaction de mes règles. La nouvelle syntaxe basée sur les expressions **CEL** (Common Expression Language) me semble plus intuitive et se rapproche de ce que l'on retrouve en Python ou d'autres langages de programmation.

Concrètement, ces règles consistent à restreindre les privilèges des **containers** et **initContainers**, et à exiger la présence de labels spécifiques (comme `env`, `prod`, `team`).

En surface, cela semblait simple, mais je me suis vite rendu compte que je m'étais engagé dans un véritable labyrinthe. Restreindre les privilèges sur les ressources telles que les `pods`, `deployments`, `daemonsets`, `statefulsets`, `jobs` et `cronjobs` allait poser un problème d'envergure. Qu'en est-il lorsqu'un outil de sécurité ou réseau comme **Falco** ou **Cilium** a légitimement besoin du mode **privileged** pour fonctionner ?

Au premier abord, cela m'apparaissait insoluble, et la solution ne figurait pas dans la section principale de la documentation. En fouillant un peu, j'ai fini par découvrir la ressource `kind: PolicyException`, qui correspondait exactement à mon besoin. Grâce à cette exception :

```yaml
apiVersion: policies.kyverno.io/v1alpha1
kind: PolicyException
metadata:
  name: exclude-skipped-deployment
  namespace: default
spec:
  policyRefs:
    - name: deny-allow-privileged-mode
      kind: ValidatingPolicy
  matchConditions:
    - name: is-infra-namespace
      expression: "object.metadata.namespace in ['cilium-system', 'falco']"

    - name: is-infra-agent
      expression: "object.metadata.name.startsWith('cilium') || object.metadata.name.startsWith('falco')"
```

J'ai pu autoriser les ressources des applications **Cilium** et **Falco** à contourner l'interdiction de privilèges pour fonctionner correctement, le tout sans avoir à affaiblir la sécurité globale établie dans mes `ValidatingPolicy`. Permettre uniquement à certaines ressources, certains pods ou conteneurs de contourner cette règle offre une meilleure granularité et un filtrage plus fin des exceptions. Cela renforce la sécurité, évitant ainsi d'avoir à exempter des **namespaces** dans leur globalité.

## 4. Concepts appris

- **Gestion des secrets :** En expérimentant l'injection de secrets pour mon webhook Slack, j'ai appris qu'il n'était pas sécurisé (ni toujours possible nativement) d'injecter des secrets en clair directement via les valeurs d'une charte **Helm**.

- **PromQL :** Bien que je n'aie établi que deux règles simples pour le moment, cela m'a permis de me familiariser avec la syntaxe **PromQL**, que j'avais déjà aperçue dans la configuration des panels de mes dashboards **Grafana**.

- **Bitnami Sealed Secrets :** J'ai appris à gérer les secrets de manière professionnelle et robuste via **Sealed Secrets**, une approche GitOps fiable et reconnue dans l'industrie.

- **Policies Kyverno :** J'ai assimilé la nouvelle syntaxe **CEL** implémentée dans Kyverno et j'ai déployé mes premières **policies** d'admission via des manifestes YAML.

- **Remise en question :** J'ai renforcé ma capacité d'analyse en apprenant à toujours remettre en question mes choix initiaux. Que ce soit en consultant des forums, en visionnant des tutoriels ou en utilisant l'IA, chercher des solutions plus robustes et professionnelles est une étape essentielle de mon apprentissage.

- **Privileged et allowPrivilegeEscalation :**
  - _Privileged: true :_ C'est l'option la plus critique, car les isolations de sécurité sont presque toutes désactivées. Le conteneur ou le pod concerné obtient presque les mêmes droits que l'administrateur (_root_) du serveur physique sur lequel il tourne. Le conteneur peut voir et modifier le réseau hôte, accéder aux disques durs physiques (_/dev_), interagir directement avec le noyau Linux... Cela revient à donner les clés de notre maison à un invité.

  - _allowPrivilegeEscalation: true :_ Ce paramètre est plus subtil, moins direct. Il contrôle un drapeau spécifique du noyau Linux (_NO_NEW_PRIVS, qui gère les bits setuid/setgid et les capabilities de fichiers_). Il s'applique aux processus à l'intérieur du conteneur. Si cette option est sur **true**, un processus enfant a le droit d'obtenir plus de privilèges (ou droits) que son processus parent. Un conteneur initialement **non-root** peut ainsi devenir **root** via des programmes mal configurés ou vulnérables.
