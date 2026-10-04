# Lab: Observation du traffic depuis une requête curl (externe) vers une application (pod)

## Objectifs

Je vais de nouveau analyser le trafic bien que j'ai déjà analyser le trafic réseau via hubble pour résoudre un problème avec mes CNP.
Le but ici est de chercher à comprendre en profondeur le chemin d'un paquet venant de l'extérieur jusqu'à mon application en le suivant avec hubble sans forcément prêter attention au SNAT/Envoy (_cf: devlog 20_).

## Étape 1: portée de l'expérience

Je vais commencer à lister ce sur quoi nous allons travailler.
Il faut savoir le trafic "publique", dans mon cluster, passe par une gateway, c'est donc une étape suppplémentaire à observer.

- Gateway
  ➜ experimentations git:(main) ✗ kubectl get gateway -A
  NAMESPACE NAME CLASS ADDRESS PROGRAMMED AGE
  gateway-system public-gateway cilium 192.168.1.193 True 85d

- HttpRoute
  ➜ experimentations git:(main) ✗ kubectl get httproute -A
  NAMESPACE NAME HOSTNAMES AGE
  nginx http-app-nginx ["projet-himmel.duckdns.org"] 85d
  nginx http-to-https-redirect ["projet-himmel.duckdns.org"] 85d

- Service
  kubectl get svc -n nginx
  NAME TYPE CLUSTER-IP EXTERNAL-IP PORT(S) AGE
  nginx-service ClusterIP 10.96.184.22 <none> 80/TCP 99d

- Endpointslice
  ➜ experimentations git:(main) ✗ kubectl get endpointslice -n nginx
  NAME ADDRESSTYPE PORTS ENDPOINTS AGE
  nginx-service-8frzn IPv4 80 10.0.2.72 99d

- pod
  ➜ experimentations git:(main) ✗ kubectl get pods -n nginx -o wide
  NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
  nginx-deployment-b995944fb-8v6jb 1/1 Running 1 (12m ago) 4d2h 10.0.2.72 node3 <none> <none>

## Étape 2: mise au point

Maintenant que l'on sait sur quoi on travail on peut dégager quelques informations importantes.
tout d'abord, mon service est en clusterIP, il a donc une adresse ip sur laquelle il peut être joint.
Le pod a lui aussi une ip (éphémère) sur laquelle il peut être joint, ici l'ip est **10.0.2.72**.
Moins important dans le cadre de l'expérience mais on peut observer que le trafic est chiffré via HTTPS et que le trafic HTTP est redirigé vers HTTPS.
Enfin, la gateway, porte d'entrée du cluster à elle aussi son ip.

Avec tout cela on peut déjà établir un schéma simple:

```
ClusterIP nginx
      |
Endpointslice
      |
podIp nginx
```

Ainsi qu'un autre plus détaillé:

```
Gateway
      |
HTTPRoute
      |
Service nginx / ClusterIP 10.96.184.22
      |
EndpointSlice
      |
Pod 10.0.2.72
```

Ensuite, pour plus de précision, je fournis ici le backend utilisé par les httproute:

```yaml
Backend Refs:
      Group:
      Kind:    Service
      Name:    nginx-service
      Port:    80
      Weight:  1
    Matches:
      Path:
        Type:   PathPrefix
        Value:  /
```

On peut conclure que l'association de la gateway et des httproute se charge de savoir quelle requête externe doit être envoyé vers quelle application. La gateway se charge de fournir le point d'entrée tandis que les httpRoute contiennent les règles de routage.
Le service, lui, se charge de savoir quels pods constituent actuellement le backend de l'application.

## Étape 3: expérimentation

Après avoir lancé la commande `➜  experimentations git:(main) ✗ hubble observe --pod nginx/nginx-deployment-b995944fb-8v6jb -f`
et accédé à ma page nginx, le trafic arrive.

