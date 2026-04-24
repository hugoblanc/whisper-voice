# Analyse Comparative : SuperWhisper vs Whisper Voice

## Features actuelles de Whisper Voice

| Feature | Status |
|---------|--------|
| Transcription vocale (OpenAI Whisper) | ✅ |
| Transcription vocale (Mistral Voxtral) | ✅ |
| Toggle mode (Option+Space) | ✅ |
| Push-to-Talk (F1-F12) | ✅ |
| Menu bar avec indicateur de statut | ✅ |
| Paste automatique (Cmd+V) | ✅ |
| Configuration des raccourcis | ✅ |
| Fenêtre de préférences | ✅ |
| Logs viewer | ✅ |
| Test de connexion API | ✅ |
| Wizard de permissions | ✅ |
| Multi-provider (switch OpenAI/Mistral) | ✅ |

---

## Features de SuperWhisper absentes de Whisper Voice

### Priorité 1 - Quick Wins (Facile à implémenter)

| Feature | Complexité | Impact | Description |
|---------|------------|--------|-------------|
| **Indicateur visuel coloré** | Facile | Moyen | Point coloré (jaune/rouge/bleu/vert) pour l'état |
| **Sons de feedback** | Facile | Élevé | Son au début/fin d'enregistrement |
| **Suppression du silence** | Moyen | Élevé | Couper les silences avant envoi API |
| **Annuler enregistrement** | Facile | Moyen | Raccourci pour annuler pendant l'enregistrement |
| **Mouse shortcut** | Moyen | Moyen | Bouton souris pour toggle/PTT |

### Priorité 2 - Core Features (Impact élevé)

| Feature | Complexité | Impact | Description |
|---------|------------|--------|-------------|
| **Historique des transcriptions** | Moyen | Élevé | Sauvegarder et rechercher les transcriptions passées |
| **Transcription de fichiers** | Moyen | Élevé | Transcrire MP3/MP4/WAV existants |
| **Vocabulaire personnalisé** | Moyen | Élevé | Mots custom pour meilleure reconnaissance |
| **Remplacements automatiques** | Facile | Moyen | Remplacer "todo" → "TODO" après transcription |
| **Quick Recording mode** | Facile | Moyen | Clic gauche icône = enregistrement direct |

### Priorité 3 - Modes de traitement IA

| Feature | Complexité | Impact | Description |
|---------|------------|--------|-------------|
| **Mode Voice-to-Text** | Déjà fait | - | Transcription pure (mode actuel) |
| **Mode Message** | Moyen | Élevé | Nettoie artefacts vocaux, corrige grammaire |
| **Mode Email** | Moyen | Moyen | Ajoute salutations, structure email |
| **Mode Note** | Moyen | Moyen | Convertit en listes et bullet points |
| **Super Mode** | Complexe | Élevé | Contexte app + clipboard + texte sélectionné |
| **Custom Mode** | Complexe | Élevé | Instructions IA personnalisables |

### Priorité 4 - Features avancées

| Feature | Complexité | Impact | Description |
|---------|------------|--------|-------------|
| **Transcription temps réel** | Complexe | Moyen | Voir texte pendant qu'on parle |
| **Séparation des locuteurs** | Complexe | Moyen | Identifier qui parle (réunions) |
| **Meeting Mode** | Complexe | Moyen | Résumé automatique des réunions |
| **Règles d'activation auto** | Moyen | Moyen | Changer mode selon l'app active |
| **Context awareness** | Complexe | Élevé | Lire contexte app/clipboard/sélection |
| **Modèles locaux** | Complexe | Élevé | Whisper.cpp, Parakeet hors-ligne |
| **Deep Links** | Facile | Faible | whispervoice://record, etc. |

### Priorité 5 - Nice to have

| Feature | Complexité | Impact | Description |
|---------|------------|--------|-------------|
| **Intégration Raycast/Alfred** | Facile | Faible | Extensions pour launchers |
| **Sync des settings** | Moyen | Faible | Sync entre machines |
| **Windows/iOS support** | Complexe | Moyen | Multi-plateforme |
| **Support 100+ langues** | Facile | Moyen | Déjà supporté par APIs |
| **Traduction intégrée** | Moyen | Moyen | Traduire vers anglais |

---

## Roadmap recommandée

### Phase 1 - Polish (1-2 jours)
1. ✅ **DONE** - Fenêtre d'enregistrement avec waveform
2. ✅ **DONE** - Indicateur visuel coloré (rouge/bleu/vert)
3. ✅ **DONE** - Sons de feedback (début/fin/annulation)
4. ✅ **DONE** - Annuler enregistrement (Escape ou bouton Cancel)
5. ✅ **DONE** - Timer d'enregistrement affiché
6. ⬜ Quick Recording mode (clic icône)

### Phase 2 - Core (3-5 jours)
5. ✅ **DONE** - Historique des transcriptions (recherche, copie, suppression)
6. ⬜ Transcription de fichiers audio/vidéo
7. Vocabulaire personnalisé
8. Remplacements automatiques

### Phase 3 - IA Processing (5-7 jours)
9. Mode Message (nettoyage + grammaire)
10. Mode Email
11. Mode Note
12. Custom Mode avec instructions

### Phase 4 - Advanced (7-10 jours)
13. Super Mode (context awareness)
14. Règles d'activation automatique
15. Modèles locaux (Whisper.cpp)
16. Transcription temps réel

---

## Estimation de parité

Avec les phases 1-3 complétées, Whisper Voice couvrirait **~80%** des fonctionnalités de SuperWhisper Pro pour **0€** vs **~99€/an**.

La phase 4 ajouterait les derniers **15%** pour une parité quasi-totale.

Les 5% restants sont les features enterprise (SSO, team management) non pertinentes pour un usage personnel open source.
