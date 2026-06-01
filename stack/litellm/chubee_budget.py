import os
from litellm.integrations.custom_logger import CustomLogger

MAX_ITERATIONS = int(os.environ.get("MAX_ITERATIONS_PER_CONV", "90"))

class ChubeeBudget(CustomLogger):
    def __init__(self):
        self._counts: dict[str, int] = {}

    async def async_log_pre_api_call(self, model, messages, kwargs):
        session = (kwargs.get("metadata") or {}).get("session_id", "default")
        self._counts[session] = self._counts.get(session, 0) + 1
        if self._counts[session] > MAX_ITERATIONS:
            raise Exception(
                f"[ChubeeBudget] Iteration budget exhausted for session {session} "
                f"({MAX_ITERATIONS} max). Start a new conversation."
            )

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        pass

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        pass

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        pass

chubee_budget_instance = ChubeeBudget()

chubee_budget_instance = ChubeeBudget()
