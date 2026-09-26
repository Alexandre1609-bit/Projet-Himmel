# Lab — Recréation d'un Pod par un ReplicaSet

## Objectif

Le but de ce lab est d'observer comment un Pod est recréé à partir d'un ReplicaSet.

La chaîne d'événements que je souhaite initialement observer est la suivante :

```text
Suppression du Pod
        |
        v
    API Server
        |
        v
ReplicaSet Controller
        |
        v
Création d'un nouvel objet Pod
        |
        v
    API Server
        |
        v
    Scheduler
        |
        v
Attribution d'un nœud
        |
        v
     kubelet
        |
        v
       CRI
        |
        v
containerd / runtime
        |
        v
Conteneur démarré
```

Pour cette expérience, j'utilise mon application Nginx déjà existante.

Je vais supprimer un Pod et observer en parallèle l'avancée de sa création, notamment avec :

* `kubectl events`
* `kubectl get pods`
* `kubectl logs`
* `kubectl describe`

### Objectifs

* Confirmer mes connaissances sur le fonctionnement d'un ReplicaSet;
* Vérifier si le Deployment Controller intervient directement ou si le ReplicaSet Controller prend en charge la recréation du Pod;
* Vérifier comment le nouveau Pod est affecté à un nœud;
* Observer les différentes étapes du démarrage du conteneur.

---

## État initial

Le Pod est initialement présent sur `node3` :

```text
NAME                               READY   STATUS    RESTARTS   AGE    IP           NODE
nginx-deployment-b995944fb-bq8x2   1/1     Running   0          2m5s   10.0.2.141   node3
```

Après suppression du Pod, j'observe l'évolution du ReplicaSet :

```text
NAME                         DESIRED   CURRENT   READY   AGE
nginx-deployment-b995944fb   1         1         1       94d
nginx-deployment-b995944fb   1         0         0       94d
nginx-deployment-b995944fb   1         1         0       94d
nginx-deployment-b995944fb   1         1         1       94d
```

On peut interpréter cette évolution ainsi :

* le Pod est supprimé ;
* le nombre de Pods actuels passe de 1 à 0 alors que le nombre désiré reste à 1 ;
* le ReplicaSet Controller constate que l'état réel ne correspond plus à l'état désiré ;
* il crée un nouvel objet Pod via l'API Server ;
* le nouveau Pod est ensuite pris en charge par le kubelet du nœud concerné ;
* le conteneur est finalement créé et démarré.

*Il est important de préciser que le ReplicaSet Controller ne récupère pas directement l'état du nœud auprès du kubelet. Il travaille sur l'état des objets Kubernetes exposé par l'API Server et cherche en permanence à faire correspondre l'état réel à l'état désiré.*

---

## Le Scheduler n'est finalement pas intervenu

Une première hypothèse était que le nouveau Pod serait soumis au Scheduler afin qu'un nœud lui soit attribué.

L'observation du Pod a cependant permis de découvrir la présence du champ suivant :

```yaml
spec:
  nodeName: node3
```

Le nœud est donc explicitement défini dans la spécification du Pod.

`nodeName` n'est pas une préférence : il attribue directement le Pod à `node3`. Le Scheduler n'a donc pas besoin d'effectuer de sélection de nœud.

La chaîne réellement observée est donc :

```text
ReplicaSet Controller
        |
        v
Création du nouvel objet Pod
        |
        v
nodeName: node3 déjà défini
        |
        v
Scheduler contourné
        |
        v
kubelet de node3
        |
        v
CRI
        |
        v
containerd / runtime
        |
        v
Image déjà présente
        |
        v
Conteneur démarré
```

Cette observation permet de corriger mon hypothèse initiale : le Pod ne revient pas sur `node3` simplement parce qu'il y était précédemment. Il y revient parce que `nodeName: node3` est explicitement défini.

---

## Observation du ReplicaSet Controller

Les logs du `kube-controller-manager` montrent plusieurs synchronisations du ReplicaSet :

```text
I0926 15:01:59.662390       1 replica_set.go:679] "Finished syncing" logger="replicaset-controller" kind="ReplicaSet" key="nginx/nginx-deployment-b995944fb" duration="63.564291ms"
I0926 15:01:59.674879       1 replica_set.go:679] "Finished syncing" logger="replicaset-controller" kind="ReplicaSet" key="nginx/nginx-deployment-b995944fb" duration="12.400912ms"
I0926 15:01:59.675010       1 replica_set.go:679] "Finished syncing" logger="replicaset-controller" kind="ReplicaSet" key="nginx/nginx-deployment-b995944fb" duration="71.29µs"
I0926 15:01:59.870813       1 replica_set.go:679] "Finished syncing" logger="replicaset-controller" kind="ReplicaSet" key="nginx/nginx-deployment-b995944fb" duration="33.68µs"
```

Ces observations illustrent la boucle de réconciliation du ReplicaSet Controller : celui-ci synchronise régulièrement l'état observé avec l'état désiré.

La recréation du Pod s'effectue très rapidement, en quelques secondes au niveau de l'expérience complète, tandis que certaines opérations internes de synchronisation prennent seulement quelques millisecondes ou microsecondes.

---

## Image du conteneur

Les événements du nouveau Pod montrent également :

```text
Events:
  Type    Reason   Age   From     Message
  ----    ------   ----  -------  -------
  Normal  Pulled   10m   kubelet  Container image "nginx:1.14.2" already present on machine
  Normal  Created  10m   kubelet  Created container: nginx
  Normal  Started  10m   kubelet  Started container nginx
```

L'image `nginx:1.14.2` était déjà présente sur le nœud `node3`.

Le runtime n'a donc pas eu besoin de télécharger (`pull`) l'image depuis le registre. Il a pu utiliser directement l'image déjà présente localement sur le nœud.

Le `kubelet` demande au CRI de créer le conteneur, et le runtime utilise alors l'image locale disponible.

---

## Conclusion

Cette expérience confirme le rôle du ReplicaSet Controller dans le maintien du nombre désiré de Pods.

Elle permet également de mettre en évidence un point important : les différents composants Kubernetes ne se transmettent pas directement un Pod comme dans une chaîne linéaire. Ils observent et modifient l'état du cluster principalement via l'API Server.

Dans cette expérience, le Scheduler n'est pas intervenu car `nodeName: node3` était explicitement défini dans la spécification du Pod.

L'expérience permet donc de distinguer :

* le **ReplicaSet Controller**, qui maintient le nombre désiré de Pods ;
* le **Scheduler**, qui attribue normalement un nœud aux Pods non encore assignés ;
* le **kubelet**, qui prend en charge le Pod sur son nœud ;
* le **CRI**, qui sert d'interface entre le kubelet et le runtime ;
* **containerd**, qui prend ensuite en charge l'exécution du conteneur.
