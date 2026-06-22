# Architecture Réseau (Network Plan)

## Contrainte Physique
Mon cluster est situé dans une pièce éloignée de la Box Internet principale, sans possibilité de tirer un câble Ethernet à travers le domicile. J'ai écarté l'utilisation de prises CPL en raison de la présence de multiprises qui dégradent le signal.

## Solution : WiFi Bridge
Pour garantir la connectivité tout en isolant le lab, j'ai opté pour une architecture en "îlot" :

### 1. L'Uplink : TP-Link RE605X
Ce répéteur agit comme une passerelle. Il se connecte au WiFi domestique et délivre la connexion via son port Ethernet RJ45. Il permet aux serveurs d'accéder à Internet pour les mises à jour et le téléchargement des images conteneurs.

### 2. Core Switch : TP-Link TL-SG108E
J'ai choisi un switch administrable de couche 2.
* **Intérêt technique :** Ce modèle permet la configuration de **VLANs** (802.1Q).
* **Objectif :** Cela me permettra d'expérimenter la segmentation réseau (séparation des flux de management et des flux applicatifs) comme dans un datacenter réel, dépassant ainsi la simple mise en réseau "plug & play".

## Plan d'Adressage (IPAM)
Le réseau local s'appuiera sur la plage `192.168.1.0/24` (héritée de la Box via le bridge), avec des IPs statiques assignées aux nœuds pour garantir la stabilité des services Kubernetes.