```bash
➜  experimentations git:(main) ✗ hubble observe --pod nginx/nginx-deployment-b995944fb-8v6jb -f
Sep 30 17:37:09.960: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: SYN)
Sep 30 17:37:09.960: 10.0.2.215:51732 (host) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-stack FORWARDED (TCP Flags: SYN, ACK)
Sep 30 17:37:09.961: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: ACK)
Sep 30 17:37:09.961: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Sep 30 17:37:09.962: 90.110.5.2:52306 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) http-request FORWARDED (HTTP/1.1 GET https://projet-himmel.duckdns.org/)
Sep 30 17:37:09.963: 10.0.2.215:51732 (host) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-stack FORWARDED (TCP Flags: ACK, PSH)
Sep 30 17:37:09.965: 90.110.5.2:52306 (ingress) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) http-response FORWARDED (HTTP/1.1 200 6ms (GET https://projet-himmel.duckdns.org/))
Sep 30 17:37:10.338: 90.110.5.2:52306 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) http-request FORWARDED (HTTP/1.1 GET https://projet-himmel.duckdns.org/favicon.ico)
Sep 30 17:37:10.339: 90.110.5.2:52306 (ingress) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) http-response FORWARDED (HTTP/1.1 404 1ms (GET https://projet-himmel.duckdns.org/favicon.ico))
Sep 30 17:38:10.339: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
Sep 30 17:38:10.339: 10.0.2.215:51732 (host) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-stack FORWARDED (TCP Flags: ACK, FIN)
Sep 30 17:38:10.339: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: ACK)
```

Ici plusieurs choses intéréssantes se produisent.
Tout d'abord on pourrait s'attendre à pouvoir observer explicitement le trafic suivant:

```
requête entrante
      |
gateway
      |
service/backend
      |
pod
```

Cependant, comme vu dans le devlog 20 et dans les logs ci-dessus, le proxy de Cilium, Envoy, peux dans certain cas utiliser un système de SNAT, masquant alors notre adresse ip d'origine.

Tant bien même nous pouvons quand même dégager des grandes étapes:
Tout d'abord on peut voir la **three-way handshake** typique de TCP entre le trafic entrant, ici transformé très probablement en `10.0.2.215` par Envoy et mon pod. (SYN - SYN, ACK - ACK)

Enuite on peut observer la requête "GET" (_via HTTP/1.1_) en réponse à ma requête curl. Ici aussi, la source du trafic entrant (ingress) semble masquée par le SNAT.

Ce qui me semble pertinent d'être noté est que l'on peut voir ici:
`Sep 30 17:37:09.963: 10.0.2.215:51732 (host) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-stack FORWARDED (TCP Flags: ACK, PSH)`
La réponse qu'Hubble observe semble être est envoyé vers l'identité **"host"**. C'est qui est asez interessant. Il faut savoir qu'Envoy est déployé en **deamonSet**.
Une piste légitime serait d'assumer que derrière cette identité host se cache Envoy car après tout c'est lui qui a initié la connexion. Le trafic retour pourrait alors aussi lui être redirigé de cette manière mais cela reste un point à creuser, notamment car le système d'identité Cilium ainsi que son mode de fonctionnement pourrait fausser cette théorie. Une autre piste pourrait être que le trafic observé au niveau du Pod provient de 10.0.2.215, tandis que Hubble est capable d'associer les événements HTTP à l'adresse externe 90.110.5.2. Les expérimentations du Devlog 20 avaient déjà montré que la Gateway/Envoy établit une communication backend vers le Pod, ce qui explique que la connexion soit évaluée comme provenant du cluster au niveau de la politique réseau.

## Étape 4: observation de la gateway, recherche du trafic réel

En se reseignant un peu plus en détail sur notre gataway nous pouvons observer quelque chose de préoccupant :

