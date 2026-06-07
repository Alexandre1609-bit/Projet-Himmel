# Devlog 14: Implémentation de la sécurité (partie 2)

Lors du précédent devlog, j'abordais le déploiement de mes premières règles (_policies_) Kyverno, marquant le début officiel de la sécurisation de mon cluster. Ce que j'ignorais alors, c'est qu'à l'instant même où j'effectuerais mon premier `git push`, j'allais déclencher une série d'incidents en chaîne exigeant un débogage intense : applications désynchronisées, paralysie totale du CNI (Cilium), dysfonctionnement critique d'ArgoCD, et arrêt complet du flux GitOps...

Ce devlog revient en détail sur les causes profondes de ces incidents, les approches employées pour les détecter et les stratégies adoptées pour restaurer la stabilité du cluster.

## 1. Problèmes rencontrés et solutions apportées

### A. Incident majeur : système étouffé

Avant l'introduction de mes premières règles sur GitHub, le cluster fonctionnait de manière parfaitement fluide. Ce n'est qu'après avoir poussé les configurations et repris le travail le lendemain que j'ai constaté des anomalies majeures. En vérifiant l'état de mes applications ArgoCD, le constat fut sans appel :

```bash
➜ kyverno git:(main) kubectl get application -n argocd
NAME              SYNC STATUS   HEALTH STATUS
app-of-apps       OutOfSync     Healthy
falco             OutOfSync     Healthy
grafana           OutOfSync     Healthy
kyverno           OutOfSync     Healthy
monitoring        OutOfSync     Healthy
prometheus        OutOfSync     Healthy
sealed-secrets    OutOfSync     Healthy
```

N'ayant pas immédiatement fait le lien avec mes récentes modifications, j'ai entamé une phase d'investigation systématique : lister les pods, analyser leurs états respectifs, exécuter des commandes `describe` et éplucher les logs. Des pistes concrètes ont rapidement émergé des événements système :

```
Warning  PolicyViolation  15m  kyverno-scan  Pod kube-system/cilium-n559n: fail; Privileged mode is forbidden in containers (Pod). Please set privileged to false.

Warning  PolicyViolation  15m  kyverno-scan  Pod kube-system/etcd-masterode: fail; Privileged mode is forbidden in containers (Pod). Please set privileged to false.

Warning  PolicyViolation  15m  kyverno-scan  Pod prometheus/prometheus-kube-prometheus-operator-6b88c5bc85-s7kzl: fail; Privileged mode is forbidden in containers (Pod). Please set privileged to false.

Warning  PolicyViolation  15m  kyverno-scan  Pod kube-system/coredns-7c65d6cfc9-lj9hn: fail; Privileged mode is forbidden in containers (Pod). Please set privileged to false.
```

Ces alertes ne représentaient qu'une fraction du problème, mais elles ont soulevé une question fondamentale : _« Ayant conçu des règles de sécurité tout en prévoyant des exceptions précises via des `PolicyException` pour Cilium et Falco, pourquoi l'intégralité du cluster est-il bloquée ? »_

Après plusieurs heures de recherche, j'ai identifié le mécanisme de verrouillage. La quasi-totalité de mes pods d'infrastructure ne contenaient pas explicitement les champs `privileged: false` ou `allowPrivilegeEscalation: false` dans leurs manifestes d'origine. De plus, j'avais déployé une règle `require-labels` imposant la présence de métadonnées spécifiques, générant des erreurs systématiques du type `Policy require-labels-on-resources failed`.

Cette combinaison de politiques trop globales a provoqué une **boucle infinie** : Kyverno bloquait le fonctionnement d'ArgoCD avant même que ce dernier ne puisse appliquer les `PolicyException` nécessaires pour débloquer la situation. N'étant jamais déployées, ces exceptions ne pouvaient pas protéger Cilium, Falco et les autres briques du système, mettant ces services vitaux hors-ligne.

Pour résoudre cette crise critique, j'ai construit une stratégie en trois points :

1. **L'isolation des espaces système via `matchConstraints` :** J'ai fait le choix radical d'exclure l'intégralité des namespaces d'infrastructure de l'application de mes règles. L'argument architectural est simple : les namespaces système ont un cycle de vie interne, n'interagissent pas directement avec l'extérieur et ne sont pas manipulés par les utilisateurs finaux. Préserver leurs privilèges natifs garantit la stabilité opérationnelle du cluster. Les politiques Kyverno strictes sont ainsi réservées exclusivement aux namespaces applicatifs actuels et futurs.
2. **Le recours à la mutation avant validation :** L'usage de `MutatingPolicy` ciblant les workloads, les batchs et les pods (incluant les `containers` et `initContainers`) s'est avéré indispensable. Plutôt que de rejeter un manifeste incomplet, Kyverno injecte désormais automatiquement les champs `privileged: false` et `allowPrivilegeEscalation: false` si ceux-ci sont absents, normalisant ainsi l'état des ressources en amont de la phase de validation.
3. **Le déploiement chirurgical manuel :** Pour briser le cercle vicieux et redonner la main à ArgoCD, j'ai temporairement contourné le flux GitOps en appliquant les manifestes d'exception mis à jour directement via `kubectl apply`. J'en ai profité pour corriger une omission en ajoutant une exception légitime pour `Node Exporter` (Prometheus).

