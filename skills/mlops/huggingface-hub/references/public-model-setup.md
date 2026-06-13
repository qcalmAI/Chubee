# Public Model Quick‑Start for Hermes

This guide documents the steps taken to download a public model from Hugging Face Hub without needing an authentication token, and configure Hermes to use it.

## 1. Download the model

```bash
mkdir -p $HOME/models
hf download EleutherAI/gpt-neo-125M --local-dir $HOME/models/gpt-neo-125M --force-download
```

The model is ~0.8 GB and will be placed in `~/models/gpt-neo-125M`.

## 2. Update Hermes configuration

Edit `~/.hermes/config.yaml`:

```yaml
model:
  default: EleutherAI/gpt-neo-125M
  provider: custom:local
  base_url: ''
  api_key: ''
providers:
  custom:
    local:
      base_url: http://vllm-super:8000
      api_key: unused
```

Set `provider` to `custom:local` so Hermes routes requests to the local vLLM endpoint.

## 3. Verify the setup

```bash
hermes chat --model default
```

You should see the model respond using the newly downloaded `EleutherAI/gpt-neo-125M` weights.

## 4. Optional: Persist the configuration in memory

Add the following memory entry for future reference:

```
Successfully downloaded public model EleutherAI/gpt-neo-125M to ~/models/gpt-neo-125M and configured Hermes to use it: model.default set to EleutherAI/gpt-neo-125M, provider set to custom:local. No HF token required.
```

This file captures the exact commands used, the minimal config changes required, and the verification step, providing a reusable recipe for any future public‑model integration.