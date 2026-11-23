# Runbook : restauration etcd en place (masterode)

Restaurer la base etcd du cluster à partir d'un snapshot, directement sur le control plane `masterode` (192.168.1.50), avec un retour arrière possible à chaque étape.

| | |
|---|---|
| Cluster | kubeadm, un seul control plane, etcd en static pod, 3 nœuds physiques |
| Nœuds | `masterode` 192.168.1.50 (control plane), `pnode2` 192.168.1.110, `node3` 192.168.1.52 |
| Outils | `etcdctl` / `etcdutl` 3.5.25 (rôle Ansible `etcd-install`), serveur etcd 3.5.24 |
| Durée mesurée | ~20 min de préparation sans coupure, puis ~10 min d'indisponibilité de l'API |

*À noter, ici deux de mes nœuds ont des erreurs dans leur nom 'masterode' au lieu de 'masternode' et 'pnode2' au lieu de 'node2". J'ai volontairement laissé ces noms là car ils sont important, par exemple l'etcd_name doit être égal à 'masterode' et non masternode.*

*Un correctif sera déployé plus tard car cela intervient directement sur le cluster, et peut avoir un impact sur kubernetes (identifie un nœud par son nom), etcd (dans --name et --initial-cluster) et les certificats du control plane crées par kubeadm avec le nom du nœud.*

## Cas d'usage

- Données du cluster corrompues ou supprimées par erreur (namespace effacé, `kubectl delete` malheureux, etc.).
- Exercice de restauration planifié.

