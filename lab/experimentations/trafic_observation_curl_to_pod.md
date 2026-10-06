# Lab : observation du trafic depuis une requête curl externe vers une application (Pod)

## Présentation

- **Objectif :** reconstruire le chemin d'une requête HTTPS externe jusqu'à mon Pod Nginx et comprendre à quel moment Cilium intervient.
- **Ce que j'ai trouvé :** la VIP `192.168.1.193` est présente dans le datapath BPF de Cilium, Envoy possède la route Gateway et un cluster upstream vers `nginx-service`, et Hubble permet d'observer une connexion vers le Pod depuis `10.0.2.215`.
- **Ce qui reste ouvert :** je n'ai pas encore démontré le chemin exact `Gateway → Service ClusterIP → Pod`, ni relié de façon certaine tous les événements TCP et L7 à une seule connexion.

> **Note de publication :** les adresses IP publiques, le domaine public et l'adresse MAC ont été remplacés par des valeurs de documentation. Les adresses privées du lab sont conservées, car elles sont nécessaires à la compréhension du datapath.

---

## Objectifs

Le but de ce lab était de partir d'une requête HTTPS réellement envoyée depuis l'extérieur et d'essayer de reconstruire son chemin jusqu'à mon application Nginx dans Kubernetes.

Je voulais notamment comprendre :

- où intervient la Gateway ;
- quel rôle joue Envoy ;
- comment Cilium représente la Gateway et le Service dans son datapath ;
- à quel moment le trafic devient du trafic interne au cluster ;
- quelle adresse IP et quelle identité Cilium sont observées au niveau du Pod ;
- si je pouvais réellement démontrer un chemin de type :

```text
Client externe
      ↓
Gateway / Envoy
      ↓
Service
      ↓
Pod Nginx
```

Au départ, je pensais pouvoir reconstruire ce chemin uniquement avec Hubble, `tcpdump`, les objets Kubernetes et les commandes de debug Cilium. En pratique, les observations ont montré plusieurs couches différentes et certaines ne sont pas directement visibles de la même manière.

---

## À noter

Ce lab est volontairement exploratoire. Les hypothèses changent au fur et à mesure des observations.

Je distingue donc autant que possible :

- **ce qui est directement observé** dans une commande ou un log ;
- **ce qui est fortement déduit** à partir de plusieurs observations ;
- **ce qui reste une hypothèse** et doit encore être vérifié.

C'est important ici, car plusieurs outils montrent des informations différentes sur le même trafic. Par exemple, Hubble peut afficher un événement TCP avec une source `10.0.2.215`, puis un événement HTTP avec une autre source. Je ne peux pas automatiquement considérer qu'il s'agit du même paquet ou de la même connexion.

---

# Étape 1 : portée de l'expérience

Je pars d'une requête externe vers ma Gateway publique.

La Gateway utilise l'adresse virtuelle :

```text
192.168.1.193
```

Cette adresse est une **VIP**, c'est-à-dire une adresse IP virtuelle. Elle n'est pas une adresse correspondant à une interface physique classique d'un nœud.

Le Gateway est :

```text
GatewayClass: cilium
Gateway: gateway-system/public-gateway
```

La Gateway expose les ports HTTP et HTTPS.

Le service généré par Cilium est :

```text
cilium-gateway-public-gateway
```

avec notamment :

```text
Type:              LoadBalancer
ClusterIP:         10.98.222.177
LoadBalancer IP:   192.168.1.193
Port 80:           NodePort 31719
Port 443:          NodePort 31041
Selector:          <none>
Endpoints:         <none>
ExternalTrafficPolicy: Cluster
InternalTrafficPolicy: Cluster
```

Le fait que ce Service n'ait pas de selector ni d'Endpoints visibles dans l'objet Kubernetes m'a immédiatement interrogé. Je m'attendais à retrouver une relation classique `Service → EndpointSlice → Pod`.

À ce stade, je ne peux cependant pas conclure que la Gateway « contourne les Services ». Je peux seulement constater que son Service généré ne présente pas la structure habituelle d'un Service applicatif avec selector et endpoints.

Pour Nginx, le Service applicatif est différent :

```text
nginx-service
ClusterIP: 10.96.184.22
Port: 80
```

Son backend Pod a changé plusieurs fois pendant les expérimentations, à la suite de recréations du Pod. Il faut donc distinguer les différents snapshots du lab.