```bash
➜  homelab-k8s git:(main) kubectl describe service cilium-gateway-public-gateway -n gateway-system
Name:                     cilium-gateway-public-gateway
Namespace:                gateway-system
Labels:                   gateway.networking.k8s.io/gateway-name=public-gateway
                          io.cilium.gateway/owning-gateway=public-gateway
Annotations:              <none>
Selector:                 <none>
Type:                     LoadBalancer
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.98.222.177
IPs:                      10.98.222.177
LoadBalancer Ingress:     192.168.1.193 (VIP)
Port:                     port-80  80/TCP
TargetPort:               80/TCP
NodePort:                 port-80  31719/TCP
Endpoints:                <none>
Port:                     port-443  443/TCP
TargetPort:               443/TCP
NodePort:                 port-443  31041/TCP
Endpoints:                <none>
Session Affinity:         None
External Traffic Policy:  Cluster
Internal Traffic Policy:  Cluster
Events:                   <none>
```

Je m'attendais à pouvoir filtrer le trafic de la gateway via hubble, cepdant comme le montre l'ouput ci-dessus la gateway n'est relié à aucun Selector, n'a aucun endpoint. Tout me laisse penser que la gateway, crée via Cilium, utilise un moyen de communication différent de `Selector -> EndpointSlice`.

```text
LoadBalancer(Relié à la gateway, IP: 192.168.1.193)
        |
Service de de la gateway (IP: 10.98.222.177)
        |
pod Envoy
```

Cela complique la recherche du trafic et également la piste du proxy Envoy.

J'ai également listé les pods Envoy :

```bash
cilium-envoy-ldhw2  → 192.168.1.52   node3
cilium-envoy-mgbdp  → 192.168.1.50   master
cilium-envoy-vj9qh  → 192.168.1.110  node2
```

Aucun n'est associé à l'adresse ip **10.0.2.215** qui reste inconnue jusqu'à présent.

Aussi, les commandes suivantes:

```bash
kubectl get pods -A | grep 10.0.2.215
kubectl get svc -A | grep 10.0.2.215
kubectl get endpointslice -A | get 10.0.2.215
```

ne retournent rien. Nous pouvons donc conclure pour le moment, à partir des commandes éffectuée et des information rassemblées que cette ip n'est pas associé à :

- un pod;
- un service;
- Un endpointSlice;

Sa provenance, d'un point de vue des objets Kubernetes "pur" n'est pour le moment innexpliquée: Ce n'est ni une IP de Pod, de Service ou d'EndpointSlice. Il faut donc inspecter directement le réseau du nœud.

Ces nouveaux résultats nous permettent presque certainement de remettre en cause une des hypothèses principale :

"10.0.2.215 est associée à un pod envoy et attribut son IP pour éffectuer du SNAT".

Un détail important à noter est que dans les logs nous pouvons voir `10.0.2.215:53638 (host) <- nginx:80`.
Cilium associe l'identité **host** à cette ip, aussi, les adresses des Pods de mon cluster se situent dans la plage 10.0.0.0/8. Cela rend plausible l'hypothèse d'une adresse de Pod, cependant cette plage est-elle réellement exclusivement réservée aux Pods ?

Nous pouvons donc assumer que "10.0.2.215" est probablement un pod ? Mais nous ne savons pas encore d'où Cilium obtient cette ip.

## Étape 5: observation au sein du nœud

Découverte majeur ! En me connectant en SSH sur le nœud 3 (nœud hébergeant mon application) et en effectuant la commande suivante : `alexandre@node3:~$ ip addr | grep 10.0.2.215` nous obtenons **inet 10.0.2.215/32 scope global cilium_host**. La théorie précédente est donc écartée.

On voit aussi que Cilium à associé plusieurs route à cette IP

```bash
10.0.0.0/24 via 10.0.2.215 dev cilium_host proto kernel src 10.0.2.215 mtu 1450
10.0.1.0/24 via 10.0.2.215 dev cilium_host proto kernel src 10.0.2.215 mtu 1450
10.0.2.0/24 via 10.0.2.215 dev cilium_host proto kernel src 10.0.2.215
10.0.2.215 dev cilium_host proto kernel scope link
```

L'interface est aussi décrit comme "Cilium_host" ce qui coresspond à l'identité observé jusqu'à présent dans les logs.

Cela permet d'établir un chemin réseau beaucoup plus clair.
Pour reprendre les logs précédents :

