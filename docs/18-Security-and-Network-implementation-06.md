# Devlog 18 : Implémentation de la sécurité et implémentation réseau (partie 6)

Lors du dernier devlog, je revenais sur l'ajout de toute la partie exposition du cluster à internet, via les fondations nécessaires, donc le L2 announcement et l'IPAM par Cilium, mais aussi avec l'ajout de certificats auto-signés pour garantir le chiffrement des paquets via HTTPS. J'expliquais aussi mon premier véritable problème réseau que j'avais rencontré. Depuis, j'ai eu l'occasion d'améliorer le tout : le problème est corrigé, une nouvelle méthode de certification est en place et la gateway est fonctionnelle. Le cluster, ou du moins une application précise, est exposée publiquement sur Internet.

## 1. Gateway publique

J'ai enfin finalisé la gateway publique (une gateway privée fera suite) qui me permet la distribution de mes paquets d'Internet à mon cluster, le tout sécurisé via HTTPS. Outre le fait que cela règle le problème de SNAT (_cf. Devlog 16_), cette gateway et l'exposition de ma première application vont me permettre d'enfin pouvoir implémenter de véritables NetworkPolicies et de véritables règles Falco. Jusqu'à présent, le tout était testé en interne, les NetworkPolicies n'étaient pas implémentables car le SNAT me posait problème. Cette étape sera un vrai levier pour la suite, autant sur la sécurité que sur la maturité du cluster.

Cependant, il faut savoir que mettre en place tout ça ne fut pas une chose facile. J'ai tout d'abord dû chercher un moyen d'obtenir un nom de domaine qui pourrait héberger mon application. Après renseignement, je me suis tourné vers **DuckDNS**, une alternative largement connue et sûre, qui me permet de générer un nom de domaine en **duckdns.org** de manière gratuite et sécurisée. Il faut savoir que chaque compte DuckDNS vient avec un token, une donnée sensible. Pour que DuckDNS soit au courant de l'IP publique de ma box internet (_PAT, section dédiée après_), on doit lui faire des requêtes. J'ai décidé de déployer un **CronJob**.

```yaml
containers:
            - name: duckdns-curl
              image: curlimages/curl:8.21.0
              env:
                - name: DUCKDNS_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: dns-key
                      key: token
              command:
                - /bin/sh
                - -c
                - 'curl -s -m 10 "[https://www.duckdns.org/update?domains=#######&token=$](https://www.duckdns.org/update?domains=#######&token=$){DUCKDNS_TOKEN}&ip="'
          restartPolicy: OnFailure
```

Ce CronJob s'effectue toutes les 15 minutes et envoie une simple requête curl à mon nom de domaine pour que DuckDNS puisse mettre à jour l'IP de ma box automatiquement quand elle vient à changer. Cette alternative simple et facile d'implémentation permet de gérer le changement d'IP dynamique de ma box de manière automatique. Ainsi, je n'ai pas à me soucier de l'accessibilité de mon application si mon IP publique venait à changer.

## 2. Certificat

J'avais déjà implémenté un système de certificat auto-signé. Le principe était simple : j'avais un "certificat bootstrap", qui créait une ébauche de certificat, ensuite ce certificat se voyait signé par lui-même pour devenir un certificat "authentique". Le problème ici est qu'un certificat auto-signé ne vaut "rien", car on ne peut pas se prétendre sécurisé soi-même. Cette solution me permettait de tester localement si tout le flow HTTPS fonctionnait en interne, mais sur internet, avoir un "véritable" certificat est mieux. C'est pourquoi j'ai décidé de passer à un certificat signé par Let's Encrypt, une autorité de certification qui octroie des certificats TLS gratuitement. Pour ce faire, j'ai dû repenser mon implémentation. J'ai supprimé le certificat "bootstrap", à la place je passe par le serveur Let's Encrypt ACME, qui gère toute la partie création de certificat : `server: https://acme-v02.api.letsencrypt.org/directory`

Ensuite, il ne me reste plus qu'à créer le "véritable" certificat, qui reprend le template généré par Let's Encrypt, via un objet Kubernetes Certificate.

