import os
import json
import httpx
from litellm.integrations.custom_logger import CustomLogger

THRESHOLD = int(os.environ.get("COMPRESSION_THRESHOLD", "91750"))
LITELLM_URL = "http://localhost:4000"

def _estimate_tokens(messages: list) -> int:
    total = 0
    for m in messages:
        content = m.get("content") or ""
        if isinstance(content, list):
            content = " ".join(
                p.get("text", "") for p in content if isinstance(p, dict)
            )
        total += len(content) // 4
    return total

def _find_split(messages: list) -> int:
    for i, m in enumerate(messages):
        if m.get("role") != "system":
            return i
    return 0

class ChubeeCompressor(CustomLogger):
    async def async_log_pre_api_call(self, model, messages, kwargs):
        if not isinstance(messages, list) or len(messages) < 6:
            return
        if _estimate_tokens(messages) < THRESHOLD:
            return
        split = _find_split(messages)
        system_msgs = messages[:split]
        body_msgs = messages[split:]
        if len(body_msgs) <= 6:
            return
        to_compress = body_msgs[:-4]
        tail = body_msgs[-4:]
        cut = len(to_compress)
        while cut > 0 and to_compress[cut - 1].get("role") in ("tool",):
            cut -= 1
        to_compress = to_compress[:cut]
        if not to_compress:
            return
        digest_prompt = (
            "Summarize the following conversation excerpt into a compact but complete "
            "record of facts, decisions, and context established. Preserve specifics "
            "(numbers, names, file paths, conclusions). Output only the summary.\n\n"
            + "\n".join(
                f"{m['role'].upper()}: "
                + (m["content"] if isinstance(m["content"], str) else json.dumps(m["content"]))
                for m in to_compress
            )
        )
        try:
            master_key = os.environ.get("LITELLM_MASTER_KEY", "")
            async with httpx.AsyncClient(timeout=60) as client:
                resp = await client.post(
                    f"{LITELLM_URL}/v1/chat/completions",
                    headers={"Authorization": f"Bearer {master_key}"},
                    json={
                        "model": "primary_model_fast",
                        "messages": [{"role": "user", "content": digest_prompt}],
                        "max_tokens": 1024,
                    },
                )
                resp.raise_for_status()
                summary = resp.json()["choices"][0]["message"]["content"]
        except Exception as e:
            print(f"[ChubeeCompressor] summarization failed ({e}), using tail fallback")
            kwargs["messages"] = system_msgs + tail
            return
        summary_msg = {
            "role": "system",
            "content": f"[Conversation summary - earlier turns compressed]\n{summary}",
        }
        kwargs["messages"] = system_msgs + [summary_msg] + tail

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        pass

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        pass

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        pass

chubee_compressor_instance = ChubeeCompressor()

chubee_compressor_instance = ChubeeCompressor()
