# Vocabulaire personnalisé

Liste de mots que tu veux que Whisper reconnaisse correctement : noms de produits (`PostHog`, `Chatwoot`), termes techniques (`Kubernetes`, `WebSocket`), noms propres inhabituels.

## Configurer

`Préférences → General → Custom Vocabulary`. Sépare les mots par virgules :

```
PostHog, Kubernetes, Chatwoot, Moteur Immo, Claude Code
```

## Comment c'est utilisé

Le vocabulaire est envoyé à l'API Whisper (OpenAI / Voxtral / local) via le paramètre `prompt`. Whisper l'utilise pour **biaiser la reconnaissance** vers ces tokens quand il hésite entre plusieurs candidats phonétiquement proches.

Cas d'usage typique : tu dictes *"on utilise posthog pour le tracking"* — sans vocab, Whisper peut écrire `"Post Hog"` ou `"poste dog"`. Avec vocab, tu maximises les chances d'avoir `"PostHog"`.

## Limites (importantes)

- **Uniquement à la transcription.** Le vocab n'est **pas** injecté dans le system prompt du LLM de post-processing. Donc si Whisper a écrit `"postog"`, le LLM (mode Clean, Slack, etc.) peut ne pas restaurer la bonne forme.
- Whisper tronque le prompt après **~224 tokens**. Garde la liste courte ; priorise les 10-20 termes que tu dictes le plus souvent.
- Whisper n'exécute pas le vocab comme une commande — c'est une suggestion probabiliste. Sur un fichier audio très bruité, ça peut quand même rater.
- Pour les abréviations (`API`, `SSH`) — inutile, Whisper les connaît déjà.

## Vérifier que ça marche

`Préférences → Logs` :

```
Using custom vocabulary prompt: PostHog, Kubernetes, Chatwoot
```

Si tu ne vois pas cette ligne avant une transcription, ta liste est vide ou mal sauvegardée.

## Roadmap

Injecter le vocabulaire aussi dans le system prompt du LLM (pour que même en cas d'échec Whisper, le LLM restaure les bonnes formes) — pas encore implémenté. [Voir design](https://github.com/hugoblanc/whisper-voice/tree/main/design).