---

# Étape 2 : mise au point avec les CiliumNetworkPolicy

Avant de chercher à reconstruire le chemin réseau, j'avais déjà essayé différentes CiliumNetworkPolicy.

Une première tentative avec l'identité `world` m'avait notamment permis de constater qu'une policy contenant une règle `ingress` rendait l'accès entrant restrictif.

J'ai donc commencé par une policy de ce type :

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l3-rule-test
  namespace: nginx
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
    - fromEntities:
        - world
```

L'idée était simple : vérifier si l'identité `world` permettait d'autoriser le trafic provenant de l'extérieur.

Le résultat a été un blocage du trafic vers Nginx. La Gateway retournait notamment :

```text
HTTP/1.1 503 Service Unavailable
server: envoy
upstream connect error or disconnect/reset before headers.
reset reason: connection timeout
```

Hubble confirmait que le trafic arrivant sur Nginx était refusé.

J'ai ensuite essayé `cluster` :

```yaml
ingress:
  - fromEntities:
      - cluster
```

Cela m'a permis de constater qu'une requête externe pouvait finalement atteindre Nginx lorsque la connexion backend était autorisée comme provenant du cluster.

C'est à partir de là qu'une hypothèse a commencé à émerger : le client externe est bien externe au niveau de la Gateway, mais Envoy agit comme proxy et établit ensuite une nouvelle connexion vers le backend.

Cette hypothèse sera ensuite confrontée aux observations plus précises.

---

# Étape 3 : expérimentation avec `fromCIDR`

J'ai ensuite voulu tester une approche basée uniquement sur les adresses IP privées :

```yaml
ingress:
  - fromCIDR:
      - 192.168.0.0/16
      - 10.0.0.0/8
      - 172.16.0.0/12
