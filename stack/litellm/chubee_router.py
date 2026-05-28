from litellm.integrations.custom_handler import CustomLogger
import os

CONTEXT_THRESHOLD = int(os.environ.get("CONTEXT_THRESHOLD", "118000"))

def count_tokens(messages):
    # ~4 chars per token — standard approximation, good enough for overflow guard
    return sum(len(m.get("content", "") or "") // 4 for m in messages)

class ChubeeRouter(CustomLogger):
    async def async_pre_call_hook(
        self, user_api_key_dict, cache, data, call_type
    ):
        messages = data.get("messages", [])
        current_model = data.get("model", "")
        if (
            current_model in ("primary_model", "primary_model_fast")
            and count_tokens(messages) > CONTEXT_THRESHOLD
        ):
            data["model"] = "frontier_model"
        return data
