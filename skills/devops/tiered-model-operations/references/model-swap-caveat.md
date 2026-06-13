# Model Swap Caveat — Reproduced Failure Pattern

## What Happened

In a session that added Wyoming voice services to the Docker stack, the agent also
swapped the vLLM model from Nemotron-3-Super-120B to Qwen2.5-32B-Instruct-GPTQ-Int4.
The agent modified `docker-compose.yml`, restarted the vLLM container, verified the
new model was serving on :8000, and updated **memory** to say the model had changed.

It **did not** run:

```bash
hermes config set model.default custom:local/qwen2.5-32b
hermes config set model.provider custom:local
```

## The Bug

After the session, vLLM served Qwen. The user refreshed and saw Qwen loaded.
But when they tried to **use** Hermes, it was still routing to OpenRouter/DeepSeek
because `config.yaml` still had:

```yaml
model:
  default: deepseek/deepseek-v4-flash
  provider: openrouter
```

The `custom:local` provider **was** configured in `custom_providers` — Hermes just
wasn't told to use it.

## Root Cause

The agent treated "changing the container" as the complete model-switch operation.
But Hermes and vLLM are independent systems with separate config. Container swap
updates the inference backend; `hermes config set` updates the routing layer.
Both are required.

## Diagnosis

When a user says "I switched to Qwen but get errors":

```bash
# Check what vLLM serves
curl -s http://localhost:8000/v1/models | grep '"id"'

# Check what Hermes uses
head -5 ~/.hermes/config.yaml
```

If they differ, the config update was missed.

## Fix

```bash
hermes config set model.default custom:local/qwen2.5-32b
hermes config set model.provider custom:local
```

Then start a new session (`/reset` in chat, or user refreshes from TUI).
Existing sessions continue using the cached (pre-switch) config and will
appear to still use the old model until restarted.
