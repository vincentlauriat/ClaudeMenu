# Architecture (miroir FR de ARCHITECTURE_EN.md)

```
┌─────────────────┐  security find-generic-password   ┌───────────────────────────┐
│ CredentialStore │ ◀──────────────────────────────── │ trousseau de session      │
└────────┬────────┘  repli ~/.claude/.credentials.json │ "Claude Code-credentials" │
         │ jeton (mémoire uniquement)                  └───────────────────────────┘
         ▼
┌──────────────────┐  GET api.anthropic.com/api/oauth/usage
│     UsageAPI     │ ───────────────────────────────▶ GaugeSnapshot (Meter[])
└──────────────────┘
┌──────────────────┐  ~/.claude/projects/**/*.jsonl (incrémental, offset par fichier)
│ TranscriptScanner│ ───────────────────────────────▶ TranscriptStats (+ JevWindow)
└──────────────────┘
┌──────────────────┐  rtk gain -d -f json (seulement si le binaire existe)
│     RTKGain      │ ───────────────────────────────▶ RTKStats
└──────────────────┘
         │                         ▲
         └─── UsageViewModel (@MainActor, timer 60 s) ───┘
                          │
                          ▼
             UsagePanelView (MenuBarExtra, style .window)
```

## Composants

| Composant | Rôle | Notes |
|---|---|---|
| `CredentialStore` | Lit le jeton OAuth de Claude Code | Trousseau via `/usr/bin/security` (l'outil même qui l'écrit, donc pas d'invite ACL supplémentaire) ; respecte `CLAUDE_CONFIG_DIR` ; refuse un jeton expiré et ne le renouvelle jamais |
| `UsageAPI` | Appelle l'endpoint d'usage OAuth, parse de façon générique | Tout objet racine portant `utilization` devient un `Meter` : `five_hour` → session, `seven_day` → all, `seven_day_<x>` → modèle `x` ; `extra_usage` est ignoré |
| `TranscriptScanner` | Acteur ; comptage exact des tokens et lecture des notices Jev | Offset d'octets par fichier, seules les lignes complètes sont consommées, messages assistant dédoublonnés par `message.id` (un message s'étale sur plusieurs lignes JSONL), purge des entrées antérieures à la fenêtre, fichiers non modifiés depuis le début de fenêtre ignorés |
| `RTKGain` | Cherche `rtk` dans les préfixes connus, lance `gain -d -f json`, agrège les lignes journalières en aujourd'hui / semaine / total | Tâche détachée en priorité utilitaire ; le bloc se masque si `rtk` est absent. RTK ne fournit que des totaux journaliers : une fenêtre hebdo commençant en milieu de journée compte ce jour entier |
| `JevDetector` + scanner | Détecte `~/.claude/plugins/cache/fast-jev-compaction` ; le scanner parse les notices `type: system` `fast-jev-compaction: kept K/M messages … (P% reduction …)` et `fallback to built-in summary` | Dédoublonnage par horodatage + texte (le hook journalise et affiche la même ligne) ; les lignes `decisions:` sont ignorées |
| `UsageMath` / `PaceProjection` | % d'atterrissage, %/h nécessaire vs courant, part journalière égale | Début de fenêtre = `resets_at − windowHours`. `isMeaningful` refuse toute projection avant 30 minutes et 5 % de fenêtre écoulés |
| `UsageViewModel` | Orchestre le rafraîchissement, expose l'état, lancement au démarrage (`SMAppService`) | Une seule instance. Les minuteurs tournent en mode `.common` du run loop, sans quoi ils s'arrêtent pendant que le popover est ouvert. Les tokens sont recomptés toutes les 60 s ; la jauge est appelée au plus toutes les 3 minutes, avec backoff exponentiel jusqu'à 15 minutes après un 429, en conservant le dernier relevé valide |
| `UsagePanelView` | Le panneau, 340 pt de large, hauteur selon les sections ouvertes | En-tête (% hebdo, compte à rebours, barre segmentée, phrase de rythme), carte budget, trois sections `DisclosureCard` (limites Anthropic par modèle, tokens consommés, économies des outils), carte réglages (actualiser / lancer au démarrage / quitter) |
| `Theme` + `DisclosureCard` / `InfoRow` / `ActionRow` / `SegmentedBar` | Briques de style Juicy | `DisclosureCard` est nommé ainsi pour ne jamais masquer `SwiftUI.Section` ; l'état ouvert/fermé est persisté via `@AppStorage` |

