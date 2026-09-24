# Devlog 20: Expérimentation sur les CiliumNetworkPlicies (CNP)

## 1. Avant-propos

J'avais déjà précédemment essayé d'installer une première CiliumNetworkPolicy, qui c'était fini en échec. Le SNAT qu'**Envoy** et **Cilium** faisait empêchait de filtrer les paquet correctement via les champs **fromCIDR**, **toCIDR**. Pour ce faire je devrais désactiver le paramètre **masqurade** dans Cilium, qui me permettrait d'enlever une première couche de SNAT. Enfin, il restera le problème d'Envoy, qui lui reste à résoudre. J'ai en parallèle déployé une gateway (déployé avec son LoadBalancer) qui avait pour vocation première de me permettre de contourner ce problème de SNAT, mais visiblement cela n'a pas résolu le problème dans sa globalité. J'ai donc réessayer de déployer une police simple, le but était de la moduler en essayant diverses configurations afin de comprendre comment fonctionne le tout. À côté, je lançais des analyse avec **Hubble Observe** qui me permettais de voir si la police bloque bien les paquets, voir de où ils viennent. Dans ce devlog je reviendrais sur les diverse méthodes que j'ai pu essayais avec les résultats obtenus à chaque fois.

C'est lors de mon premier test que j'ai bloqué l'idnetité World. Le but ici était de voir si, malgré l'identité **World** bloqué j'avais toujours accès, via mon IP privé, à mon application. Cela s'est soldé par un échec. L'identité world bloque tout le trafic externe, oui, mais cela ajoute aussi le **deny** automatique de tous les autres pauets, question de sécurité, least-privilege. De ce fait, afin de résoudre ce problème, j'ai du essayer d'autoriser l'identité **cluster**. Cela m'a permis de lancer un pod de test dans mon cluster via **kubectl exec -it** et de lancer une requête **curl** qui a fonctionné. De cette façon j'ai pu voir que le trafic externe était bien bloqué, car mon applcation était innaccessible depuis mon téléphone (5G) mais bien accessible depuis un pod dans le cluster.

## 1. Test avec l'identité `world`

J'ai commencé avec une policy très simple ciblant mon endpoint Nginx :

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "l3-rule-test"
  namespace: nginx
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
    - fromEntities:
        - world
```

L'objectif était de vérifier si l'identité `world` permettait de contrôler le trafic externe.

Le résultat a été un blocage complet du trafic entrant. L'accès à l'application depuis l'extérieur retournait notamment :

```text
HTTP/1.1 503 Service Unavailable
server: envoy

upstream connect error or disconnect/reset before headers.
reset reason: connection timeout
```

Hubble confirmait que le trafic arrivant sur Nginx était refusé :

```text
Sep  7 19:26:33.630: 10.0.2.215:60562 (ingress) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) policy-verdict:none trafic_DIRECTION_UNKNOWN DENIED (TCP Flags: SYN)

Sep  7 19:26:33.630: 10.0.2.215:60562 (ingress) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) Policy denied DROPPED (TCP Flags: SYN)
```

Ce premier test m'a également permis de constater qu'une policy contenant une règle `ingress` rendait le trafic entrant restrictif : les sources non explicitement autorisées étaient refusées.

## 2. Autorisation de l'identité `cluster`

J'ai ensuite remplacé `world` par `cluster` :

```yaml
ingress:
  - fromEntities:
      - cluster
```

J'ai testé l'identité cluster afin d'autoriser les communications provenant du cluster lui-même. Les premiers essais m'ont permis de valider le comportement sur le trafic interne, mais je n'avais pas encore compris les résultats concernant l'accès externe.

La compréhension définitive est venue lors d'un test ultérieur, réalisé avec la même règle **fromEntities: cluster**, mais cette fois en observant précisément le chemin avec Hubble.

### 3. Test avec `fromCIDR`

J'ai ensuite voulu tester une approche basée uniquement sur les adresses IP privées :

```yaml
ingress:
  - fromCIDR:
      - 192.168.0.0/16
      - 10.0.0.0/8
      - 172.16.0.0/12
```

L'idée était d'autoriser les trois grandes plages privées et donc, en théorie, de permettre le trafic provenant de mon réseau local ainsi que celui provenant du réseau Kubernetes.

Pourtant, même un pod situé dans le cluster était bloqué :

```text
Sep 7 19:10:49.942: default/test-client:37162 (ID:37619) -> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) to-overlay FORWARDED (TCP Flags: SYN)

Sep 7 19:10:49.950: default/test-client:37162 (ID:37619) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) policy-verdict:none trafic_DIRECTION_UNKNOWN DENIED (TCP Flags: SYN)

Sep 7 19:10:49.950: default/test-client:37162 (ID:37619) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) Policy denied DROPPED (TCP Flags: SYN)
```

Ce résultat était intéressant : le simple fait qu'une adresse appartienne à une plage privée ne suffisait pas à permettre le trafic.

Lors d'un autre test, Hubble affichait une source `10.0.2.215`, qui appartient bien à `10.0.0.0/8`, mais le paquet était malgré tout refusé.

Cela montre que l'adresse IP visible à un moment donné du chemin ne suffit pas nécessairement à déterminer l'identité Cilium utilisée lors de l'évaluation de la policy.

## 4. Retour à `world` et observation avec Hubble

J'ai ensuite voulu comprendre plus précisément ce qui se passait entre la Gateway, Envoy et le pod Nginx.

Avec la policy :

```yaml
ingress:
  - fromEntities:
      - world