**La leçon apprise :** La mutation des ressources en amont est une approche infiniment plus robuste que le simple rejet. L'utilisation conjointe des `MutatingPolicy` et des `ValidatingPolicy` est essentielle pour garantir à la fois la conformité et la résilience du cluster.

### B. Le piège de l'Autogen de Kyverno

Mon application `monitoring` refusait obstinément de se synchroniser, renvoyant une erreur de conformité à la norme RFC 1123 :

_`a lowercase RFC 1123 subdomain must consist of lower case alphanumeric characters, '-' or '.', and must start and end with an alphanumeric character.`_

Ce standard interdit formellement l'usage de majuscules dans le nommage des ressources Kubernetes, or l'erreur pointait explicitement vers la chaîne `initContainers`.

J'ai découvert que Kyverno possède un mécanisme d'auto-génération de sous-règles appelé **Autogen**. Lorsqu'il analyse une règle ciblant les Pods, il génère automatiquement des déclinaisons notamment pour les `initContainers` en conservant la casse textuelle originale (le 'C' majuscule de `initContainers`). Kubernetes rejetait donc les ressources générées en arrière-plan à cause de cette violation.

Pour pallier ce défaut, j'ai appliqué deux correctifs :

- J'ai converti l'intégralité des noms de mes règles personnalisées en minuscules strictes, en utilisant exclusivement le tiret comme séparateur (`init-containers`).
- J'ai neutralisé le comportement de Kyverno en insérant l'annotation suivante au sein de mes politiques : `pod-policies.kyverno.io/autogen-controllers: "none"`.

**La leçon apprise :** En environnement GitOps, il est crucial de garder une maîtrise totale sur l'état déclaré du cluster. Laisser un outil tiers générer des ressources automatisées et invisibles en dehors de Git compromet la traçabilité. L'intégralité de la configuration doit être explicite et contrôlée à la source.

### C. Le problème du produit cartésien (_cross-product_)

Certaines de mes `ValidatingPolicy` stagnaient à l'état `False` et saturaient les logs avec des erreurs de droits d'accès telles que :

`missing permissions: get apps/v1, Resource=jobs` ou `get batch/v1, Resource=deployments`.

L'anomalie provenait d'une mauvaise écriture de mes fichiers YAML, où j'avais regroupé plusieurs groupes d'API au sein d'un unique bloc `resourceRules` : `apiGroups: ["", "apps", "batch"]`. Lors de l'évaluation, Kyverno générait le produit cartésien de toutes les combinaisons possibles, y compris des associations totalement invalides au sein de l'architecture Kubernetes (comme l'association du groupe `batch` aux `deployments`, ou du groupe `apps` aux `jobs`).

La correction a consisté à segmenter de manière stricte mes `resourceRules` en blocs distincts et cohérents par groupes d'API :

YAML

```
matchConstraints:
  resourceRules:
    - apiGroups: [""]
      resources: ["pods"]
    - apiGroups: ["apps"]
      resources: ["deployments", "daemonsets", "statefulsets"]
    - apiGroups: ["batch"]
      resources: ["jobs", "cronjobs"]
```

**La leçon apprise :** La définition des règles d'admission requiert une grande précision chirurgicale. Combiner aveuglément les groupes d'API force le moteur à évaluer des ressources inexistantes, entraînant des erreurs de permissions et des instabilités logiques.

### D. Le piège des faux positifs en langage CEL

Lors de la phase d'évaluation de mes règles, plusieurs workloads légitimes mais dépourvus de configuration de sécurité explicite se retrouvaient bloqués par des erreurs récurrentes :

_`Pod prometheus/... : [evaluation] error; failed to load context: no such key: template`_.

En approfondissant le fonctionnement des expressions CEL j'ai compris qu'accéder à un champ non déclaré dans un manifeste ne retournait pas une valeur fausse (`false`), mais levait une exception bloquante. Par conséquent, une condition comme `c.securityContext.privileged == false` provoquait un crash de l'évaluation si le bloc `securityContext` ou la clé `privileged` n'était pas initialement définie par l'utilisateur.

Pour sécuriser l'exécution de ces règles, j'ai systématiquement encapsulé les accès aux champs optionnels derrière la fonction de contrôle native `has()`. De plus, l'adoption systématique de la politique de mutation évoquée au point **A** garantit désormais que ces champs existent toujours au moment de la validation, éliminant définitivement ces faux positifs.

### E. Perte des accès et boucle de crash sur ArgoCD