```

L'idée était d'autoriser les trois grandes plages privées.

Pourtant, un trafic interne au cluster était lui aussi bloqué. Un extrait représentatif de Hubble était :

```text
Sep 7 19:10:49.942: default/test-client:37162 -> nginx/...:80 to-overlay FORWARDED (TCP Flags: SYN)
Sep 7 19:10:49.950: default/test-client:37162 <> nginx/...:80 DENIED (TCP Flags: SYN)
Sep 7 19:10:49.950: default/test-client:37162 <> nginx/...:80 Policy denied DROPPED (TCP Flags: SYN)
```

Le résultat était intéressant : appartenir à une plage IP privée ne suffisait pas nécessairement à obtenir l'autorisation attendue.

J'ai donc commencé à distinguer deux choses :

1. l'adresse IP visible à un instant donné ;
2. l'identité Cilium associée à la source du trafic.

C'est à partir de là que l'investigation s'est déplacée vers le datapath réel.

---

# Étape 4 : observation de la Gateway et recherche du trafic réel

Je commence par observer directement la VIP :

```bash
sudo tcpdump -ni any host 192.168.1.193
```

Lors d'une requête HTTPS externe, j'observe sur l'interface physique `eno1` un trafic de la forme :

```text
203.0.113.10:43188 > 192.168.1.193:443
192.168.1.193:443 > 203.0.113.10:43188
```

L'ARP permet également d'observer que la VIP est annoncée avec une adresse MAC :

```text
192.168.1.193 is-at 02:00:5e:10:00:01
```

Ce que je peux démontrer ici est limité mais utile : sur l'interface physique observée, le trafic arrive bien à destination de `192.168.1.193` et je ne vois pas de réécriture d'adresse avant cette arrivée.

Je ne peux pas en déduire qu'il n'existe aucun NAT ailleurs dans le chemin. Je ne peux pas non plus conclure précisément à quel moment une éventuelle traduction de source intervient.

---

# Étape 5 : observation au sein du nœud

Je cherche ensuite à savoir comment Cilium représente la VIP.

Sur les trois nœuds, la commande :

```bash
cilium-dbg bpf lb list | grep 192.168.1.193
```

montre une entrée pour la VIP en HTTP et en HTTPS.

Chaque nœud possède notamment une association de type :

```text
192.168.1.193:80/TCP  [LoadBalancer, l7-load-balancer]
192.168.1.193:443/TCP [LoadBalancer, l7-load-balancer]
```

avec un port de proxy L7 local différent selon le nœud :

```text
master: 10152
node2:  15206
node3:  19500
```

On retrouve également une entrée générique :

```text
192.168.1.193:0/ANY ... [LoadBalancer, non-routable]
```

Cette entrée ne doit pas être interprétée comme une connexion réelle vers `0.0.0.0:0`. Il s'agit d'une représentation interne du datapath BPF.

### Ce que cela démontre

Je peux démontrer que les trois nœuds ont une représentation locale de la VIP dans le datapath Cilium et qu'un proxy L7 lui est associé.

Cela ne démontre pas encore qu'une requête donnée passe réellement par chacun de ces nœuds.

---

## Les ports L7 et Envoy

Je me suis ensuite connecté en SSH sur les nœuds et j'ai vérifié les sockets en écoute avec `ss`.

Sur node3, par exemple :

```text
127.0.0.1:19500  cilium-envoy
```

On retrouve de la même manière :

```text
master: 127.0.0.1:10152
node2:  127.0.0.1:15206
node3:  127.0.0.1:19500
```

Cela établit une forte corrélation entre les ports L7 indiqués par le datapath BPF et les listeners locaux du processus `cilium-envoy`.

Je préfère cependant parler de corrélation plutôt que d'affirmer que « tout le trafic Gateway passe par ce port », car cela n'est pas démontré uniquement par `ss`.

Une observation plus intéressante apparaît ensuite sur node3 :

```text
ESTAB ... 192.168.1.193:80 203.0.113.11:49620 users:("cilium-envoy",pid=1634,fd=62)
```

Ici, `ss` montre directement que le processus `cilium-envoy` possède une connexion TCP établie avec une adresse locale `192.168.1.193:80`.

C'est une preuve plus forte de l'implication d'Envoy dans le trafic observé que la simple présence d'un listener.

En revanche, je ne peux pas déterminer à partir de cette seule ligne le rôle exact de l'adresse distante ni reconstruire toute la chaîne amont/aval.

---

# Étape 6 : investigation en profondeur, différentes pistes possibles

À ce stade, plusieurs hypothèses étaient possibles.

### Hypothèse 1 : le trafic passe par un Service Kubernetes classique

C'est la première chose que j'ai voulu vérifier, puisque mon application est exposée derrière un Service :

```text
nginx-service
ClusterIP: 10.96.184.22
```

Cilium possède bien une représentation de ce Service dans son BPF load balancer.

Selon les snapshots observés pendant le lab, j'ai notamment retrouvé des backends Pod différents, car le Pod Nginx a été recréé plusieurs fois.

Dans un snapshot intermédiaire, l'entrée observée était par exemple :

```text
10.96.184.22:80/TCP -> 10.0.2.72:80/TCP
```

J'avais également observé `10.0.2.116` dans un autre état plus ancien du lab. Ces adresses ne doivent donc pas être mélangées : elles correspondent à des snapshots différents du Pod.

Dans l'état final de l'expérience, le Pod observé est `10.0.2.244`.

La présence de ces entrées BPF démontre que Cilium connaît la relation Service → backend. Elle ne démontre pas que la requête Gateway observée a effectivement utilisé le ClusterIP `10.96.184.22` sur son chemin exact.

### Hypothèse 2 : Envoy établit directement la connexion vers le Pod

Cette hypothèse devient plus intéressante lorsque j'observe la configuration runtime d'Envoy.

---

## Configuration runtime d'Envoy

La commande :

```bash
cilium-dbg envoy admin routes
```

permet d'observer une configuration correspondant à la Gateway.

Pour la route HTTPS, on retrouve notamment :

```yaml
name: gateway-system/cilium-gateway-public-gateway/listener-secure
virtual_hosts:
  - name: gateway-system/cilium-gateway-public-gateway/projet-himmel.example
    domains:
      - projet-himmel.example
      - projet-himmel.example:*
    routes:
      - match:
          prefix: /
        route:
          cluster: gateway-system/cilium-gateway-public-gateway/nginx:nginx-service:80
