import os
from litellm.integrations.custom_logger import CustomLogger

class ChubeeRouter(CustomLogger):
    async def async_log_pre_api_call(self, model, messages, kwargs):
        pass

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        pass

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        pass

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        pass

chubee_router_instance = ChubeeRouter()

chubee_router_instance = ChubeeRouter()