```

Hubble affichait :

```text
Sep 9 17:54:25.512: 10.0.1.210:34471 (ingress) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) to-overlay FORWARDED (TCP Flags: SYN)

Sep 9 17:54:25.524: 10.0.1.210:34471 (ingress) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) policy-verdict:none trafic_DIRECTION_UNKNOWN DENIED (TCP Flags: SYN)

Sep 9 17:54:25.524: 10.0.1.210:34471 (ingress) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) Policy denied DROPPED (TCP Flags: SYN)
```

Un élément important apparaît ici : alors que le client initial est externe au cluster, la connexion observée directement sur Nginx provient de `10.0.1.210`.

Cela m'a amené à distinguer deux connexions différentes :

```text
Client externe
     │
     │ HTTPS
     ▼
Gateway / Envoy
     │
     │ connexion upstream
     ▼
Cilium
     │
     ▼
Nginx
```

Le client externe peut donc être identifié comme `world` sur la connexion vers la Gateway, mais Envoy agit ensuite comme proxy et établit une nouvelle connexion vers le backend Nginx.

La policy appliquée directement sur Nginx ne voit donc pas nécessairement le client Internet original.

## 5. Test final avec `cluster`

Pour vérifier cette hypothèse, j'ai finalement utilisé :

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "l3-rule-test"
  namespace: nginx
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
    - fromEntities:
        - cluster
```

Cette fois, l'accès public à `projet-himmel.duckdns.org` fonctionne.

Depuis mon PC, la requête HTTPS retourne :

```text
HTTP/1.1 200 OK
server: envoy
x-envoy-upstream-service-time: 11
```

Hubble montre alors le chemin suivant :

```text
Sep 9 18:13:40.690: [pnode2]: 10.0.1.210:33765 (ingress) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) to-overlay FORWARDED (TCP Flags: SYN)

Sep 9 18:13:40.691: [pnode2]: 90.110.5.2:40320 (ingress) -> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) http-request FORWARDED (HTTP/1.1 GET https://projet-himmel.duckdns.org/)

Sep 9 18:13:40.709: [node3]: 10.0.1.210:33765 (ingress) -> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) policy-verdict:none trafic_DIRECTION_UNKNOWN ALLOWED (TCP Flags: SYN)
```

Un test depuis un téléphone connecté en 5G donne également un résultat similaire :

```text
Sep 9 18:19:24.045: [pnode2]: 10.0.1.210:44669 (ingress) <> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) to-overlay FORWARDED (TCP Flags: SYN)

Sep 9 18:19:24.046: [pnode2]: 104.28.42.25:18272 (ingress) -> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) http-request FORWARDED (HTTP/1.1 GET https://projet-himmel.duckdns.org/)

Sep 9 18:19:24.067: [node3]: 10.0.1.210:44669 (ingress) -> nginx/nginx-deployment-b995944fb-8trqq:80 (ID:30589) policy-verdict:none trafic_DIRECTION_UNKNOWN ALLOWED (TCP Flags: SYN)
```

Le résultat est particulièrement intéressant : avec `cluster` autorisé sur Nginx, une requête provenant d'Internet peut atteindre l'application à travers la Gateway.

## 6. Autre problème mineur

- Je me suis rendu compte que Grafana était déployé deux fois. Une premoère fois via la stack **Kube-Prometheus** et une seconde fois via une application ArgoCD. En me renseignant j'ai réalisé que l'instance déployé par Prometheus était inutile, j'ai donc désactivé depuis le manifeste de mon application Prometheus, le déploiement de Grafana.

## Conclusion

Ces tests montrent que la policy appliquée directement au pod Nginx n'est pas le bon endroit pour filtrer l'origine Internet lorsque l'application est placée derrière une Gateway/Envoy.

Le trafic peut être résumé ainsi :

```text
                    TRAFIC EXTERNE
                         │
                         │ world
                         ▼
                ┌─────────────────┐
                │ Gateway / Envoy │
                └────────┬────────┘
                         │
                         │ nouvelle connexion
                         │ source observée :
                         │ 10.0.1.210
                         ▼
                    ┌─────────┐
                    │ Cilium  │
                    │ policy  │
                    └────┬────┘
                         │
                         ▼
                      Nginx
```

Ainsi, `fromEntities: world` sur Nginx bloque la connexion backend provenant de la Gateway/Envoy.

À l'inverse, `fromEntities: cluster` autorise cette connexion backend. Une requête Internet peut donc indirectement atteindre Nginx via la Gateway publique.

Cela signifie que `fromEntities: cluster` ne doit pas être interprété comme « seuls les utilisateurs internes peuvent accéder à Nginx ». Dans cette architecture, cela signifie plutôt que « les connexions provenant d'une source que Cilium identifie comme appartenant au cluster peuvent atteindre Nginx ».

Cilium reste donc particulièrement intéressant pour la segmentation interne du cluster, mais le filtrage des clients Internet doit idéalement être effectué plus en amont, au niveau de la couche réseau/edge/firewall ou d'un composant capable de conserver et exploiter l'identité du client original.

Lorsque qu'une application sera composée de plusieurs composants (frontend, API, base de données, Redis, etc.), les CiliumNetworkPolicy deviendront beaucoup plus pertinentes pour contrôler précisément les communications entre workloads, par exemple en autorisant uniquement les connexions nécessaires entre l'API et PostgreSQL ou Redis si cela est installé un jour.
