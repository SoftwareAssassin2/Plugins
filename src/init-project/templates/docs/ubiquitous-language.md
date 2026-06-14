# Ubiquitous Language

This is the project's **domain glossary** — the single canonical vocabulary for
every domain concept, used identically in code, tests, conversation, and docs
(Evans, *Domain-Driven Design*). When a term has one meaning here, it has that
meaning everywhere: name an entity, a method, a test, or a config field with the
glossary term, never a synonym.

> **TODO** — this glossary is empty. It's filled as the domain emerges.

## How to maintain it

This file is owned by the `/ubiquitous-language` skill installed in this repo.
Run it after a conversation that surfaces domain terms; it scans for domain
nouns/verbs, flags ambiguities (one word for two concepts, two words for one),
proposes canonical terms, and writes them here. Re-run it as understanding
evolves — it incorporates new terms and re-flags conflicts. Don't hand-maintain
the format; let the skill own it.

When you introduce a new domain concept in code or a spec, add it here (or run
the skill) so the rest of the system can speak the same language. See
[architecture.md](architecture.md) — precise names are a free design document.

## Glossary

_(empty — populated by `/ubiquitous-language` as the domain is modeled)_
