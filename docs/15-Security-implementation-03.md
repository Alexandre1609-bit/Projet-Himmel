# Devlog 15: Implémentation de la sécurité (partie 3)

Ce devlog marque la partie trois de la phase de déploiement et renforcement du cluster. Jusqu'à présent j'ai implémenté des règles, des alertes, du chiffrement de secrets mais pas de vérification de manifestes, de code, de vulnérabilités, aucun scan "concret". C'est donc tout naturellement que la décision d'intégrer une pipeline, dans un premier temps CI, s'est imposée. Je reviendrai dans ce devlog, dédié à la pipeline, sur le pourquoi l'avoir intégrée, les différents outils utilisés, les futures évolutions que j'ai prévues et enfin j'aborderai les différents concepts appris et révisés.

# 1. Pourquoi

Le choix d'intégrer une pipeline CI n'est pas anodin. Cette pipeline va directement venir renforcer la sécurité du cluster, en plus de vérifier le formatage de mes manifestes yaml. Intégrer une pipeline me permet de vérifier dans un premier temps les différents défauts de sécurité qui pourraient se trouver dans mes fichiers et dans mon code. Dans un second temps, elle me permet d'appliquer les standards du formatage de fichiers yaml. En outre, la pipeline est un outil nécessaire dans tout bon projet. La facilité d'implémentation, avec _GitHub actions_ et les gains obtenus sont tout simplement non négligeables.

# 2. Outils utilisés

J'ai décidé d'intégrer différents outils, du scan de vulnérabilités au scan "lint" de fichiers yaml. C'est à travers ces outils que la sécurité du cluster se voit renforcée.

- **Yamllint :** J'ai décidé d'introduire **Yamllint** afin d'appliquer les standards de formatage des fichiers yaml. Les premiers essais étaient concluants et m'ont retourné toutes les informations nécessaires concernant le formatage de mes fichiers. C'est grâce à cet outil que j'ai pu procéder à l'analyse et la correction du formatage de mes fichiers. Cet outil est crucial pour la bonne compréhension de mes fichiers et pour l'application des standards du typage yaml.

- **Trivy :** Trivy s'est vu naturellement sélectionné pour sa simplicité d'intégration et sa compréhension. Bien que Trivy puisse scanner les images, je l'utilise dans ma pipeline pour scanner les potentielles failles dans mes manifestes d'**IaC** (_yaml, terraform, ansible..._). J'ai aussi décidé d'intégrer ses fonctions de scan de secrets et de vulnérabilités (_CVEs_). Cela me permet de savoir, **à chaque push**, si mes fichiers comportent des vulnérabilités, des misconfigurations, ou des données sensibles.

- **GitLeaks :** J'ai décidé de coupler l'analyse de secrets via Trivy avec **GitLeaks**. Cet outil, très largement utilisé en entreprise me permet d'améliorer la détection de données sensibles. Le couplage **Trivy** / **Gitleaks** me permet de couvrir en totalité et en toute sérénité la présence de secrets dans le code, ce qui me permet de maintenir une certaine exigence sur la gestion des données sensibles.

- **Semgrep :** J'ai choisi Semgrep comme outil **SAST** afin d'analyser le code pour y trouver de potentielles vulnérabilités. Là où **Trivy** scanne mes fichiers, **Semgrep**, lui, analyse le code. L'ajout de Semgrep, en plus de Trivy, permet une analyse complète de l'ensemble des fichiers, que ce soit des manifestes ou du code.

Cette stack d'outils, bien que simple au premier abord me permet de couvrir un large éventail de scans de sécurité, tout en gardant une certaine simplicité.

# 3. Choix d'architecture

- **Sur Yamllint :** J'ai décidé de configurer un fichier .yamllint avec quelques règles customisées. Elles ont pour vocation d'ignorer les fichiers sensibles, augmenter la tolérance au nombre de caractères par ligne (par défaut 80). Mes fichiers contenant des _queries_ PromQL, des règles Kyverno, des chemins vers des manifestes... cette limite était trop faible, j'ai donc décidé de l'augmenter à 350, ce qui me semble être raisonnable dans mon cas.

- **Sur Trivy :** J'ai décidé d'inclure deux steps dédiés à Trivy dans la pipeline. Tout d'abord le premier step effectue un scan des fichiers, recherchant des misconfigurations, des secrets. Le deuxième step lui, scanne les fichiers à la recherche de vulnérabilités (_CVEs_) dans les fichiers. J'ai décidé de faire cela en deux steps distincts pour ne pas créer de conflits entre les scans. Trivy ne supportant pas, ou mal, la fusion de scans de misconfigurations et de vulnérabilités. Aussi, par défaut le type de scan lancé par Trivy est le scan **vuln**, **secret**. Dans mon deuxième step j'ai tout de même précisé le type de scan via `scanners: 'vuln'` afin de ne cibler uniquement les vulnérabilités et non les secrets, scannés au step d'avant.

- **Sur Gitleaks :** J'ai opté pour GitLeaks car il proposait une action officielle, documentée, mise à jour et utilisable. L'implémentation était simple et ne surchargeait pas la pipeline. J'ai cependant considéré une approche via **Detect-secrets**, de _Yelp_. Ce dernier ne possédant pas d'action officielle et nécessitant une implémentation native dans la pipeline, ce qui allait surcharger ce que je voulais simple de base, s'est vu placé en seconde option. Cela ne change en rien au fait que **Detect-secrets** reste une alternative solide et envisageable dans le futur si je venais à rencontrer des problèmes avec **GitLeaks**.

