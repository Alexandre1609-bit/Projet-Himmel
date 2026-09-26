L'un de mes 3 pods Falco était en CrashLoopBackOff. Ne connaissant pas la cause j'ai du investiguer afin de déterminer d'où le problème venait
Dans ce "lab" de troobleshooting j'expose mes théorie en même temps d'avancer sur le problème, pour enfin le résoudre.
Le but de cette démarche est de comprendre le problème en lui-même, comprendre comment le résoudre et le fonctionnement sous-jacent des choses impacté, ici inotify.

# 1. Affichage des pods

```bash
NAME          READY   STATUS             RESTARTS          AGE
falco-4kmcd   2/2     Running            56 (35m ago)      98d
falco-5dpd7   0/2     CrashLoopBackOff   156 (3m51s ago)   13d
falco-n2xnf   2/2     Running            54 (35m ago)      98d
```

Rien qu'avec cet output nous pouvons déjà écarter plusieurs problèmes, le pod n'est pas en pending, ce n'est pas une erreur du scheduler qui n'arrive pas à lui trouver une place et calculer les ressources nécessaires. Ni une erreur de PVCs, ici quelque chose nuit à la bonne initialisation du pod, après l'étape du scheduler

```bash
NAME          READY   STATUS             RESTARTS        AGE   IP           NODE        NOMINATED NODE   READINESS GATES
falco-4kmcd   2/2     Running            56 (40m ago)    98d   10.0.1.237   pnode2
falco-5dpd7   0/2     CrashLoopBackOff   158 (85s ago)   13d   10.0.2.237   node3
falco-n2xnf   2/2     Running            54 (40m ago)    98d   10.0.0.225   masterode
```

On peut voir aussi qu'uniquement le pod sur le node3 est impacté, les autres n'ont rien malgré des restarts récents, ce qui laisse penser que le problème est local et non généralisé sur le cluster.

Nous pouvons voir que l'erreur apparaît alors que les composants initiaux sont déjà créés, après que l'image 'falco security' a été pull, peut-être une erreur avec l'image ? Cela serait étrange car les 2 autres conteneurs utilisent la même.

# 2. Describe yaml du pod concerné

