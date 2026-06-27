# Devlog 17 : Implémentation de la sécurité et implémentation réseau (partie 5)

Le dernier devlog traitait de la runtime security via Falco et de l'essai d'implémentation de ma première CiliumNetworkPolicy (_CNP_) qui s'était vouée à l'échec. Suite à cela j'ai réfléchi et j'ai décidé de repousser l'implémentation des CNP à plus tard, lorsque j'aurais une meilleure compréhension de mes outils. Pour combler cela je me suis renseigné via des vidéos, la documentation officielle et les labs Cilium (gratuits) proposés par Isovalent. C'est ici que j'ai pu beaucoup apprendre et c'est ici qu'est née l'idée d'implémenter l'ouverture du cluster, d'abord en local via un load balancer (résolvant le problème de SNAT, _cf devlog 16_), et plus tard, ouvrir le cluster au monde via HTTPS et TLS en passant par le PAT de ma box internet. Je reviens donc ici sur l'implémentation de la sécurité pour le routage (HTTPS, TLS, Certificats...) et sur le premier problème réseau que j'ai rencontré.

## 1.1 Gateway et AnnouncementPolicy

Afin d'intégrer ma première gateway je devais trouver un moyen de fournir des adresses IP locales dynamiquement à mes load balancers, qui seront les points d'entrée fixes vers mes pods. Pour ce faire j'ai paramétré un IPAM (_IP Address Management_) afin d'établir une pool d'adresses IP fixes qui pourront être distribuées par le contrôleur Cilium. Mais cela ne suffisait pas, comment mes adresses allaient être distribuées si elles ne pouvaient pas être vues ? À défaut d'avoir les connaissances et le matériel nécessaire pour implémenter BGP (_Border Gateway Protocol_) je me suis penché sur les L2AnnouncementPolicy de Cilium. Mais c'est quoi ? Pour faire simple, ce système utilise les requêtes ARP (L2), ce qui permet de rendre mes services visibles et atteignables localement. (_À noter que cette solution est prévue pour des installations locales, on-premises, et non pour des installations de grande envergure_.) Concrètement, de cette manière Cilium répondra aux demandes des IP externes et/ou des LoadBalancers avec des réponses ARP/NDP. Chaque service de mon cluster qui recevra des réponses ARP/NDP répondra avec son adresse MAC et le nœud sur lequel le service se trouve attirera le trafic vers lui, servant comme nœud d'entrée. L'avantage ici est que je puisse utiliser une adresse IP unique pour plusieurs services contrairement à NodePort, où le client doit décider vers quel hôte envoyer le trafic. Et surtout, l'un des avantages est la disponibilité : si le nœud d'entrée tombe, le L2 announcement va permettre au service de migrer vers un autre nœud et pourra ensuite reprendre le trafic.

Après avoir intégré tout ça j'avais besoin d'un point d'entrée, la gateway. Pour faire simple, quand un paquet, par exemple pour mon application nginx, arrive sur le cluster il sera envoyé vers le service load balancer. Ensuite le trafic est passé au proxy interne de la gateway (Envoy/Cilium), qui va ensuite rediriger le paquet vers les HTTPRoutes, qui vont filtrer la destination du paquet selon son endpoint et qui vont l'envoyer ensuite au service de l'application concernée, puis finalement le service final l'enverra au pod, au conteneur et à l'application !

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /details
    backendRefs:
      - name: details
        port: 9080
