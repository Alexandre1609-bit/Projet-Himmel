#!/bin/bash
set -euo pipefail

ENDPOINT=https://127.0.0.1:2379
CACERT=/etc/kubernetes/pki/etcd/ca.crt
CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key

KEEP=5
DATE=$(date +%F_%H%M%S)
BACKUP_DIR=/var/backups/etcd
SNAPSHOT=$BACKUP_DIR/snapshot-$DATE.db

e() { etcdctl --endpoints="$ENDPOINT" --cacert="$CACERT" --cert="$CERT" --key="$KEY" "$@"; }



e snapshot save "$SNAPSHOT"
chmod 640 "$SNAPSHOT" && chgrp alexandre "$SNAPSHOT"
cd "$BACKUP_DIR"
sha256sum "snapshot-$DATE.db" | tee "$SNAPSHOT.sha256"
chmod 640 "$SNAPSHOT.sha256" && chgrp alexandre "$SNAPSHOT.sha256"
ls -1 snapshot-*.db | head -n -"$KEEP" | xargs -r -I{} rm -f {} {}.sha256