```yaml
Name:             falco-5dpd7
Namespace:        falco
Priority:         0
Service Account:  falco
Node:             node3/192.168.1.52
Start Time:       Sat, 12 Sep 2026 22:09:44 +0200
Labels:           app.kubernetes.io/instance=falco
app.kubernetes.io/name=falco
controller-revision-hash=79697d469c
pod-template-generation=10
Annotations:      checksum/certs: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
checksum/config: 6b2f493eeae541257fcea2ccfd738d25e9172bf0b56d80004b82907e332fcdee
checksum/rules: e8859594409a91a14d99b170af6cde04d4fd854e4b951c7585d3185977d69dca
kubectl.kubernetes.io/restartedAt: 2026-05-15T23:32:32+02:00
Status:           Running
IP:               10.0.2.237
IPs:
IP:           10.0.2.237
Controlled By:  DaemonSet/falco
Init Containers:
falco-driver-loader:
Container ID:  containerd://c9b58892ec7e5662b11a1d2176fe47a5a61abd744c861453a3eaf4fdc791d082
Image:         docker.io/falcosecurity/falco-driver-loader:0.43.1
Image ID:      docker.io/falcosecurity/falco-driver-loader@sha256:e8043a73b3fe5b9cdeee7d04985f9a1efab06b023930997087e8c4447c48a963
Port:
Host Port:
Args:
auto
State:          Terminated
Reason:       Completed
Exit Code:    0
Started:      Sat, 26 Sep 2026 11:34:57 +0200
Finished:     Sat, 26 Sep 2026 11:34:58 +0200
Ready:          True
Restart Count:  3
Environment:
HOST_ROOT:                         /host
FALCOCTL_DRIVER_CONFIG_NAMESPACE:  falco (v1:metadata.namespace)
FALCOCTL_DRIVER_CONFIG_CONFIGMAP:  falco
Mounts:
/etc/falco/config.d from specialized-falco-configs (rw)
/host/boot from boot-fs (ro)
/host/etc from etc-fs (ro)
/host/lib/modules from lib-modules (rw)
/host/proc from proc-fs (ro)
/host/usr from usr-fs (ro)
/root/.falco from root-falco-fs (rw)
/var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-4bb74 (ro)
falcoctl-artifact-install:
Container ID:  containerd://7f5d5817d3537fec39e31fbafcc0827c6b79dabd08c3f48d75e24109549b05cf
Image:         docker.io/falcosecurity/falcoctl:0.12.2
Image ID:      docker.io/falcosecurity/falcoctl@sha256:0d3bddce03a26365b86e6ff1aa5c51965d2e16569e8cf8b3e37a3d3ef186dc9b
Port:
Host Port:
Args:
artifact
install
--log-format=json
State:          Terminated
Reason:       Completed
Exit Code:    0
Started:      Sat, 26 Sep 2026 11:34:58 +0200
Finished:     Sat, 26 Sep 2026 11:35:12 +0200
Ready:          True
Restart Count:  0
Environment:
Mounts:
/artifactstate from artifact-state-dir (rw)
/etc/falcoctl from falcoctl-config-volume (rw)
/plugins from plugins-install-dir (rw)
/rulesfiles from rulesfiles-install-dir (rw)
/var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-4bb74 (ro)
Containers:
falco:
Container ID:  containerd://62b20c31d6a0db497006745863943d1ee3d3170ef8a2f372fd8a5e5d52e04f42
Image:         docker.io/falcosecurity/falco:0.43.1
Image ID:      docker.io/falcosecurity/falco@sha256:b4166a61f41e2fa638c041cac881d8bb32c284e3aaf282fdfed80f15f6eb55e3
Port:          8765/TCP
Host Port:     0/TCP
Args:
/usr/bin/falco
State:          Waiting
Reason:       CrashLoopBackOff
Last State:     Terminated
Reason:       Error
Exit Code:    1
Started:      Sat, 26 Sep 2026 12:16:38 +0200
Finished:     Sat, 26 Sep 2026 12:16:38 +0200
Ready:          False
Restart Count:  92
Limits:
cpu:     1
memory:  1Gi
Requests:
cpu:      100m
memory:   512Mi
Liveness:   http-get http://:8765/healthz delay=0s timeout=5s period=15s #success=1 #failure=3
Readiness:  http-get http://:8765/healthz delay=0s timeout=5s period=15s #success=1 #failure=3
Startup:    http-get http://:8765/healthz delay=3s timeout=5s period=5s #success=1 #failure=20
Environment:
HOST_ROOT:            /host
FALCO_HOSTNAME:        (v1:spec.nodeName)
FALCO_K8S_NODE_NAME:   (v1:spec.nodeName)
Mounts:
/etc/falco from rulesfiles-install-dir (rw)
/etc/falco/config.d from specialized-falco-configs (rw)
/etc/falco/falco.yaml from falco-yaml (rw,path="falco.yaml")
/etc/falco/rules.d from rules-volume (rw)
/host/dev from dev-fs (ro)
/host/etc from etc-fs (ro)
/host/proc from proc-fs (rw)
/host/run/containerd/containerd.sock from container-engine-socket-3 (rw)
/host/run/crio/crio.sock from container-engine-socket-4 (rw)
/host/run/host-containerd/containerd.sock from container-engine-socket-2 (rw)
/host/run/k3s/containerd/containerd.sock from container-engine-socket-5 (rw)
/host/run/podman/podman.sock from container-engine-socket-1 (rw)
/host/var/run/docker.sock from container-engine-socket-0 (rw)
/root/.falco from root-falco-fs (rw)
/sys/kernel from sys-fs (ro)
/sys/module from sys-module-fs (rw)
/usr/share/falco/plugins from plugins-install-dir (rw)
/var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-4bb74 (ro)
falcoctl-artifact-follow:
Container ID:  containerd://03a4a098706642c62b4f7dfbd810ce825b0b7592262e4f42626e18aed32497b0
Image:         docker.io/falcosecurity/falcoctl:0.12.2
Image ID:      docker.io/falcosecurity/falcoctl@sha256:0d3bddce03a26365b86e6ff1aa5c51965d2e16569e8cf8b3e37a3d3ef186dc9b
Port:
Host Port:
Args:
artifact
follow
--log-format=json
State:          Waiting
Reason:       CrashLoopBackOff
Last State:     Terminated
Reason:       Error
Exit Code:    1
Started:      Sat, 26 Sep 2026 12:18:14 +0200
Finished:     Sat, 26 Sep 2026 12:20:07 +0200
Ready:          False
Restart Count:  68
Environment:
Mounts:
/artifactstate from artifact-state-dir (rw)
/etc/falcoctl from falcoctl-config-volume (rw)
/plugins from plugins-install-dir (rw)
/rulesfiles from rulesfiles-install-dir (rw)
/var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-4bb74 (ro)
Conditions:
Type                        Status
PodReadyToStartContainers   True
Initialized                 True
Ready                       False
ContainersReady             False
PodScheduled                True
Volumes:
[omitted]
Events:
Type     Reason          Age                       From     Message

---

Warning  BackOff         6d15h (x1628 over 6d20h)  kubelet  Back-off restarting failed container falco in pod falco-5dpd7_falco(bba5a717-a60c-4fc4-ad43-45b4ce370768)
Normal   SandboxChanged  45m                       kubelet  Pod sandbox changed, it will be killed and re-created.
Normal   Pulled          45m                       kubelet  Container image "docker.io/falcosecurity/falco-driver-loader:0.43.1" already present on machine
Normal   Created         45m                       kubelet  Created container: falco-driver-loader
Normal   Started         45m                       kubelet  Started container falco-driver-loader
Normal   Created         45m                       kubelet  Created container: falcoctl-artifact-install
Normal   Pulled          45m                       kubelet  Container image "docker.io/falcosecurity/falcoctl:0.12.2" already present on machine
Normal   Started         45m                       kubelet  Started container falcoctl-artifact-install
Normal   Pulled          45m                       kubelet  Container image "docker.io/falcosecurity/falcoctl:0.12.2" already present on machine
Normal   Created         45m                       kubelet  Created container: falcoctl-artifact-follow
Normal   Started         45m                       kubelet  Started container falcoctl-artifact-follow
Normal   Created         44m (x2 over 45m)         kubelet  Created container: falco
Normal   Started         44m (x2 over 45m)         kubelet  Started container falco
Normal   Pulled          44m (x3 over 45m)         kubelet  Container image "docker.io/falcosecurity/falco:0.43.1" already present on machine
Warning  BackOff         43s (x248 over 45m)       kubelet  Back-off restarting failed container falco in pod falco-5dpd7_falco(bba5a717-a60c-4fc4-ad43-45b4ce370768)
```

