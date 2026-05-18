from __future__ import annotations

from dataclasses import dataclass
import json
import os
import subprocess
import time
from typing import Any
from urllib import error, request
from urllib.parse import urlparse, urlunparse

from .config import Config, config_value, provider_name


ROLE_SYSTEM = "system"
ROLE_USER = "user"

REQUIRED_ENV_BY_PROVIDER = {
    "openai": "DOT_OPENAI_KEY",
    "gemini": "DOT_GEMINI_KEY",
    "openrouter": "DOT_OPENROUTER_KEY",
}


@dataclass(slots=True)
class HttpResult:
    status: int
    body: str
    headers: dict[str, str]
    url: str


def missing_key_message(config: Config, sections: tuple[str, ...] = ("chat", "embedding")) -> str | None:
    providers = {provider_name(config, section) for section in sections}
    for provider in sorted(p for p in providers if p):
        env_key = REQUIRED_ENV_BY_PROVIDER.get(provider)
        if env_key and not os.environ.get(env_key):
            return (
                f'Missing API key for provider "{provider}".\n'
                f"Required env var: {env_key}\n"
                f'PowerShell (current session): $env:{env_key}="YOUR_KEY"\n'
                f"cmd.exe (current session): set {env_key}=YOUR_KEY"
            )
    return None


def should_start_ollama(config: Config, sections: tuple[str, ...] = ("chat", "embedding")) -> bool:
    return any(provider_name(config, section) == "ollama" for section in sections)


def ensure_ollama_started(config: Config, sections: tuple[str, ...] = ("chat", "embedding"), wait_seconds: int = 15) -> bool:
    url = _ollama_api_url(config, sections)
    if not url:
        return True
    if _ollama_running(url):
        return True
    if urlparse(url).hostname not in {"localhost", "127.0.0.1", "::1"}:
        print(f"Ollama provider configured at {url}, but it is not reachable and cannot be auto-started as a remote service.")
        return False

    print("Ollama is not running; starting `ollama serve`...")
    try:
        subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        print("Ollama provider is configured, but the `ollama` command was not found.")
        return False

    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        if _ollama_running(url):
            return True
        time.sleep(0.5)
    print(f"Ollama did not become ready within {wait_seconds} seconds.")
    return False


def chat(config: Config, messages: list[dict[str, str]], opts: dict[str, Any] | None = None) -> str:
    opts = opts or {}
    provider = provider_name(config, "chat") or "openai"
    if provider == "ollama":
        return _ollama_chat(config, messages, opts)
    if provider == "gemini":
        return _gemini_chat(config, messages, opts)
    if provider == "openrouter":
        return _openai_compatible_chat(
            config,
            "chat",
            messages,
            opts,
            default_model="gpt-4.1-mini",
            default_url="https://openrouter.ai/api/v1/chat/completions",
            env_key="DOT_OPENROUTER_KEY",
        )
    return _openai_compatible_chat(
        config,
        "chat",
        messages,
        opts,
        default_model="gpt-4.1-mini",
        default_url="https://api.openai.com/v1/chat/completions",
        env_key="DOT_OPENAI_KEY",
    )


def _openai_compatible_chat(
    config: Config,
    section: str,
    messages: list[dict[str, str]],
    opts: dict[str, Any],
    *,
    default_model: str,
    default_url: str,
    env_key: str,
) -> str:
    model = config_value(config, section, "model", default_model)
    url = config_value(config, section, "url", default_url)
    payload = {"model": model, "messages": messages, **opts}
    result = _http_post_json(url, payload, bearer=os.environ.get(env_key))
    if result.status != 200:
        raise RuntimeError(_http_error("Chat error", result))
    data = json.loads(result.body)
    print(f"Chat usage: {data.get('usage')}, model: {payload['model']}")
    return data["choices"][0]["message"]["content"]


