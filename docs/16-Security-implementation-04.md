# Devlog 16: Implémentation de la sécurité (partie 4)

Après le déploiement de ma première pipeline CI (_cf: devlog 15_) j'ai décidé de mettre en "pause" le déploiement d'outil supplémentaire. À la place je m'attaque à la profondeur, je configure les outils déjà implémentés, je comprends leur fonctionnement et j'essaie d'améliorer ce qui est déjà présent. Dans la continuation de cette démarche je me suis attaqué à **Cilium** et **Falco**. Je n'avais pas encore eu l'occasion d'approfondir ces deux outils, pourtant cruciaux pour le cluster. J'ai commencé par Falco en implémentant des règles personnalisées. Ensuite j'ai exploré les NetworkPolicies de Cilium. Je reviendrai dans ce devlog sur les points appris, les concepts découverts, les expériences menées et comment j'ai pu / comment je vais pouvoir résoudre les problèmes rencontrés.

## 1. Pourquoi ?

Depuis le début du projet Himmel, j'ai eu l'occasion de découvrir, d'apprendre pas mal d'outils (Observabilité, Sécurité, Provisioning...). Jusqu'à présent je me concentrais sur l'ajout de nouvelles fonctionnalités. J'ai déjà implémenté, personnalisé des outils, comme Kyverno, Prometheus, Grafana... mais il me restait des outils **non explorés**. C'est à partir de cette réflexion que j'ai décidé de commencer à en apprendre plus sur les outils déjà déployés que d'en ajouter de nouveaux. Dans cette optique, j'ai pu consolider mes connaissances sur Falco et Cilium en implémentant des règles personnalisées à Falco et en commençant les labs **Isovalent** pour Cilium, et en déployant ma première NetworkPolicy. Les prochains devlogs porteront donc sur l'approfondissement des outils déjà présents, et sur la configuration, plus en détail, de ces derniers.

## 2. Règles Falco

Falco est implémenté depuis les débuts du cluster mais n'avait pas encore de règles personnalisées. Au premier abord cela semblait imposant, **syscall**, monitoring m'apparaissait inatteignable. Cependant en lisant la documentation j'ai réalisé que la syntaxe était plutôt intuitive. À partir de là j'ai commencé la création de 3 règles personnalisées afin de saisir la syntaxe de base de Falco.

Parmi ces trois règles on retrouve une règle indispensable : la surveillance de shell dans un conteneur.

```yaml
 - rule: shell_in_container
      desc: check for any shell activity within a container
      condition: >
        evt.type in (execve, execveat) and
        container.id != host and
        proc.name in ("bash", "ksh")
      output: >
        shell in a container detected |
        user=%user.name container_id=%container.id container_name=%container.name
        shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline
      priority: ALERT
```

J'ai créé cette première règle en m'inspirant de la documentation afin de saisir la syntaxe et de pouvoir tester, plus tard, si mes règles fonctionnent, sans compter sur celles définies par défaut.

J'ai ensuite pris un peu plus de liberté, j'ai imaginé deux autres règles, le but pour le moment n'étant pas d'avoir des règles exigeantes, j'ai créé ces deux autres règles :

- première règle:

```yaml
- rule: deny_nmap
  desc: deny nmap scan in a container
  condition: >
    evt.type == execve and
    container.id != host and
    proc.name == "nmap"
  output: >
    Network scan detected |
    user=%user.name container_id=%container.id container_name=%container.name
    shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline
  priority: WARNING
```

Cette règle a pour objectif de détecter si des scans **nmap** sont lancés dans un conteneur. L'objectif ici était d'explorer les syscall via la documentation Linux, rechercher si un script, un binaire exécutait le même syscall qu'un shell... toujours dans l'optique de comprendre le "flow" classique d'une règle.

- deuxième règle:

```yaml
- rule: read_etc_shadow
  desc: check for any consultation of /etc/shadow
  condition: >
    evt.type in (open, openat, openat2) and
    container.id != host and
    fd.name == "/etc/shadow"
  output: >
    /etc/shadow read |
    user=%user.name container_id=%container.id container_name=%container.name
    path:%fd.name
  priority: WARNING
```

Enfin cette dernière règle surveille s'il y a une consultation du fichier shadow dans le dossier /etc. Falco, par défaut, a une règle qui avertit quand le dossier `/etc/` est consulté "_Warning Sensitive file opened for reading by non-trusted program_", cependant j'ai voulu essayer d'implémenter et de découvrir d'autres syscall "de base".

### Test des règles

Afin de vérifier si mes règles fonctionnaient correctement j'ai décidé de déployer une application simple : un conteneur _nginx_. Le but était d'exécuter des commandes dans ce conteneur via un shell obtenu via _kubectl exec_ et de vérifier si mes règles répondaient bien.

Tout d'abord j'ai pu observer que ma première règle fonctionnait correctement :

`12:01:11.787655396: Alert shell in a container detected | user=root container_id=f5ced295d0ed container_name=nginx shell=bash parent=bash cmdline=bash container_id=f5ced295d0ed container_name=nginx container_image_repository=docker.io/library/nginx container_image_tag=1.14.2 k8s_pod_name=nginx-deployment-b995944fb-gxbpx k8s_ns_name=nginx`

Cette règle s'est déclenchée au moment où j'ai exécuté la commande "_kubectl exec_". Le shell s'est lancé et ma règle a détecté le syscall dans le conteneur.

Aussi, pour la règle de consultation du fichier _/etc/shadow_, elle n'est pas apparue. C'est la règle Falco implémentée par défaut qui a pris le dessus :