Hors périmètre : la perte complète de `masterode` (disque mort, réinstallation de l'OS). Ce cas relève d'une reconstruction du cluster, pas d'une restauration.

## Perte de données (RPO)

Tout ce qui a changé après le snapshot utilisé est perdu. Argo CD resynchronise ce qui est décrit dans Git ; les modifications faites à la main ne reviennent pas.

## Règles d'exécution

- Toutes les commandes se lancent dans un shell root sur `masterode` (`sudo -i`), sauf mention « PC » ou « worker ».
- Taper les commandes critiques sur une seule ligne. Un collage de plusieurs lignes peut insérer des caractères parasites (`^[[200~`) ou laisser le shell bloqué sur une invite `>` : dans ce cas, `Ctrl+C` et recommencer.
- Chaque phase se termine par une condition **STOP**. Si elle est remplie, ne pas passer à la suite.

---

## Variables

```bash
export ETCDCTL_API=3
export ENDPOINT=https://127.0.0.1:2379
export CACERT=/etc/kubernetes/pki/etcd/ca.crt
export CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key
export KUBECONFIG=/etc/kubernetes/admin.conf

export ETCD_NAME=masterode
export ETCD_PEER=https://192.168.1.50:2380

export DATE=$(date +%F_%H%M)
export BACKUP_DIR=/var/backups/etcd
export SNAPSHOT=$BACKUP_DIR/snapshot-$DATE.db
export STATE_DIR=/root/restore-$DATE            # états avant/après + chrono
export MANIFESTS_OFF=/root/manifests-off-$DATE

mkdir -p "$STATE_DIR" "$MANIFESTS_OFF"
alias e='etcdctl --endpoints=$ENDPOINT --cacert=$CACERT --cert=$CERT --key=$KEY'
chrono() { echo "$(date +%T) $1" | tee -a "$STATE_DIR/chrono.txt"; }
```

`chrono "texte"` horodate chaque étape dans `chrono.txt`, ce qui permet de calculer le RTO à la fin.

Sauvegarder l'environnement, pour pouvoir reprendre si la session SSH coupe :

```bash
{ declare -p ETCDCTL_API ENDPOINT CACERT CERT KEY KUBECONFIG ETCD_NAME ETCD_PEER DATE BACKUP_DIR SNAPSHOT STATE_DIR MANIFESTS_OFF; alias e; declare -f chrono; } > "$STATE_DIR/env.sh"
```

Reprise après coupure : `sudo -i` puis `source /root/restore-*/env.sh`.

---

## Phase 0 : vérifications (cluster en service)

```bash
chrono "phase 0 début"

# Les paramètres de restauration doivent correspondre à etcd.yaml
grep -E -- '--name=|--initial-advertise-peer-urls=|--initial-cluster=|--data-dir=' /etc/kubernetes/manifests/etcd.yaml
# attendu : --name=masterode, https://192.168.1.50:2380, --data-dir=/var/lib/etcd

# hostPath en DirectoryOrCreate : si /var/lib/etcd n'existe pas au redémarrage,
# etcd démarre silencieusement sur une base vide (voir phase 4)
grep -A3 'hostPath' /etc/kubernetes/manifests/etcd.yaml

etcdctl version && etcdutl version     # attendu : 3.5.25
e endpoint health
e endpoint status -w table

# Espace disque : l'ancienne base est conservée à côté de la nouvelle
du -sh /var/lib/etcd
df -h /var
```

**STOP si :** une valeur de `etcd.yaml` diffère des variables, etcd n'est pas `healthy`, ou l'espace libre sur `/var` est inférieur à 3 fois la taille de `/var/lib/etcd`.

---

## Phase 1 : état de référence

```bash
chrono "phase 1 début"

kubectl get nodes -o wide            > "$STATE_DIR/before-nodes.txt"
kubectl get pods -A -o wide          > "$STATE_DIR/before-pods.txt"
kubectl get ns                       > "$STATE_DIR/before-ns.txt"
kubectl get applications -n argocd   > "$STATE_DIR/before-argo.txt" 2>&1
e get / --prefix --keys-only | grep -c .  > "$STATE_DIR/before-keys.txt"

cat "$STATE_DIR/before-keys.txt"
grep -vE 'Running|Completed' "$STATE_DIR/before-pods.txt"    # pods déjà en échec avant l'opération
```

Les pods déjà en échec à ce stade servent de référence en phase 5 : le critère est « pas pire qu'avant », pas « zéro erreur ».

### Marqueur « avant » (exercice uniquement)

Un ConfigMap créé avant le snapshot doit réapparaître après la restauration. Sans ce marqueur, impossible de distinguer une restauration réussie d'une opération sans effet.

```bash
kubectl create configmap restore-marker-before -n default --from-literal=date="$DATE"
kubectl get configmap restore-marker-before -n default
```

**STOP si :** un des fichiers `before-*.txt` est vide (kubeconfig manquant), ou si `restore-marker-before` n'existe pas.

---

## Phase 2 : snapshot et copie hors nœud

```bash
chrono "phase 2 début"
```

```bash
e snapshot save "$SNAPSHOT"
chmod 600 "$SNAPSHOT"
etcdutl snapshot status "$SNAPSHOT" -w table
sha256sum "$SNAPSHOT" | tee "$SNAPSHOT.sha256"
```

`TOTAL KEYS` est plus élevé que le compte de la phase 1 : `snapshot status` inclut les anciennes révisions des clés, `get --keys-only` seulement les valeurs actuelles.

### Marqueur « après » (exercice uniquement)

Créé une fois le snapshot réussi. Il ne fait pas partie du snapshot et doit donc disparaître après la restauration.

```bash
kubectl create configmap restore-marker-after -n default --from-literal=date="$DATE"
```

### Copie hors nœud

Le snapshot appartient à root (mode 600) : une copie temporaire lisible par l'utilisateur SSH est nécessaire.

```bash
# masterode (root)
install -m 600 -o alexandre "$SNAPSHOT" "$SNAPSHOT.sha256" /home/alexandre/
```

```bash
# PC, dans le dossier de sauvegarde (remplacer la date)
scp alexandre@192.168.1.50:'snapshot-AAAA-MM-JJ_HHMM.db*' .
sha256sum snapshot-AAAA-MM-JJ_HHMM.db
cat snapshot-AAAA-MM-JJ_HHMM.db.sha256
```

Les deux empreintes doivent être identiques. `sha256sum -c` ne fonctionne pas ici, le fichier `.sha256` contenant le chemin du nœud.

```bash
# masterode (root), une fois l'empreinte vérifiée
rm /home/alexandre/snapshot-*.db*
```

**STOP si :** le snapshot n'a pas de copie vérifiée sur le PC.

---

## Phase 3 : arrêt du control plane

Retirer les manifests des static pods du dossier surveillé par le kubelet suffit à arrêter etcd, l'API server, le controller-manager et le scheduler. L'API est indisponible à partir d'ici ; les applications continuent de tourner sur les nœuds.

```bash
chrono "phase 3 début" && mv /etc/kubernetes/manifests/*.yaml "$MANIFESTS_OFF"/ && ls "$MANIFESTS_OFF"
# attendu : etcd.yaml kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml
```

Vérifier l'arrêt des conteneurs (jusqu'à ~30 s), relancer la commande tant qu'elle affiche des lignes :