## Décisions

- **Pas de renouvellement du jeton** : il faudrait réécrire le nouveau jeton dans le trousseau,
  en concurrence avec Claude Code. Un jeton expiré s'affiche dans une carte d'erreur invitant
  à lancer `claude`.
- **Pas de sandbox** : l'app lit `~/.claude` et exécute `security` ; distribution hors App Store
  avec Developer ID et notarisation.
- **Parsing générique des jauges** : Anthropic ajoute des clés par modèle au fil du temps
  (`seven_day_opus`, `seven_day_sonnet`, autres) ; le panneau liste ce qui revient et embellit
  le nom.
- **UI en français** (2026-09-21, demande de Vincent) : le panneau est intégralement en français
  et utilise le formatage français (helpers `FR` : virgule décimale, durées `4 j 4 h`, `12,5 %`).
- **Matériau natif plutôt qu'un thème sombre peint** : aucun fond imposé, aucun schéma de
  couleurs forcé, la fenêtre `MenuBarExtra` laisse voir le matériau système et suit clair et
  sombre. Les cartes sont des opacités de `Color.primary`.
- **Hauteur** : les sections repliables laissent le popover s'ajuster à son contenu, plafonné à
  640 pt et défilant au-delà (mesuré : 521 pt tout replié, 559 pt par défaut, 640 pt tout ouvert).
- **`UsagePanelView(scrolls:)`** : le popover défile, mais `ImageRenderer` ne met pas en page un
  `ScrollView` ; le mode capture rend donc le même contenu sans ce conteneur.
- **La hauteur du conteneur défilant est concrète, jamais déduite** : un `ScrollView` n'a pas de
  hauteur intrinsèque, et dans une fenêtre `MenuBarExtra` cela réduit le popover à quelques points.
  `PanelSizer` mesure une copie non défilante via `NSHostingController.preferredContentSize`, et le
  panneau se remesure dès que `layoutSignature` change.

## Modes de développement

| Variable d'environnement | Effet |
|---|---|
| `CLAUDEMENU_DEBUG_WINDOW=1` | Ouvre aussi le panneau dans une fenêtre classique, dimensionnée à la taille naturelle du panneau |
| `CLAUDEMENU_SNAPSHOT=<chemin.png>` | Rend le panneau hors écran avec `ImageRenderer`, écrit le PNG et quitte. Ne lit rien de l'écran : utilisable pendant un appel ou un partage d'écran |
| `CLAUDEMENU_SNAPSHOT_DARK=1` | Rend cette capture en mode sombre |
| `CLAUDEMENU_MEASURE=1` | Affiche la taille que le popover demanderait, puis quitte. Seule vérification fiable de la hauteur du panneau |
| `CLAUDEMENU_MEASURE_PLAIN=1` | Avec la précédente, mesure le contenu sans son conteneur défilant |
| `CLAUDEMENU_TIMERTEST=1` | Déclenche un minuteur planifié et celui de l'app dans chaque mode du run loop, affiche les compteurs puis quitte |

## Build & release

XcodeGen (`project.yml`) → `ClaudeMenu.xcodeproj`. `Scripts/release.sh <version>` construit,
signe (Developer ID, hardened runtime), crée `release/ClaudeMenu-<version>.dmg`, notarise
avec le profil partagé `AppliMacVincentGithub` et staple.