# 3. Logs du pod

Intéressant, en consultant les logs on se rend compte que la valeur hostname du node3 a été changée, peut-être une manipulation que j'ai faite dont je ne me souviens plus ? Cela exclut potentiellement des erreurs réseau, argocd ou autre, on peut se concentrer sur une erreur humaine ?

```bash
Sat Sep 26 10:21:51 2026: Falco version: 0.43.1 (x86_64)
Sat Sep 26 10:21:51 2026: Falco initialized with configuration files:
Sat Sep 26 10:21:51 2026:    /etc/falco/config.d/engine-kind-falcoctl.yaml | schema validation: ok
Sat Sep 26 10:21:51 2026:    /etc/falco/falco.yaml | schema validation: ok
Sat Sep 26 10:21:51 2026: System info: Linux version 6.8.0-139-generic (buildd@lcy02-amd64-036) (x86_64-linux-gnu-gcc-13 (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0, GNU ld (GNU Binutils for Ubuntu) 2.42) #139-Ubuntu SMP PREEMPT_DYNAMIC Sat Aug  1 03:52:05 UTC 2026
Sat Sep 26 10:21:51 2026: Loaded plugin 'container@0.6.3' from file /usr/share/falco/plugins/libcontainer.so
Sat Sep 26 10:21:51 2026: [libs]: container: Enabled 'podman' container engine.
Sat Sep 26 10:21:51 2026: [libs]: container: * enabled container runtime socket at '/host/run/podman/podman.sock'
Sat Sep 26 10:21:51 2026: [libs]: container: Enabled 'docker' container engine.
Sat Sep 26 10:21:51 2026: [libs]: container: * enabled container runtime socket at '/host/var/run/docker.sock'
Sat Sep 26 10:21:51 2026: [libs]: container: Enabled 'cri' container engine.
Sat Sep 26 10:21:51 2026: [libs]: container: * enabled container runtime socket at '/host/run/containerd/containerd.sock'
Sat Sep 26 10:21:51 2026: [libs]: container: * enabled container runtime socket at '/host/run/crio/crio.sock'
Sat Sep 26 10:21:51 2026: [libs]: container: * enabled container runtime socket at '/host/run/k3s/containerd/containerd.sock'
Sat Sep 26 10:21:51 2026: [libs]: container: * enabled container runtime socket at '/host/run/host-containerd/containerd.sock'
Sat Sep 26 10:21:51 2026: [libs]: container: Enabled 'containerd' container engine.
Sat Sep 26 10:21:51 2026: [libs]: container: * enabled container runtime socket at '/host/run/host-containerd/containerd.sock'
Sat Sep 26 10:21:51 2026: [libs]: container: Enabled 'lxc' container engine.
Sat Sep 26 10:21:51 2026: [libs]: container: Enabled 'libvirt_lxc' container engine.
Sat Sep 26 10:21:51 2026: [libs]: container: Enabled 'bpm' container engine.
Sat Sep 26 10:21:51 2026: Loading rules from:
Sat Sep 26 10:21:51 2026:    /etc/falco/falco_rules.yaml | schema validation: ok
Sat Sep 26 10:21:51 2026:    /etc/falco/rules.d/my-rules.yaml | schema validation: ok
Sat Sep 26 10:21:51 2026: Hostname value has been overridden via environment variable to: node3
Error: could not initialize inotify handler
```