```

Pour HTTP, la route contient une redirection vers HTTPS.

Cette observation est importante : le `HTTPRoute` Kubernetes a bien été traduit en configuration de routage runtime pour Envoy.

Cela démontre la partie L7 du chemin : Envoy possède une règle qui associe la requête destinée au domaine à un cluster upstream correspondant à `nginx-service:80`.

En revanche, une route HTTP n'est pas un « saut réseau » physique. Elle décrit la décision de routage L7 prise par Envoy.

---

## Le cluster upstream d'Envoy et l'EDS

Je regarde ensuite les clusters runtime :

```bash
cilium-dbg envoy admin clusters
```

Sur node3, je retrouve notamment :

```text
gateway-system/cilium-gateway-public-gateway/nginx:nginx-service:80
```

avec :

```text
eds_service_name::nginx/nginx-service:80
```

et surtout un endpoint :

```text
10.0.2.244:80
```

avec des compteurs du type :

```text
cx_active::0
cx_connect_fail::0
cx_total::10
rq_active::0
rq_error::0
rq_success::21
rq_total::21
health_flags::healthy
```

**EDS signifie Endpoint Discovery Service**, et non « Endpoint Detection Service ».

Cette observation permet de faire un pas supplémentaire : Envoy connaît un cluster upstream correspondant au Service `nginx-service:80`, et l'EDS lui fournit actuellement l'endpoint `10.0.2.244:80`.

Les compteurs montrent également qu'Envoy a traité des requêtes vers ce cluster. Je ne considère cependant pas le compteur `rq_total` comme la preuve qu'une requête précise du test correspond à l'un de ces événements.

---

# Étape 7 : analyse sur Linux et avec Hubble

Je reviens ensuite à Hubble et au datapath Cilium.

Une observation importante est la présence de l'adresse :

```text
10.0.2.215
```

Cette adresse correspond à l'interface `cilium_host` de node3 :

```text
inet 10.0.2.215/32 scope global cilium_host
```

Ce n'est donc :

- ni l'IP LAN de node3 (`192.168.1.52`) ;
- ni l'IP du Pod Nginx ;
- ni le ClusterIP du Service ;
- ni la VIP de la Gateway.

C'est l'adresse de l'interface `cilium_host` de node3.

La commande `cilium-dbg nodeid list` permet de retrouver les correspondances :

```text
NODE ID   IP ADDRESSES
0x36d3    192.168.1.52
          10.0.2.215
0x4959    192.168.1.50
          10.0.0.250
0xc3a0    192.168.1.110
          10.0.1.43
```

Cela m'a permis de comprendre que `10.0.2.215` n'était pas une IP Pod mystérieuse, mais bien une adresse liée au réseau Cilium de node3.

---

## Observation directe avec `cilium-dbg monitor`

L'observation la plus intéressante du lab arrive avec :

```bash
cilium-dbg monitor --related-to 173
```

L'endpoint `173` correspond au Pod Nginx observé à ce moment-là.

Le trafic TCP montre notamment :

```text
10.0.2.215:38162 -> 10.0.2.244:80  TCP SYN
10.0.2.244:80 -> 10.0.2.215:38162  TCP SYN, ACK
10.0.2.215:38162 -> 10.0.2.244:80  TCP ACK
```

Puis Hubble/Cilium remonte une requête HTTP :

```text
GET https://projet-himmel.example/ => 0
```

et une réponse :

```text
GET https://projet-himmel.example/ => 304
```

Ici, contrairement aux premières hypothèses, je peux être beaucoup plus précis.

J'observe directement une communication entre :

```text
10.0.2.215:38162
        ↓
