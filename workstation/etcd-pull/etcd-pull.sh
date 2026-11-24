#!/bin/bash
set -euo pipefail

MASTERADDR=alexandre@192.168.1.50
DEST="$HOME/backups/etcd-himmel"

rsync -av -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$MASTERADDR":/var/backups/etcd/ "$DEST"
find "$DEST" -name 'snapshot-*' -mtime +30 -delete