```

## 1.2 Certificat et TLS

Voilà le fonctionnement rapide du flux "internet -> application".
Mais à quoi bon se limiter à ça ? Notre trafic n'est pas chiffré, il est vulnérable. C'est là qu'entre en jeu l'ajout du protocole HTTPS (_HTTP over TLS_). Mais pour implémenter HTTPS il ne suffit pas de rajouter une ligne dans notre manifeste de base (_disponible dans k8s/manifests/gateway/public-gateway.yaml_). Non, pour cela nous avons besoin d'un certificat, une CA (_Certificate Authority_) capable de prouver que oui, nos données sont bien chiffrées. Cependant pour avoir un certificat, un tiers de confiance doit nous l'accorder, car un certificat auto-signé ne vaut rien, du point de vue identité et confiance, et non du point de vue chiffrement. On ne peut pas se dire "sécurisé" tout seul !

Il faut savoir qu'avant d'intégrer un certificat de confiance signé par un tiers j'ai décidé d'utiliser un certificat auto-signé, implémenté par **cert-manager**, mais pourquoi ? Un certificat auto-signé est plus simple à implémenter et donc par conséquent, au plus vite j'obtenais un certificat, validé ou non, au plus vite je pouvais tester mes nouveaux ajouts (_gateway, IPAM, L2Announcement..._). J'ai donc procédé de la sorte :

- J'ai créé un **"certificate-bootstrap"** qui a pour but de générer un certificat auto-signé.

- Puis je crée le "vrai" certificat, un certificat capable d'en signer d'autres, capable de prouver qu'ils sont authentiques. Pour ce faire ce certificat doit être chiffré, dans mon cas via l'algorithme **"ECDSA"** (_Elliptic Curve Digital Signature Algorithm_) et ensuite il doit être distribué dans le cluster.

- C'est là qu'intervient mon manifeste **"cluster-issuer"**, qui a pour but de propager ce certificat à l'ensemble du cluster.

Voilà pour ce qui est des certificats internes, non validés par une entité tierce. Cela suffisait largement pour tester ma gateway. J'ai donc pu accéder une première fois localement à **"https://test-himmel-local.com"** (_en simulant un DNS local et en ajoutant l'entrée `192.168.1.193 test.himmel-local.com` dans le fichier `/etc/hosts` de la machine cliente_). La première poignée de main avec HTTPS était établie.

Enfin cela n'était pas suffisant, le but est d'avoir un cluster accessible depuis internet, je pouvais continuer d'utiliser mes certificats auto-signés mais cela n'était pas crédible, je devais moi aussi passer par une entité tierce, **Let's Encrypt**.

Afin que Let's Encrypt puisse signer les certificats je devais l'installer, montrer sa présence dans le cluster, chose que j'ai pu faire via un manifeste "clusterIssuer". Le principe est simple, je garde la démarche d'avant mais je rajoute Let's Encrypt au milieu, qui pourra signer mes certificats dédiés à ma gateway. Cependant il me restait un problème majeur à traiter : comment mon certificat "officiel" résidant dans mon namespace **cert-manager** pouvait atteindre ma gateway afin de lui fournir sa sécurité ? Pour ce faire il suffit de passer un pacte de confiance avec un manifeste **ReferenceGrant**. Le principe est simple, le manifeste fait office de contrat, il stipule que le secret, ici le certificat, a le droit de voyager jusqu'à ma gateway, dans son namespace associé. De cette manière la boucle est bouclée, mon certificat est signé par une entité tierce et reconnue, il est envoyé dans un namespace précis, à un groupe précis et est utilisé par ce même groupe, capable de chiffrer le trafic.

```yaml
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-read-secrets
  namespace: cert-manager
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: gateway-system
  to:
    - group: ""
      kind: Secret
