# Pressepapier multi-format

## Le principe

Sur macOS (comme Windows et Linux), le pressepapier **n'est pas une string unique** : c'est une boîte multi-formats. Tu peux y mettre la même information sous plusieurs représentations (`public.utf8-plain-text`, `public.html`, `public.rtf`, `public.png`…) — c'est l'app qui colle qui choisit la représentation qu'elle préfère.

## Ce que fait Whisper Voice

Quand le texte post-LLM contient du **markup Slack** (`*gras*`, `` `code` ``, `_italique_`, listes, blockquotes), on écrit **deux versions** :

| Format | Contenu | Consommé par |
|---|---|---|
| `public.utf8-plain-text` | markdown source (toujours) | Terminal, Claude Code, VSCode, Xcode, `<textarea>` |
| `public.html` | HTML rendu (`<strong>`, `<code>`, `<ul>`…) | Slack (WYSIWYG), Notion, Gmail, Apple Mail, Word |

## Pourquoi c'est utile

**Problème Slack** : depuis 2019, le composer WYSIWYG de Slack affiche littéralement les `*` et `` ` `` quand tu colles du texte. Deux options :

1. **Soit** tu actives `Slack → Preferences → Avancé → Mettre en forme les messages avec des balises` → markup rendu au collage, mais la toolbar WYSIWYG (B/I/U) disparaît.
2. **Soit** tu laisses le réglage par défaut et comptes sur le **HTML du pressepapier** — Slack le prend en priorité et rend tout correctement, sans te forcer à changer tes préfs.

Whisper Voice t'offre l'option 2 par défaut.

## Audit

`Préférences → Logs` :

```
[Paste] wrote plain + HTML (347 chars)
```

Si cette ligne est absente, c'est que le texte n'a pas été détecté comme contenant du markup → seul le plain text a été écrit. Normal pour du prose pur.

## Limites actuelles

- **Seul le dialecte Slack est converti.** Si tu es en mode **Markdown** built-in qui crache du `**gras**` ou `# titre` (CommonMark), Whisper Voice ne convertit pas encore → Notion/Gmail reçoivent le plain markdown et l'affichent littéralement.
- Pas de `public.rtf` écrit (TextEdit, Pages prennent encore le plain text).

Les deux sont adressés dans le [design 03](https://github.com/hugoblanc/whisper-voice/blob/main/design/03-clipboard-multi-format.md) — flavor par mode + converter CommonMark + RTF.

## Debug

Si le paste ne rend pas le style attendu dans l'app cible :

1. Vérifier `Préférences → Logs` — voir si `[Paste] wrote plain + HTML` apparaît
2. Vérifier que l'app cible **lit vraiment le HTML** : Slack (avec WYSIWYG on), Notion, Gmail le font ; `<input>` HTML, Terminal, VSCode non (par design)
3. Inspecter le pressepapier : Terminal → `pbpaste` (plain), `osascript -e 'the clipboard as «class HTML»'` (HTML en hex)
