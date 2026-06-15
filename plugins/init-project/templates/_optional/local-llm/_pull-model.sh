#!/bin/sh
# Description: One-shot Ollama model pull for the local LLM stack (--profile ai).
#
# Runs INSIDE the ollama/ollama image via an entrypoint override (/bin/sh THIS), so
# it must be POSIX sh-compatible — that image may lack Bash. NO bashisms: set -eu
# only (no pipefail), no [[ ]], no arrays. Its unit tests run under `sh`.
#
# Reads LLM_MODEL (required) + LLM_EMBED_MODEL (optional) from the container env
# (set via compose ${LLM_MODEL:-} / ${LLM_EMBED_MODEL:-} interpolation from the
# host's exported values). Pulls the chat model, and — when an embedding model is
# set (R12) — also pulls it (still one model-pull step under the single `ai`
# profile). Any `ollama pull` failure (offline / unknown model) makes this exit
# non-zero; the real litellm service waits on service_completed_successfully, so a
# failed pull makes `up --profile ai` fail LOUDLY rather than half-start (R13).

set -eu

# LLM_MODEL must be set and non-empty — fail clearly otherwise (a bare `--profile ai`
# without an exported model would otherwise pull "").
if [ -z "${LLM_MODEL:-}" ]; then
  echo "ERROR: LLM_MODEL is empty — set localLlm.model in config.json and run './system.sh build-config', then 'up --profile ai'." >&2
  exit 1
fi

echo "model-pull: pulling chat model '$LLM_MODEL'"
ollama pull "$LLM_MODEL"

# Optional embedding model (R12) — only when opted in (non-empty).
if [ -n "${LLM_EMBED_MODEL:-}" ]; then
  echo "model-pull: pulling embedding model '$LLM_EMBED_MODEL'"
  ollama pull "$LLM_EMBED_MODEL"
fi

echo "model-pull: done"