```bash
crictl ps 2>/dev/null | grep -E 'etcd|kube-apiserver|kube-controller|kube-scheduler'
```

**STOP si :** le conteneur `etcd` tourne encore après 2 min. Ne pas toucher à `/var/lib/etcd` ; investiguer avec `crictl ps -a` et `journalctl -u kubelet`.

---

## Phase 4 : restauration

Mise de côté de l'ancienne base. Elle n'est pas supprimée : c'est elle qui sert au rollback.

```bash
chrono "phase 4 début" && mv /var/lib/etcd "/var/lib/etcd.before-restore-$DATE" && ls -d /var/lib/etcd*
```

Restauration (sur une seule ligne) :

```bash
etcdutl snapshot restore "$SNAPSHOT" --data-dir /var/lib/etcd --name "$ETCD_NAME" --initial-cluster "$ETCD_NAME=$ETCD_PEER" --initial-advertise-peer-urls "$ETCD_PEER" --bump-revision 1000000000 --mark-compacted
```

Résultat attendu : uniquement des lignes `info`, dont `restored snapshot`. L'`added-peer-id` doit être identique à l'ID affiché par `endpoint status` en phase 0.

`--bump-revision` et `--mark-compacted` : la restauration ramène le compteur de révisions d'etcd en arrière, alors que les composants qui surveillent l'API (watch) ont mémorisé des révisions plus récentes et risqueraient d'ignorer des changements. Le compteur est donc avancé très loin et l'ancien historique marqué comme compacté, ce qui force tous les clients à tout relire.

Vérification de l'emplacement (piège `DirectoryOrCreate`) et des droits :

```bash
ls -l /var/lib/etcd/member/ && chmod 700 /var/lib/etcd && ls -ld /var/lib/etcd
# attendu : snap/ et wal/, puis drwx------ root root /var/lib/etcd
```

**STOP si :** la restauration affiche `error`/`fatal`, ou `/var/lib/etcd/member/` ne contient pas `snap/` et `wal/`. Ne pas remettre les manifests ; corriger puis relancer la restauration.

---

## Phase 5 : redémarrage et vérifications

```bash
chrono "phase 5 début" && mv "$MANIFESTS_OFF"/*.yaml /etc/kubernetes/manifests/ && ls /etc/kubernetes/manifests/
```