def _ollama_chat(config: Config, messages: list[dict[str, str]], opts: dict[str, Any]) -> str:
    model = config_value(config, "chat", "model", "llama2")
    url = _normalize_ollama_url(config_value(config, "chat", "url", "http://127.0.0.1:11434/api/chat"))
    payload = {"model": model, "messages": messages, "stream": False, "think": False, **opts}
    payload["stream"] = False
    payload["think"] = False
    result = _http_post_json(url, payload)
    if result.status != 200:
        raise RuntimeError(_http_error("Chat error", result))
    data = json.loads(result.body)
    if isinstance(data, dict) and data.get("message"):
        return data["message"]["content"]
    return data["choices"][0]["message"]["content"]


def _gemini_chat(config: Config, messages: list[dict[str, str]], opts: dict[str, Any]) -> str:
    model = config_value(config, "chat", "model", "gemini-2.5-flash")
    base_url = str(config_value(config, "chat", "url", "https://generativelanguage.googleapis.com/v1beta/models"))
    api_url = f"{base_url.rstrip('/')}/{model}:generateContent"
    contents = [{"role": msg["role"], "parts": [{"text": msg["content"]}]} for msg in messages]
    payload = {"contents": contents, **opts}
    result = _http_post_json(api_url, payload, extra_headers={"x-goog-api-key": os.environ.get("DOT_GEMINI_KEY", "")})
    if result.status != 200:
        raise RuntimeError(_http_error("Chat error", result))
    data = json.loads(result.body)
    return data["candidates"][0]["content"]["parts"][0]["text"]


def _http_post_json(
    url: str,
    payload: dict[str, Any],
    *,
    bearer: str | None = None,
    extra_headers: dict[str, str] | None = None,
) -> HttpResult:
    body = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    if extra_headers:
        headers.update(extra_headers)
    req = request.Request(str(url), data=body, headers=headers, method="POST")
    try:
        with request.urlopen(req, timeout=600) as resp:
            return HttpResult(resp.status, resp.read().decode("utf-8"), dict(resp.headers), str(url))
    except error.HTTPError as exc:
        return HttpResult(exc.code, exc.read().decode("utf-8", errors="replace"), dict(exc.headers), str(url))


def _http_error(prefix: str, result: HttpResult) -> str:
    body = result.body
    try:
        parsed = json.loads(body)
        body = json.dumps(parsed.get("error", parsed), ensure_ascii=False)
    except (json.JSONDecodeError, AttributeError):
        pass
    req_id = (
        result.headers.get("x-request-id")
        or result.headers.get("x-request_id")
        or result.headers.get("x-openai-request-id")
        or result.headers.get("x-google-request-id")
    )
    parts = [f"code={result.status}", f"url={result.url}"]
    if req_id:
        parts.append(f"request_id={req_id}")
    if body:
        parts.append(f"body={body}")
    return f"{prefix}: {', '.join(parts)}"


def _ollama_api_url(config: Config, sections: tuple[str, ...] = ("chat", "embedding")) -> str | None:
    for section, default_url in (
        ("embedding", "http://127.0.0.1:11434/api/embeddings"),
        ("chat", "http://127.0.0.1:11434/api/chat"),
    ):
        if section not in sections:
            continue
        if provider_name(config, section) != "ollama":
            continue
        return _ollama_tags_url(config_value(config, section, "url", default_url))
    return None


def _ollama_tags_url(url: str) -> str:
    parsed = urlparse(str(url))
    host = "127.0.0.1" if parsed.hostname == "localhost" else parsed.hostname
    netloc = host or "127.0.0.1"
    if parsed.port:
        netloc = f"{netloc}:{parsed.port}"
    return urlunparse((parsed.scheme or "http", netloc, "/api/tags", "", "", ""))


def _normalize_ollama_url(url: str) -> str:
    parsed = urlparse(str(url))
    if parsed.hostname != "localhost":
        return str(url)
    netloc = "127.0.0.1"
    if parsed.port:
        netloc = f"{netloc}:{parsed.port}"
    return urlunparse((parsed.scheme, netloc, parsed.path, parsed.params, parsed.query, parsed.fragment))


def _ollama_running(url: str) -> bool:
    try:
        with request.urlopen(str(url), timeout=2) as resp:
            return 200 <= resp.status < 300
    except OSError:
        return False
