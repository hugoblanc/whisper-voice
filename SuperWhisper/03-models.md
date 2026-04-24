# SuperWhisper - Modèles

## Modèles Vocaux (Transcription)

### Superwhisper Cloud
- **S1-Voice** : multilingue avec traduction (Pro)
- **Ultra** : multilingue avec traduction (Pro)

### Whisper Models (Local)
Basés sur OpenAI Whisper, exécutés via whisper.cpp :
- **Ultra** : 3 GB, précision maximale
- **Nano** : 150 MB, gratuit, plus léger

### Nvidia Parakeet (Local)
Via WhisperKit SDK :
- **Parakeet Multilanguage** : 494 MB, multilingue
- Note : difficultés avec la ponctuation

### Deepgram Nova (Cloud)
- **Nova** : vitesse maximale, idéal pour enregistrements longs
- **Nova Medical** : spécialisé anglais médical
- Meilleur pour la séparation des locuteurs

## Modèles de Langage (Traitement IA)

### Fournisseurs supportés
| Fournisseur | Modèles | Benchmark | Vitesse |
|-------------|---------|-----------|---------|
| Superwhisper | S1-Language | ~80 | 10 |
| Anthropic | Claude 4.5 Sonnet | 89 | 8-9 |
| Anthropic | Claude 3.5 Haiku | 75 | 8-9 |
| OpenAI | GPT-5 | 91 | 7-9 |
| OpenAI | GPT-4.1 nano | 80 | 7-9 |
| Groq | Llama 3 8b | 67 | 10 |

## Recommandations par usage

### Dictation rapide
- **Parakeet** (Local) : très rapide, anglais uniquement
- **Ultra** (Cloud) : rapide et précis
- **Ultra Turbo v3** (Local) : équilibre vitesse/qualité

### Enregistrements longs
- **Nova** (Cloud) : meilleur pour séparation locuteurs