Attendre que les 4 conteneurs soient `Running` (l'API server démarre en dernier) :

```bash
crictl ps 2>/dev/null | grep -E 'etcd|kube-apiserver|kube-controller|kube-scheduler'
```

Santé d'etcd et de l'API :

```bash
e endpoint health && kubectl get --raw='/readyz' && echo && chrono "API de nouveau joignable"
```

Redémarrer le kubelet sur les 3 nœuds, pour qu'aucun ne conserve un état antérieur à la restauration (recommandation de la documentation Kubernetes) :

```bash
# masterode (root)
systemctl restart kubelet && systemctl is-active kubelet
```

```bash
# workers : ssh -t pour que sudo puisse demander le mot de passe
ssh -t alexandre@192.168.1.110 'sudo systemctl restart kubelet && systemctl is-active kubelet'   # pnode2
ssh -t alexandre@192.168.1.52  'sudo systemctl restart kubelet && systemctl is-active kubelet'   # node3
```

### Vérifications

```bash
# Marqueurs (exercice uniquement) : seul restore-marker-before doit apparaître
kubectl get cm -n default | grep restore-marker

kubectl get nodes

# Pods en échec : comparer avant / après
echo "== AVANT =="; grep -vE 'Running|Completed' "$STATE_DIR/before-pods.txt"; echo "== APRÈS =="; kubectl get pods -A | grep -vE 'Running|Completed'

kubectl get applications -n argocd
```

État final et validation (la comparaison ne porte que sur les noms des namespaces, la colonne `AGE` changeant forcément) :

```bash
kubectl get nodes -o wide > "$STATE_DIR/after-nodes.txt"; kubectl get pods -A -o wide > "$STATE_DIR/after-pods.txt"; kubectl get ns > "$STATE_DIR/after-ns.txt"
diff <(awk '{print $1}' "$STATE_DIR/before-ns.txt") <(awk '{print $1}' "$STATE_DIR/after-ns.txt") && echo "namespaces identiques" && chrono "restauration validée"
```

```bash
# PC
curl -sI https://projet-himmel.duckdns.org | head -1     # attendu : 200
```

### Critères de réussite

| Vérification | Attendu |
|---|---|
| `e endpoint health` | `healthy` |
| `kubectl get --raw='/readyz'` | `ok` |
| `kubectl get nodes` | 3 nœuds `Ready` |
| Namespaces | mêmes noms qu'avant |
| Pods en échec | pas plus qu'en phase 1 |
| Argo CD | applications `Synced` |
| `restore-marker-before` | présent |
| `restore-marker-after` | absent |
| Site public | HTTP 200 |

---

## Rollback

**Déclencher le rollback si, 10 min après le début de la phase 5 :**
- l'API server ne répond pas (`kubectl get --raw=/readyz` échoue) ;
- le conteneur etcd redémarre en boucle (`crictl ps -a | grep etcd`) ;
- des nœuds restent `NotReady` ;
- `restore-marker-before` est absent (mauvaise base ou base vide).

```bash
chrono "ROLLBACK début"

# 1. Arrêter le control plane, puis attendre que la commande crictl n'affiche plus rien
mv /etc/kubernetes/manifests/*.yaml "$MANIFESTS_OFF"/
crictl ps 2>/dev/null | grep -E 'etcd|kube-apiserver'

# 2. Conserver la base restaurée pour analyser l'échec
mv /var/lib/etcd "/var/lib/etcd.restored-failed-$DATE"

# 3. Remettre l'ancienne base
mv "/var/lib/etcd.before-restore-$DATE" /var/lib/etcd && ls /var/lib/etcd/member/

# 4. Redémarrer
mv "$MANIFESTS_OFF"/*.yaml /etc/kubernetes/manifests/
systemctl restart kubelet
```

Redémarrer ensuite le kubelet des workers (mêmes commandes qu'en phase 5), noter `chrono "ROLLBACK fin"`, puis refaire les vérifications de la phase 5. En cas de rollback, `restore-marker-after` doit **exister**.

---

## Après une restauration réussie

```bash
kubectl delete configmap restore-marker-before -n default     # exercice uniquement
cat "$STATE_DIR/chrono.txt"                                   # RTO = de "phase 3 début" à "restauration validée"
```

Conserver `/var/lib/etcd.before-restore-$DATE` quelques jours, puis le supprimer une fois le cluster stable.

## Historique des exercices

| Date | Résultat | Coupure API | RTO | Remarques |
|---|---|---|---|---|
| 2026-11-23 | Réussi | 5 min 46 s | 10 min 03 s | Snapshot de 262 MB. Seul pod en échec (falco sur masterode) déjà en échec avant. |

## Références

- Kubernetes, *Restoring an etcd cluster* : https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#restoring-an-etcd-cluster
- etcd, *Disaster recovery* : https://etcd.io/docs/v3.5/op-guide/recovery/