`Warning Sensitive file opened for reading by non-trusted program | file=/etc/shadow gparent=containerd-shim ggparent=systemd gggparent=<NA> evt_type=open user=root user_uid=0 user_loginuid=-1 process=cat proc_exepath=/bin/cat parent=bash command=cat shadow terminal=34817 container_id=f5ced295d0ed container_name=nginx container_image_repository=docker.io/library/nginx container_image_tag=1.14.2 k8s_pod_name=nginx-deployment-b995944fb-gxbpx k8s_ns_name=nginx`

Puis pour ce qui est de la dernière règle je n'ai pas pu vérifier directement car le binaire **nmap** n'est pas installé par défaut dans mon conteneur.

Enfin pour ce qui est de l'observabilité, mon dashboard Falco a pu repérer les syscall et les règles implémentées, donc même si ma seconde règle n'était pas visible, le dashboard, lui, l'a bien détecté !

![Alt](docs/images/system/Falco/falco_detection_dashboard.png)

# 3. Cilium NetworkPolicy

Après avoir attaqué les deux premiers labs d'introduction à Cilium (_disponible gratuitement sur https://labs-map.isovalent.com/_) j'ai décidé de me lancer et d'implémenter ma première L3 NetworkPolicy. L'objectif était simple : limiter le trafic entrant et sortant aux plages IP privées afin de rendre l'accès possible uniquement aux utilisateurs connectés à ma box internet. De là a découlé une pensée simple : _"je n'ai qu'à sélectionner les CIDR concernés en ingress et egress"_. Mais je ne m'attendais pas à rencontrer autant de problèmes et à découvrir autant de choses ! Tout d'abord voici la règle de base :

```yaml
---
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "restrict-communication-nginx-app"
  namespace: nginx
spec:
  endpointSelector:
    matchLabels:
      app: nginx
      env: prod
  ingress:
    - fromEndpoints:
        - {}
    - fromCIDRSet:
        - cidr: "192.168.0.0/16"
  egress:
    - toCIDRSet:
        - cidr: "192.168.0.0/16"
    - toEndpoints:
        - {}
```

Comme dit précédemment l'objectif ici était trivial : on autorise la plage IP **192.168.0.0/16** en entrée et en sortie, en plus d'autoriser les **endPoints** (les pods, conteneurs...) à communiquer entre eux. C'est lorsque j'ai déployé cette règle que j'ai réalisé que ça ne passait pas. En me renseignant j'ai fait plusieurs découvertes aussi intéressantes les unes que les autres :

- Kubernetes utilise un **SNAT**, _source network address translation_, jusque là je connaissais le principe du NAT : statique, dynamique, PAT... mais je n'avais pas encore rencontré de SNAT. Après investigation j'ai appris que lorsqu'une requête en 192.168.x.x atteint le nœud du cluster, Kubernetes (via l'architecture par défaut du NodePort) remplace physiquement mon adresse IP par une IP interne (ex : 10.0.0.250).

De plus, Cilium attribue à ce trafic l'identité globale **world**. Mon pod Nginx ne voit donc jamais l'IP d'origine, mais uniquement une IP en 10.x.x.x **taguée** comme world. La règle CIDR locale était donc systématiquement contournée et le trafic était droppé.

### Essai de contournement

J'ai essayé et pensé plusieurs solutions afin de pouvoir contourner le SNAT :

1. L'autorisation des deux plages IP :
   L'idée : ajouter la plage du proxy (10.0.0.0/8) en plus de ma plage locale dans le **fromCIDRSet**.

   Résultat : échec.

   Pourquoi ? Dans Cilium, l'identité **forte** (world) attribuée au paquet par eBPF écrase et invalide les simples filtres d'adresses IP brutes **fromCIDRSet**.

2. La combinaison avec l'identité world
   L'idée : autoriser l'entité **world** en ingress pour débloquer le trafic et limiter le trafic en egress avec les **CIDRSet** dans une même règle.

   Résultat : fonctionne, mais cela détruit l'objectif de ma politique.

   L'entité world englobant tout l'univers extérieur, j'ouvrais la porte à n'importe quelle connexion en dehors de mon réseau local. (**Annexe 1**)

3. La stratégie à deux règles séparées (OU vs ET)
   L'idée : créer deux règles distinctes pour tenter de forcer une condition (autoriser world ET contraindre avec le CIDRSet).

   Résultat : échec.

   Pourquoi ? Les NetworkPolicies dans Kubernetes sont purement additives. Elles fonctionnent avec une logique inclusive "OU" (OR). Avoir une règle qui autorise tout le monde annule automatiquement la règle qui restreint.

![Alt](docs/images/system/Cilium/first_hubble_logs.png)

### Solutions envisagées

1. Passer par un **Gateway API**, cependant ne connaissant pas encore tous les détails, et manquant d'expérience, j'ai décidé de mettre cette solution de côté et de me renseigner de manière passive.

2. Il faut changer la politique de trafic externe du **Service** pour lui interdire de masquer l'IP d'expéditeur.

En appliquant ce paramètre dans le YAML du Service :

```YAML
spec:
  externalTrafficPolicy: Local
```

De cette manière, le noeud Kubernetes transfère le paquet au pod en **préservant** la véritable IP 192.168.x.x. Hubble affichera enfin l'identité locale, et la Network Policy (sans world, sans plage 10.x.x.x) deviendra instantanément fonctionnelle. Cependant, je n'envisage pas cette solution car cela reviendrait à supprimer la disponibilité de mon application en la limitant à un seul pod. Par défaut, un NodePort expose son port sur l'ensemble des adresses IP des noeuds du cluster et est donc accessible via n'importe quelle IP d'un noeud.

# 4. Annexes

- Annexe 1: Le pare-feu de Cilium est Stateful. Puisque la connexion a été validée à l'entrée, Cilium mémorise la session, via son système d'identité, attribuée à l'entrée, et laisse sortir la réponse automatiquement sans lire tes restrictions d'Egress.