```bash
➜  experimentations git:(main) ✗ hubble observe --pod nginx/nginx-deployment-b995944fb-8v6jb -f
Sep 30 17:37:09.960: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: SYN)
Sep 30 17:37:09.960: 10.0.2.215:51732 (host) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-stack FORWARDED (TCP Flags: SYN, ACK)
Sep 30 17:37:09.961: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: ACK)
Sep 30 17:37:09.961: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Sep 30 17:37:09.962: 90.110.5.2:52306 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) http-request FORWARDED (HTTP/1.1 GET https://projet-himmel.duckdns.org/)
Sep 30 17:37:09.963: 10.0.2.215:51732 (host) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-stack FORWARDED (TCP Flags: ACK, PSH)
Sep 30 17:37:09.965: 90.110.5.2:52306 (ingress) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) http-response FORWARDED (HTTP/1.1 200 6ms (GET https://projet-himmel.duckdns.org/))
Sep 30 17:37:10.338: 90.110.5.2:52306 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) http-request FORWARDED (HTTP/1.1 GET https://projet-himmel.duckdns.org/favicon.ico)
Sep 30 17:37:10.339: 90.110.5.2:52306 (ingress) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) http-response FORWARDED (HTTP/1.1 404 1ms (GET https://projet-himmel.duckdns.org/favicon.ico))
Sep 30 17:38:10.339: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
Sep 30 17:38:10.339: 10.0.2.215:51732 (host) <- nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-stack FORWARDED (TCP Flags: ACK, FIN)
Sep 30 17:38:10.339: 10.0.2.215:51732 (ingress) -> nginx/nginx-deployment-b995944fb-8v6jb:80 (ID:30589) to-endpoint FORWARDED (TCP Flags: ACK)
```

Les observations permettent maintenant d'identifier **10.0.2.215** comme l'adresse IPv4 de l'interface **cilium_host** du nœud 3. Le trafic observé par Hubble est donc traité par le datapath Cilium du nœud, avant d'atteindre le Pod nginx 10.0.2.72. En revanche, nous n'avons pas encore reconstruit précisément le chemin emprunté par le paquet avant son apparition au niveau de cilium_host.

Le problème étant résolu il nous reste des autres points à clarifier, que ce passe-t-il avant que le data path cilium agisse ?
Quand est-il de la gateway et de son LoadBalancer (ip 192.168.1.193), de l'ip public "90.110.5.2" ?

Pour le moment nous avons quelque chose qui pourrait s'approcher de cela :

```text
???
|
192.168.1.193
|
???
|
10.0.2.215 / cilium_host
|
10.0.2.72 / nginx
```

Mais il manque encore des étapes cruciales: Pourquoi Huuble nous montre simultanément:

```text
TCP :
10.0.2.215:51732
        |
10.0.2.72:80
```

et

```text
HTTP :
90.110.5.2:52306
        |
nginx:80
```

Cela soulève encore plus de questions :

- Pourquoi Hubble présente-t-il 10.0.2.215:51732 au niveau des événements TCP, alors qu'il associe la requête HTTP à 90.110.5.2:52306 ?
- Où est passé 192.168.1.193, le VIP de la Gateway ?
- Est-ce que 10.96.184.22, le ClusterIP de nginx-service, apparaît quelque part dans le datapath ?

# Prochaine du lab:

- Où et comment le Service nginx-service / ClusterIP 10.96.184.22 intervient-il réellement dans le trafic observé ?
  - Observer la Gateway avec Hubble
  - Chercher le trafic correspondant au Service/ClusterIP
  - Comparer ce que Hubble montre :
    - côté Gateway
    - côté Service/datapath
    - côté Pod
  - Vérifier expérimentalement si nous pouvons retrouver 10.96.184.22 dans les événements
  - Comprendre à quel endroit Cilium fait la sélection du backend.

Et ensuite répondre à cette question capable d'éclairer l'ensemble : pourquoi je vois 10.0.2.215 au niveau TCP alors que Hubble connaît 90.110.5.2 au niveau HTTP ?
