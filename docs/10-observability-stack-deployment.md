# Journal d'avancement - Déploiement de la stack d'observabilité : Connexion de Prometheus via DNS interne à Grafana, configuration de helm.values, import du dashboard "15757"

Aujourd'hui marque un moment clé dans l'évolution du cluster. En effet, nous sommes enfin arrivés au point de pouvoir visualiser les premiers logs du cluster. Pour ce faire, nous avons dû connecter Prometheus à Grafana, configurer des data sources et tout ce qui suit. Je reviendrai dans ce court devlog sur les différents points et problèmes rencontrés lors de la connexion de Prometheus à Grafana, et je finirai par un petit mot car cette étape m'est très importante.

## 1. Connexion de Prometheus à Grafana

- **DNS Kubernetes interne :** Kubernetes dispose d'un système **DNS** interne géré par **CoreDNS**. Chaque service dans le cluster reçoit automatiquement un nom **DNS** suivant la convention **<service>.<namespace>.svc.cluster.local**. Cela permet à n'importe quel pod de joindre n'importe quel autre service par nom, peu importe sur quel nœud physique il tourne. L'URL utilisée pour connecter Grafana à Prometheus est _"http://prometheus-kube-prometheus-prometheus.svc.cluster.local:9000"_.

- **Data source :** Dans le manifest ArgoCD de Grafana, j'ai dû configurer la data source afin de permettre à Grafana de récupérer les métriques exposées par Prometheus. Cette connexion s'effectue via l'API HTTP de Prometheus, généralement exposée sur le port 9090.

- **Grafana et NodePort :** J'ai rencontré un petit problème avec Grafana lors de mon accès au dashboard. Grafana était en **ClusterIP** et ne parlait qu'en interne. Le **NodePort** s'est imposé comme choix évident afin que je puisse accéder à l'interface Grafana depuis ma machine.

```bash
service:
    type: NodePort
    nodePort: 30081
```

- **Import du dashboard "15757" :** J'ai opté pour le dashboard **15757** car il est assez répandu et que j'en avais déjà entendu parler dans diverses vidéos.

- **Interprétation du dashboard :** Je rencontre encore des difficultés à interpréter le dashboard. Rome ne s'est pas construite en un jour, mais outre cela il est complet : network, namespace, utilisation CPU/Mémoire, QoS...

## 2. Étape clé

Cette étape représente pour moi une vraie avancée dans le cluster. J'ai toujours été curieux et, en regardant des vidéos, en lisant des articles, en apprenant, je voyais toujours des dashboards Grafana avec des logs complexes et des chiffres partout. Je ne pensais pas être capable d'en arriver là moi aussi; je voyais ça comme quelque chose de lointain, inatteignable.

Hier, en liant Prometheus à Grafana, j'ai compris que oui, moi aussi j'en étais capable. Pouvoir enfin visualiser le cluster, autrement que par du code et des commandes CLI, fut une vraie satisfaction.

J'ai encore beaucoup à apprendre, beaucoup de choses à relire et à réviser, mais ce n'est que le début !