Avec le describe du pod en -o yaml on a pu obtenir un exit code de 1, cela ne nous avance pas plus, en se renseignant cela indique juste une erreur de compilation du module noyau ou d'eBPF, des erreurs de syntaxe dans les règles YAML ou un problème de configuration des plugins, un code d'erreur avec de multiple interprétations. Je vais dans le doute consulter mon fichier 'falco-rules' même si je ne l'ai pas modifié depuis.
Les logs du conteneur actuel sont les mêmes que ceux du 'previous'. Mes règles sont chargées avec **'schema validation: ok'** donc le problème ne vient pas de ça. Le problème viendrait d'avant ou d'après ? L'erreur semble venir d'**inotify**, on va comparer avec les autres pods falco !

# 4. Résolutions et apprentissage

Le problème était dû aux limites **'max_user_instances'** et **'max_user_watches'** qui étaient trop basses. J'ai pu résoudre ce problème en consultant une ancienne PR résolue. **(https://github.com/falcosecurity/falco/issues/3200#issuecomment-2117159225)**

On conclut que le problème était dû aux limites d'inotify, mais inotify c'est quoi ? C'est 'un mécanisme du noyau Linux permettant de surveiller les changements dans les systèmes de fichiers (création, modification, suppression de fichiers).' Dans le contexte de Falco, l'utilisation d'inotify permet de détecter des activités suspectes liées aux fichiers, telles que la modification de binaires critiques ou l'exécution de scripts malveillants depuis un répertoire spécifique.

- Différence entre max_user_instances et max_user_watches:
  - Max_user_instances : Limite le nombre d'instances inotify par utilisateur. Chaque instance correspond généralement à un processus ou une application
    qui surveille le système de fichiers. La valeur par défaut est 128. Si cette limite est atteinte, les applications échouent avec l'erreur "EMFILE" ("Too many open files").

  - Max_user_watches : Limite le nombre total de fichiers et répertoires surveillés (watches) à travers toutes les instances d'un utilisateur.
    La valeur par défaut est 'souvent' 8192. (Les noyaux récents peuvent ajuster automatiquement ?).
    Si cette limite est atteinte, les applications échouent avec l'erreur "ENOSPC" ("No space left on device") lors de l'ajout de nouveaux watches.

  - Une instance inotify est créée par un appel système (inotify_init() ou inotify_init1()).
    Concrètement c'est un descripteur de fichier (un entier) qui représente une boîte de surveillance.
    À l'intérieur on peut ajouter autant de watches que l'on veut (inotify_add_watch()).

Les évènements (création, modification, suppression...) des objets surveillés sont mis dans une file d'évènements associée à cette instance, que l'application lit avec read().

En comparant les limites (par défaut et celles actualisées) on obtient :

```bash
alexandre@node2:~$ cat /proc/sys/fs/inotify/max_user_instances
128
cat /proc/sys/fs/inotify/max_user_watches
60281
```

et sur le 3

```bash
alexandre@node3:~$ cat /proc/sys/fs/inotify/max_user_instances
8192
cat /proc/sys/fs/inotify/max_user_watches
1048576
```

# 5. Hypothèse

La limite de 128 était plutôt faible, j'avais effectué des tests sur mon application nginx.
Mon pod nginx se trouve sur le node3. Les tests menés visaient à déclencher mes règles falco, ce qui a pu faire augmenter les détections.
De ce fait, l'une des limites a dû être atteinte et placer le pod en CrashLoopBackOff.

Afin de vérifier cette hypothèse, je me pose la question suivante :

**"Est-ce que je peux mesurer la consommation actuelle et identifier les processus qui utilisent inotify ?"**

Question sur laquelle je me pencherais prochainement.

J'avais écarté un problème de scheduler au début, de réseau...
en essayant de reproduire la timeline des évènement on obtient le schéma suivant :

```
Scheduler
│
│ ressources Kubernetes suffisantes
▼
Pod Falco → node3
│
▼
kubelet démarre le conteneur
│
▼
Falco initialise sa configuration
│
▼
Falco demande l'initialisation de son mécanisme inotify
│
▼
Noyau Linux
│
└── limite atteinte / insuffisante
│
▼
erreur
│
▼
exit 1
│
▼
CrashLoopBackOff
```
