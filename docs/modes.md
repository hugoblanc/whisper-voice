# Modes de traitement

Un **mode** = une consigne donnée au LLM qui reformate ta dictée après transcription. Choisi avant ou pendant l'enregistrement (Shift cycle).

## Modes built-in

| Mode | Rôle | LLM ? |
|---|---|---|
| **Brut** | Transcription brute Whisper, aucun post-traitement. Le plus rapide. | Non |
| **Clean** | Enlève hésitations (*euh, bah, genre*), corrige ponctuation/majuscules. Préserve le ton et le sens. | Oui |
| **Formel** | Comme Clean + ton pro, paragraphes structurés. Ne change pas tutoiement/vouvoiement. | Oui |
| **Casual** | Comme Clean mais garde le naturel et les expressions familières. | Oui |
| **Markdown** | Convertit en markdown structuré (headers, listes, `code`, **gras**). | Oui |
| **Super** | Mode "assistant". Prend le texte sélectionné comme contexte ; ta voix devient une instruction. | Oui |

Activer / désactiver les built-ins : `Préférences → Modes → Built-in modes`.

## Modes personnalisés

Tu peux créer tes propres modes avec un system prompt sur mesure. Exemple : un mode "Slack" qui formate le message en markup Slack (`*gras*`, `` `code` ``).

Créer : `Préférences → Modes → + Add Mode`. Le prompt que tu écris est envoyé au LLM comme consigne système.

**Bonnes pratiques prompt :**
- Démarre par *"Réponds UNIQUEMENT avec le texte, sans préambule"* — évite les *"Voici le texte reformaté :"*
- Sois explicite sur ce qu'il faut **préserver** (sens, ton, tutoiement) et ce qu'il faut **transformer**
- Si tu veux un dialecte markdown spécifique (Slack, GitHub), dis-le explicitement — le LLM mélange sinon
- Teste avec 3-4 dictées variées avant de juger le prompt

## Choisir son mode à l'enregistrement

- Cliquer dans la barre de modes du panneau d'enregistrement
- Ou **Shift** pendant l'enregistrement pour cycler
- Ou configurer l'[Auto-mode](auto-mode.md) pour que Whisper Voice choisisse selon l'app

## Quel modèle LLM est utilisé ?

`Préférences → General → Processing model`. Par défaut **GPT-5.4 Nano** (rapide, pas cher). GPT-5.4 standard est plus qualitatif pour les prompts complexes.

## Audit : le mode fait vraiment ce qu'il devrait ?

`Préférences → Logs` affiche chaque pipeline :

```
[TextProcessor] model=gpt-5.4 tokenParam=max_completion_tokens mode=Slack
[TextProcessor] INPUT (185 chars): <texte brut transcrit>
[TextProcessor] SYSTEM PROMPT HEAD: <240 premiers chars>
[TextProcessor] SUCCESS 185→192 chars  changed=true
[TextProcessor] OUTPUT: <texte reformaté>
```

Si `INPUT == OUTPUT`, le LLM n'a pas modifié — probable que le prompt est trop permissif ("sans forcer", "si c'est cohérent"). Durcis-le.