J'avais égaré le mot de passe d'administration d'ArgoCD. Pensant résoudre rapidement le problème en appliquant une méthode de réinitialisation classique, j'ai supprimé le secret Kubernetes associé. Cette action a eu un effet de bord immédiat : le pod `argocd-server` est tombé dans une boucle d'échec critique (`CrashLoopBackOff`), affichant une erreur fatale :

_`secret "argocd-secret" not found`_.

Ce comportement découle directement du principe _« Secure by Default »_ adoptée par ArgoCD. Au démarrage, le serveur d'API exige la présence de son secret d'authentification. S'il constate son absence, il préfère s'interrompre immédiatement par mesure de sécurité plutôt que de s'exposer dans un état non protégé ou accessible sans filtre. Le composant refusant de s'initialiser, il était impossible de le laisser recréer ses clés de manière autonome.

L'accès a été restauré en injectant manuellement un nouveau secret structuré via `kubectl`, doté d'un hash de mot de passe temporaire connu. Cette injection a permis de valider le contrôle de sécurité d'ArgoCD, de stabiliser le pod en état `Running` et de procéder à la configuration finale d'un nouveau mot de passe administrateur via l'interface utilisateur.

**La leçon apprise :** On ne supprime jamais une brique d'authentification d'infrastructure à chaud sans avoir minutieusement validé la procédure de remplacement ou configuré au préalable une méthode d'accès alternative.

## 2. Concepts appris

**Produit cartésien dans Kubernetes :** J'ai compris que Kubernetes (et particulièrement Kyverno) utilise le principe mathématique du produit cartésien lorsqu'on lui fournit plusieurs listes d'attributs. En déclarant plusieurs groupes d'API et types de ressources dans un même bloc `ValidatingPolicy`, le moteur génère l'ensemble de toutes les combinaisons possibles, ce qui tentait de créer des correspondances invalides et générait des erreurs de permissions.

**Langage CEL et fonction `has()` :** En parcourant la documentation de Kyverno, j'ai constaté l'évolution vers l'utilisation du CEL (_Common Expression Language_) pour l'écriture des policies. Lors de la rédaction de mes règles, je me suis rapidement familiarisé avec ce langage (_dont la syntaxe rappelle celle de Python_) et ses fonctions natives. L'expression `has()`, par exemple, s'est révélée indispensable pour vérifier l'existence préalable d'un champ optionnel avant son évaluation, évitant ainsi les plantages d'exécution. _(Exemple : `has(object.spec.serviceAccountName) && object.spec.serviceAccountName in ['cilium', 'cilium-operator']`)_.

**Autogen Kyverno et norme RFC 1123 :** Cette phase de sécurisation m'a poussé à paramétrer en profondeur des outils jusqu'alors laissés dans leur configuration initiale. J'ai découvert la fonctionnalité d'**Autogen** de Kyverno, conçue pour générer automatiquement des règles dérivées pour les sous-ressources (comme les `initContainers`). L'ayant couplée à mes règles manuelles, cette automatisation a engendré des conflits de nommage bloquants en violant la norme de Kubernetes **RFC 1123**. Résoudre ce conflit m'a appris à comprendre les mécanismes d'auto-génération tout en assimilant les standards de nommage du cluster.

**Philosophie « Secure by Default » et DevSecOps :** Les tentative de réinitialisation du mot de passe ArgoCD m'ont confronté de plein fouet à la réalité de la conception _Secure by Default_. C'est une illustration parfaite du principe de _Shift-Left_ en DevSecOps : la sécurité n'est pas une surcouche ajoutée après coup, elle est intrinsèque à l'initialisation de l'outil. Cette expérience a fondamentalement fait évoluer mon approche concernant l'intégration future de mes applications et la gestion rigoureuse des éléments sensibles comme les secrets Kubernetes.

## 3. Conclusion

Cette première phase de déploiement des politiques de sécurité aura été nettement plus technique et mouvementée que prévu. Les multiples obstacles rencontrés m'ont forcé à plonger au cœur des rouages internes de Kubernetes, de Kyverno et d'ArgoCD.

Faire face à des pannes en cascade dans un environnement réel est un exercice extrêmement formateur ! Cela permet de franchir le cap séparant la compréhension théorique de la véritable expérience pratique en ingénierie système. Savoir identifier ces comportements, anticiper les conflits entre les différents contrôleurs et maîtriser les outils de remédiation est un _acquis_ d'une valeur inestimable pour la suite de la construction du **Projet Himmel**.

Au-delà de la technique pure, cette épreuve m'a immergé dans les pratiques fondamentales du DevSecOps. J'ai pu expérimenter ce que signifie réellement une sécurité pensée dès la conception (_Shift-Left_), plutôt qu'ajoutée en correctif d'urgence. Ces incidents me motivent d'autant plus à faire preuve de patience, à réfléchir avant d'agir, et à adopter définitivement le réflexe _Secure by Default_ dans mon architecture. C'est la voie à suivre pour garantir un cluster stable, résilient et conforme aux exigences du monde de l'entreprise pour la suite de l'aventure !
