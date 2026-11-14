"""Regression tests for keyless OpenAI-compatible gateways.

An empty ``ai.api_key_env`` is only meaningful for an explicitly configured
HTTP(S) gateway that needs no credential. Everything else stays fail-closed: a
named env var must be set, and the official OpenAI API still requires a key.
"""

from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from src.ai.client import OpenAIClient
from src.models import AIConfig, AIProvider

GATEWAY_URL = "https://ada.great-wrasse.ts.net/v1"
MODEL = "deepseek-v4.1-flash-eco"


def _gateway_config(**overrides) -> AIConfig:
    defaults = {
        "provider": AIProvider.OPENAI,
        "model": MODEL,
        "api_key_env": "",
        "base_url": GATEWAY_URL,
        "temperature": 0.3,
        "max_tokens": 4096,
    }
    defaults.update(overrides)
    return AIConfig(**defaults)


def _completion_body() -> dict:
    return {
        "id": "chatcmpl-test",
        "object": "chat.completion",
        "created": 1,
        "model": MODEL,
        "choices": [
            {
                "index": 0,
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": '{"ok":true}'},
            }
        ],
        "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8},
    }


def _complete_with_transport(client: OpenAIClient) -> httpx.Request:
    """Run one completion through the real SDK and return the captured request."""
    captured: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return httpx.Response(200, json=_completion_body())

    async def run() -> str:
        original = client.client
        client.client = original.with_options(
            http_client=httpx.AsyncClient(transport=httpx.MockTransport(record))
        )
        try:
            return await client.complete(system="s", user="u")
        finally:
            await client.client.close()
            await original.close()

    result = asyncio.run(run())
    assert result == '{"ok":true}'
    assert len(captured) == 1
    return captured[0]


def test_keyless_gateway_omits_authorization_header() -> None:
    client = OpenAIClient(_gateway_config())

    request = _complete_with_transport(client)

    assert str(client.client.base_url).rstrip("/") == GATEWAY_URL
    assert request.url == httpx.URL(f"{GATEWAY_URL}/chat/completions")
    assert "authorization" not in {name.lower() for name in request.headers}
    payload = json.loads(request.content)
    assert payload["model"] == MODEL
    assert payload["response_format"] == {"type": "json_object"}
    assert payload["messages"][0] == {"role": "system", "content": "s"}


def test_named_key_env_still_requires_the_variable(monkeypatch) -> None:
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)

    with pytest.raises(ValueError, match="Missing API key"):
        OpenAIClient(_gateway_config(api_key_env="OPENAI_API_KEY"))


def test_named_key_env_is_sent_as_bearer(monkeypatch) -> None:
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")

    client = OpenAIClient(_gateway_config(api_key_env="OPENAI_API_KEY"))
    request = _complete_with_transport(client)

    assert request.headers["authorization"] == "Bearer test-key"


def test_official_openai_rejects_empty_key_env() -> None:
    with pytest.raises(ValueError, match="Missing API key"):
        OpenAIClient(_gateway_config(base_url=None))


def test_official_openai_host_rejects_empty_key_env() -> None:
    with pytest.raises(ValueError, match="Missing API key"):
        OpenAIClient(_gateway_config(base_url="https://api.openai.com/v1"))


@pytest.mark.parametrize(
    "base_url",
    [
        "https://user:secret@ada.great-wrasse.ts.net/v1",
        "ftp://ada.great-wrasse.ts.net/v1",
        "ada.great-wrasse.ts.net/v1",
    ],
    ids=["userinfo", "non-http-scheme", "no-scheme"],
)
def test_non_gateway_base_urls_reject_empty_key_env(base_url: str) -> None:
    with pytest.raises(ValueError, match="Missing API key"):
        OpenAIClient(_gateway_config(base_url=base_url))