```yaml
spec:
  secretName: ###
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

De cette manière le certificat, obtenu par une entité tierce et reconnue, me permet de certifier mon application. Pour ce faire, il ne manque plus qu'à faire "voyager" le secret, le certificat, du namespace source au namespace cible. Cela se fait via un ReferenceGrant, qui permet de créer un "contrat" entre deux entitées, le secret et la destination. (_voir Devlog 17_).

## 3. Méthodes d'exposition

Plusieurs choix d'exposition se sont imposés, avec chacun des avantages et des inconvénients. Tout est une question de compromis entre sécurité, simplicité et contrôle. Voici les approches possibles et celle que j'ai retenue pour le moment.

**L'approche "from scratch"** : PAT et DNS Dynamique (configuration actuelle)
Pour l'instant, je suis parti sur la méthode qui selon moi était la plus accessible. J'utilise le PAT (Port Address Translation) directement sur ma box internet pour rediriger le trafic entrant des ports 80 (HTTP) et 443 (HTTPS) vers l'IP locale de mon cluster Kubernetes.

Comme mon IP publique n'est pas fixe, j'ai couplé cette configuration à DuckDNS. Concrètement, j'ai configuré un cron-job qui tourne de manière autonome dans mon cluster. Son rôle est d'aller toquer régulièrement chez DuckDNS pour mettre à jour mon IP publique.

Les avantages : C'est une excellente façon d'apprendre. On gère toute la chaîne de liaison, du routeur physique jusqu'au conteneur, sans dépendre d'une boîte noire.

Les inconvénients : J'ouvre littéralement une porte de mon réseau sur internet, l'exposant aux bots et aux scans incessants. De plus, si l'IP de la box change entre deux exécutions du cron-job, l'accès est temporairement rompu.

**L'approche tunnel** : Tunnels Inversés (ex: Cloudflare Tunnel)
Au lieu d'ouvrir une "porte" depuis l'extérieur vers l'intérieur (PAT), c'est le cluster qui initie un tunnel sortant et sécurisé vers un serveur externe.

Les avantages : Il n'y a plus aucun port à ouvrir sur la box, l'IP personnelle reste cachée, et la gestion du HTTPS est déléguée. La sécurité globale est renforcée.

Les inconvénients : On confie la gestion de son trafic à un acteur tiers. On perd en indépendance totale.

**L'approche "sécurisée"** : Le Réseau Maillé (ex: Tailscale ou WireGuard)
Cette solution est idéale si l'objectif n'est pas de rendre ses applications publiques, mais uniquement de pouvoir y accéder soi-même depuis l'extérieur.

Les avantages : Une sécurité accrue, presque impénétrable. Le cluster n'est pas exposé publiquement, il n'est accessible qu'aux machines explicitement connectées au VPN.

Les inconvénients : Il est impossible de partager un projet avec le grand public via un simple nom de domaine.

Pour un début, j'ai choisi une approche simple d'implémentation. Cela me permet d'ajouter diverses choses, notamment mes NetworkPolicies, et de les tester. Cela facilite aussi le test de mon application : comment elle réagit face aux règles implémentées, voir s'il y a des failles venant de l'extérieur. En outre, cette méthode d'exposition me permet un premier contact avec internet et va me permettre de renforcer la sécurité globale du cluster, en observant ce qu'il se passe et en testant différentes choses : DoS, scan...

Par la suite, j'aimerais passer sur une approche "tunnel", afin de renforcer la sécurité du cluster et d'éviter d'exposer mon IP personnelle. Enfin, sur le long terme, j'aimerais exposer mes applications "infra" afin de pouvoir configurer le cluster à distance. Pour ce faire, je passerai via une gateway privée, et utiliserai peut-être une approche via WireGuard.

## 4. Ce qu'il faut retenir

Tout au long de cette partie, j'ai appris énormément de choses. Tout d'abord, j'ai pu mettre en pratique ma certification CCNA en configurant réellement le PAT, des gateways, des certificats... La théorie couplée à la pratique est l'une des meilleures choses pour apprendre et renforcer ses connaissances.

Ensuite, j'ai pu voir toute une chaîne de déploiement : gérer l'adressage IP via IPAM, savoir faire une annonce de la gateway, du load balancer via le L2 announcement de Cilium, configurer toute la gateway, apprendre qu'il existe une ressource dédiée pour faire transiter les secrets (ReferenceGrant), approfondir mes connaissances sur les certificats, sur HTTPS... Le tout a été possible grâce à mes connaissances (CCNA) mais aussi grâce à différentes vidéos, blogs, articles et surtout les labs Cilium proposés par Isovalent (accessibles gratuitement), qui m'ont permis d'apprendre à configurer et découvrir de nouvelles choses sur Cilium.