10.0.2.244:80
```

où :

- `10.0.2.215` est le `cilium_host` de node3 ;
- `10.0.2.244` est le Pod Nginx dans l'état final du test ;
- l'endpoint Cilium du Pod est `173` ;
- l'identité Cilium du Pod est `30589`.

Cela démontre que cette connexion TCP atteint directement l'adresse du Pod depuis le contexte réseau Cilium de node3.

En revanche, je n'ai pas observé dans cet événement une destination `10.96.184.22`. Je ne peux donc pas transformer cette observation en preuve d'un chemin réseau exact passant par le ClusterIP du Service.

---

## Une observation qui m'a d'abord semblé contradictoire

Dans des observations Hubble précédentes, j'avais obtenu des événements comme :

```text
10.0.2.215:51732 (ingress) -> nginx/...:80  SYN
```

puis des événements L7 ressemblant à :

```text
203.0.113.12:52306 (ingress) -> nginx/...:80  http-request
203.0.113.12:52306 (ingress) <- nginx/...:80  http-response 200
```

La première adresse correspond au contexte `cilium_host` observé sur le nœud, tandis que les événements HTTP montrent une autre source.

Je ne peux pas simplement dire qu'Hubble « change l'IP » entre deux lignes. Les événements TCP et L7 ne sont pas nécessairement la représentation d'une seule et même connexion TCP. Il peut exister plusieurs connexions ou plusieurs frontières de proxy.

Cette observation reste donc une question ouverte, plutôt qu'une preuve de NAT à un endroit précis.

---

## Test avec `tcpdump` sur le port du proxy L7

J'ai également tenté :

```bash
sudo tcpdump -ni any port 19500
```

pendant une requête.

Je n'ai rien observé.

Au premier abord, cela semble contradictoire avec le fait que `ss` montre qu'Envoy écoute sur `127.0.0.1:19500` et qu'une entrée BPF associe la VIP à ce port.

Mais cette absence d'observation ne suffit pas à démontrer qu'Envoy n'intervient pas.

Le trafic peut être redirigé au niveau du datapath eBPF vers le proxy sans apparaître comme un trafic TCP classique visible par ce `tcpdump` sur le port `19500`.

Je garde donc les deux observations :

- `ss` montre qu'Envoy possède bien le listener local correspondant au port L7 ;
- `tcpdump` ne voit pas de trafic TCP classique sur ce port pendant mon test.

Je ne force pas une conclusion supplémentaire tant que je n'ai pas une observation permettant de relier précisément les deux.

---

# Observation complémentaire : les Services Cilium

Cilium représente notamment :

```text
ID 61: 192.168.1.193:80/TCP  LoadBalancer
ID 62: 192.168.1.193:443/TCP LoadBalancer
ID 47: 10.96.184.22:80/TCP  ClusterIP
```

Pour le Service Nginx, on retrouve une association de backend de la forme :

```text
10.96.184.22:80/TCP
    => 10.0.2.244:80/TCP
```

Cette relation est bien présente dans la représentation Cilium.

J'ai toutefois essayé :

```bash
cilium-dbg monitor --related-to 47
```

pendant une requête, sans obtenir d'événement de trafic permettant de démontrer que cette requête particulière traversait le Service ID `47`.

J'ai fait la même tentative avec les IDs de la Gateway :

```bash
cilium-dbg monitor --related-to 61
cilium-dbg monitor --related-to 62
```

sans obtenir non plus l'observation directe attendue.

Cela ne prouve pas que les Services ne sont pas utilisés. Cela montre simplement que cette méthode de monitoring ne m'a pas permis de relier directement les requêtes observées aux entrées de Service concernées.

---

# Prochaine étape du lab

À ce stade, plusieurs questions restent ouvertes :

1. Le trafic vers Nginx passe-t-il réellement par le ClusterIP `10.96.184.22`, ou Envoy utilise-t-il directement l'endpoint fourni par l'EDS ?
2. À quel endroit précis intervient la traduction de source qui explique l'apparition de `10.0.2.215` ?
3. Comment relier précisément les événements TCP observés par Hubble aux événements L7 générés par le proxy ?
4. Pourquoi le trafic n'apparaît-il pas avec `tcpdump` sur le port local `19500` alors qu'Envoy est associé à ce port dans le datapath ?
5. Quel est exactement le rôle du Service `cilium-gateway-public-gateway`, qui possède une ClusterIP mais aucun selector ni endpoint classique ?

L'objectif n'est donc plus seulement de « trouver le chemin », mais de déterminer quelles observations permettent réellement de prouver chaque étape de ce chemin.

---

# Étape 8 : nouvelles observations

Après les premières expérimentations, j'ai continué l'investigation avec l'objectif de remplacer progressivement les hypothèses par des observations plus directes.

## VIP et datapath BPF

La VIP `192.168.1.193` est présente sur les trois nœuds dans le BPF load balancer avec le marquage :

```text
[LoadBalancer, l7-load-balancer]
```

et un port de proxy L7 différent selon le nœud.

Cela renforce l'idée que Cilium prend en charge localement la redirection vers le proxy L7. Cela ne signifie toujours pas que chaque nœud reçoit effectivement les requêtes externes.

## Service Nginx

Dans l'état final du test, le backend est :

```text
10.0.2.244:80
```

et Cilium possède une association active entre :

```text
10.96.184.22:80
        ↓