```

## 2.1 Problème réseau : DHCP et Debug

Cela devait arriver, un problème réseau, non lié à mon cluster directement, est survenu. Cette partie sera dédiée à la découverte, la résolution et aux concepts appris.

Comme chaque jour j'approfondissais mes connaissances sur mon cluster, je me renseignais, je testais, je réparais, j'interagissais... Mais là c'était différent. Je venais d'implémenter cert-manager la veille pour préparer l'exposition du cluster sur internet via le NAT/PAT de la box (_en HTTPS_). Le lendemain lors du démarrage du cluster je vois que c'est lent, que ça ne répond pas. Première chose que je fais c'est d'aller voir mes applications via `kubectl get application -A -n argocd` et là je vois que l'intégralité des applications étaient en statut **Unknown**. D'accord, je sors la démarche classique, je décris mes pods argocd et analyse les logs, tout semble normal. J'essaie de forcer la synchronisation (Sync / Prune) depuis l'interface ArgoCD, ne sait-on jamais, mais rien n'y fait. Je redémarre l'application avec `kubectl rollout restart` mais là encore, même constat, le problème ne peut pas venir d'ArgoCD lui-même, il doit y avoir autre chose.

Je descends dans les couches, si mes applications sont en unknown, que rien ne se déploie (Apps of Apps non fonctionnel) je dois investiguer plus profondément. Je me connecte en SSH sur mes machines, je regarde la connexion avec internet via un simple `curl google.com`. Master : OK, Node3 : OK, Node2 : rien. Le nœud n'a plus d'accès internet, voilà le coupable. Je retourne sur mon CLI, j'affiche tous les pods avec `kubectl get pods`, je vois qu'un des pods **CoreDNS** sur le nœud 2 est en erreur. Je le supprime, car après tout _It's Always DNS_. Il revient, fonctionne bien, statut : running, mais cela ne résout pas le problème, c'est autre chose, c'est encore en dessous, en dessous de Kubernetes.

Je réfléchis, si ça ne vient pas de mon nœud, alors ça vient d'où ? Je me penche sur le réseau, je pense d'abord à un problème physique (L1). Je débranche mon câble ethernet, le change, redémarre mon uplink, mais rien. Ça ne pouvait pas venir du câble, tous me donnaient la même chose : pas d'internet mais d'après la commande `cat /sys/class/net/eno1/carrier` effectuée sur le nœud, et qui m'a retourné **"1"**, le câble était bien détecté, c'était autre chose.

Je me penche du côté de la box internet. Je me connecte à l'interface d'administration du FAI et là je découvre le coupable : un conflit d'IP. Deux appareils distincts revendiquent la même adresse IP (celle de mon nœud 2). Je tente alors une chose simple : je bannis l'adresse MAC "intruse" sur la box, mais pour une raison qui m'échappe encore, elle ne disparaît pas, elle reste, et restera affichée et présente dans les appareils connectés. De ce fait, impossible de réserver l'IP car elle est considérée comme déjà prise.

C'est en vérité ici que l'incident devient critique : pour contourner le conflit j'essaie d'attribuer une adresse IP qui se situe hors de la plage DHCP de la box. Ce qui s'ensuit est un crash total de la carte réseau **"eno1"** au démarrage du nœud. Impossible d'accéder au CLI, il est surchargé de messages d'erreur, j'ai bien cru que je devais remplacer ma carte réseau.

_ajouter image CLI_

C'est du sérieux, je décide de passer à l'action de façon plus directe. Tout d'abord je "_drain_" mon nœud via `kubectl drain` afin que le scheduler puisse réattribuer les ressources de mon nœud aux autres nœuds disponibles, ensuite je débranche la machine et l'emmène sur mon bureau : écran, clavier, souris. Pour contourner les erreurs j'ai dû passer par le GRUB (_GRand Unified Bootloader_). Je le lance en mode **debug** et je décide d'aller éditer manuellement le fichier de configuration de l'interface **eno1** pour lui donner une adresse IP valide.

C'est ici que j'ai décidé de réserver une IP libre de ma plage DHCP préalablement via l'interface administrateur de la box. Je teste, le réseau semble stable et fonctionnel, premier ping, premier contact, le ping passe. C'est bon, ça y est. Avant toute autre chose je pars modifier mon inventaire Ansible afin qu'il pointe vers la nouvelle adresse IP. Je rebranche ensuite mon nœud, je le réactive via `kubectl uncordon` et le scheduler lui renvoie bien la charge de travail !

## 2.2 Ce qu'il faut retenir

- **L'effet domino (Top-Down) :** Un problème qui s'affiche tout en haut dans une belle interface web (ici ArgoCD en "**unknown**") peut cacher une défaillance tout en bas (bail DHCP de box internet). Il ne faut jamais faire confiance aveuglément à l'interface, il faut tester les bases (ici avec `curl`).

- **Piège hors-plage DHCP :** J'ai commencé le projet Himmel sans connaissance préalable sur le réseau, je n'avais pas encore mon CCNA, par conséquent je n'avais pas connaissance des baux DHCP et tout ce qui suit. Maintenant je sais qu'attribuer une IP statique en prévision d'une installation, d'autant plus locale comme la mienne, est nécessaire. Aussi, attribuer une adresse IP hors de la plage DHCP prévue par le serveur DHCP peut provoquer un rejet pur et simple au niveau de l'interface réseau de l'OS (crash de l'interface).

- **Importance de la résilience K8s :** Le combo **drain + Scheduler** a parfaitement fonctionné. Pendant que je bataillais avec le GRUB et la carte réseau, le reste de mes applications tournait sur les autres nœuds.
