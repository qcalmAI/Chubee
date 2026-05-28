
## vLLM Memory Probe Results — 2026-05-26

- VLLM_GPU_MEM_UTIL: 0.88 (first probe succeeded)
- Available KV cache: 32.54 GiB = 5,837,522 tokens
- VLLM_MAX_MODEL_LEN: 131072 (128K — model native max; KV cache supports ~44 concurrent sessions at this length, overkill for single user)
- CONTEXT_THRESHOLD: 118000 (90% of max_model_len — 10% margin for tiktoken under-count; appropriate for English document ingestion workload)