10.0.2.244:80
```

Ici, « active » désigne l'association du backend dans la représentation Cilium. Il ne faut pas l'interpréter comme « une connexion TCP active ».

## Envoy

La configuration runtime d'Envoy contient :

```text
gateway-system/cilium-gateway-public-gateway/nginx:nginx-service:80
```

et l'EDS fournit :

```text
10.0.2.244:80
```

L'ensemble forme une chaîne logique cohérente :

```text
Gateway / HTTPRoute
        ↓
Envoy route
        ↓
cluster upstream nginx:nginx-service:80
        ↓
EDS
        ↓
10.0.2.244:80
```

Cette chaîne est démontrée au niveau de la configuration et du runtime d'Envoy.

Ce que je ne peux pas encore démontrer est que le paquet réseau observé par `cilium-dbg monitor` a physiquement traversé le ClusterIP `10.96.184.22` avant d'arriver sur `10.0.2.244`.

---

# Résultats et questions ouvertes

## Démontré

À la fin de l'investigation, plusieurs éléments sont clairement établis :

- la Gateway utilise la VIP `192.168.1.193` ;
- Cilium possède des entrées BPF LoadBalancer pour cette VIP sur les trois nœuds ;
- ces entrées sont associées à un traitement L7 ;
- les ports L7 observés dans le BPF correspondent à des listeners locaux de `cilium-envoy` ;
- Envoy possède une configuration runtime correspondant au `HTTPRoute` de la Gateway ;
- Envoy possède un cluster upstream correspondant à `nginx-service:80` ;
- l'EDS fournit à Envoy l'endpoint `10.0.2.244:80` ;
- le Pod Nginx possède l'endpoint Cilium `173` et l'identité `30589` dans l'état final observé ;
- `10.0.2.215` est l'adresse `cilium_host` de node3 ;
- `cilium-dbg monitor` permet d'observer directement une connexion `10.0.2.215:38162 → 10.0.2.244:80` ;
- une requête HTTP est également visible au niveau L7 sur cet endpoint.

## Très plausible / déduit

Les observations rendent très plausible le fonctionnement suivant :

```text
Client externe
      │
      │ HTTPS
      ▼
VIP 192.168.1.193
      │
      ▼
Cilium / traitement L7
      │
      ▼
Envoy
      │
      │ route HTTPRoute
      ▼
cluster upstream nginx:nginx-service:80
      │
      │ EDS
      ▼
10.0.2.244:80
      │
      ▼
Pod Nginx
```

Il est également très plausible que la connexion observée depuis `10.0.2.215` corresponde à la connexion interne établie vers le backend par l'infrastructure du nœud/proxy.

Mais je garde volontairement une réserve sur la position exacte de chaque étape réseau, notamment sur le rôle du ClusterIP dans cette requête précise.

## Non démontré

Je n'ai pas encore démontré :

- que le paquet de cette requête précise a traversé `10.96.184.22` comme destination réseau ;
- l'endroit exact où une éventuelle traduction de source intervient ;
- que les événements TCP et L7 observés par Hubble correspondent tous à une seule et même connexion ;
- que `tcpdump` sur `19500` devrait nécessairement voir les paquets correspondant au traitement L7 ;
- le chemin physique complet entre la VIP, Envoy et le Pod au niveau de chaque paquet.

### Ce que je retiens du lab

Le lab n'a donc pas permis de reconstruire chaque paquet de bout en bout, mais il a permis de faire quelque chose de plus intéressant que de simplement constater qu'une requête fonctionne : j'ai pu descendre progressivement dans les différentes couches et remplacer plusieurs suppositions par des observations concrètes.

J'ai notamment commencé avec une représentation assez simple :

```text
Gateway → Service → Pod
```

Puis les observations m'ont obligé à distinguer :

```text
VIP
 ↓
Cilium BPF LoadBalancer
 ↓
L7 / Envoy
 ↓
HTTPRoute
 ↓
Envoy upstream cluster
 ↓
EDS
 ↓
Pod endpoint
```

Le point encore ouvert est précisément de déterminer comment cette chaîne de configuration se traduit en chemin réseau réel pour une connexion donnée.

C'est probablement la prochaine étape intéressante du lab : ne plus seulement observer les composants séparément, mais essayer de corréler une seule requête avec les différents niveaux du datapath, du paquet Ethernet jusqu'à la décision L7.