- **Sur Semgrep :** En me renseignant j'ai vu que Semgrep possédait une action, cependant cette dernière étant dépréciée j'ai dû changer d'approche. La documentation officielle, qui m'a bien aidé, indiquait d'implémenter Semgrep via une image docker, ce que j'ai fait. J'ai préféré isoler l'installation et le scan Semgrep dans un job à part pour plusieurs raisons :
  - L'installation via Docker nécessite un conteneur dédié pour Semgrep. Ce faisant, mes autres steps auraient été coupés du scan Semgrep car pas dans le même conteneur.
  - Un seul job aurait pu être suffisant si j'avais décidé d'implémenter l'entièreté de la pipeline dans un seul et même conteneur. Cependant cela aurait nécessité une installation native des outils dans le conteneur, surchargeant la pipeline.
  - Introduire un job dédié était plus simple: on fournit le conteneur, l'image et semgrep scanne mes fichiers dans son conteneur. Cela permet aussi une sécurité supplémentaire en évitant de regrouper l'ensemble des outils dans un seul et même conteneur.

# 4. Premiers résultats

Les premiers résultats de la pipeline étaient plutôt satisfaisants. En effet, aucune vulnérabilité critique ne fut trouvée par les scans Trivy et Semgrep, ce qui était fort étonnant. Cependant le test yamllint bloquait. En effet, comme dit précédemment, mes manifestes contiennent des lignes avec plus de 80 caractères, des espaces invisibles et ils manquaient certaines bonnes pratiques (début avec `---`, fin par une ligne vide...). Les premiers scans m'ont permis de remettre au propre mes manifestes, leur donnant une "nouvelle peau" et au passage, me permettant de corriger quelques morceaux de code incohérents. Voici quelques exemples d'erreurs rencontrées :
`Error: 10:81 [line-length] line too long (83 > 80 characters)`
`Error: 41:14 [new-line-at-end-of-file] no new line character at the end of file`
`Error: 4:8 [colons] too many spaces before colon`
Ces erreurs m'ont permis de réviser mon ancien code, comme les manifestes Ansible, et de corriger les erreurs typographiques en respectant les standards yaml.

Pour ce qui est des scans Trivy, ils ont trouvé un problème medium, lié à une règle Kyverno, car le namespace de déploiement est _kube-system_. Cela sera corrigé prochainement. Le reste s'est passé sans accroc.

```bash
Tests: 63 (SUCCESSES: 62, FAILURES: 1)
Failures: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 1, HIGH: 0, CRITICAL: 0)
```

Il en va de même pour la partie détection de secrets, gérée par Trivy et GitLeaks, qui n'ont rien remarqué de suspect :

```Bash
✅ No leaks detected
```

Enfin les scans Semgrep, eux aussi se sont passés correctement, retournant un rapport sans erreur :

```Bash
Scan Status │
└─────────────┘
  Scanning 54 files tracked by git with 2932 Code rules:

  Language      Rules   Files          Origin      Rules
 ─────────────────────────────        ───────────────────
  <multilang>      47      54          Pro rules    1872
  yaml             31      36          Community    1060
  terraform       101      11
```

```Bash
CI scan completed successfully.
  View results in Semgrep Cloud Platform:
    [https://semgrep.dev/orgs/.../findings?repo=.../...l&ref=refs/heads/main](https://semgrep.dev/orgs/.../findings?repo=.../...l&ref=refs/heads/main)
    [https://semgrep.dev/orgs/.../supply-chain/vulnerabilities?repo=.../...&ref=refs/heads/main](https://semgrep.dev/orgs/.../supply-chain/vulnerabilities?repo=.../...&ref=refs/heads/main)
  No blocking findings so exiting with code 0
```

# 5. Évolutions futures de la pipeline

- **SBOM (Syft + Grype) :** génération d'inventaire et scan CVEs sur les images

- **Scan d'images Docker :** Trivy image scan à chaque build

- **IRSA + OIDC :** attachement de rôles IAM AWS aux pods via OIDC, renforcement du principe de moindre privilège

# 6. Concepts appris et révisés

- **Trivy :** Scan de fichiers, d'images, de secrets... Autant sur mes manifestes que sur les composants des outils importés à la recherche de CVEs, contenues et comparées avec une bibliothèque interne.

- **Yamllint :** Là où j'étais conscient de l'existence de lint pour Python (pylint) ou autre langage de programmation, l'existence de lint pour des fichiers yaml, pourtant évidente, ne s'était pas imposée comme naturelle pour moi.

- **Semgrep :** Outil de scan statique du code (SAST). Permet une analyse du code, sans exécution, à la recherche de vulnérabilités, de patterns / motifs dangereux. Avec **semgrep ci**, les résultats sont envoyés vers Semgrep Cloud Platform pour analyse et suivi.

- **Scan vs SAST :** Le SAST analyse la logique interne du code source afin d'y trouver des vulnérabilités algorithmiques ou des failles d'injection, tandis qu'un Scanner global (SCA/IaC) inspecte l'écosystème qui l'entoure. Ce dernier traque les failles publiques (CVE) dans les dépendances et s'assure que les fichiers de configuration (manifestes entre autres) ne créent pas de brèches d'infrastructure. En somme, le SAST sécurise le comportement même d'un programme, là où le Scanner en verrouille les fondations et l'assemblage.

- **CVE :** Common Vulnerabilities and Exposures : Référentiel public géré par Mitre, qui attribue des identifiants uniques comme par exemple CVE-2024-12345 afin de cataloguer et identifier sans ambiguïté les vulnérabilités de sécurité informatique et les expositions connues.

- **Shift-Left :** Méthodologie de développement logiciel qui consiste à déplacer les activités de tests, d’assurance qualité et de sécurité vers le début du cycle de vie du développement. Plutôt que d’attendre la fin du processus pour détecter les défauts, cette approche intègre ces vérifications dès les phases de conception, de codage et de commit.
