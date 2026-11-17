import json
import logging

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.logging_config import JsonFormatter
from app.main import create_app


def make_settings(**overrides: object) -> Settings:
    base = dict(
        host="127.0.0.1",
        port=8080,
        log_level="INFO",
        environment="test",
        app_version="1.2.3",
        graceful_timeout=5,
        enable_error_endpoint=False,
    )
    base.update(overrides)
    return Settings(**base)  # type: ignore[arg-type]


@pytest.fixture
def client() -> TestClient:
    with TestClient(create_app(make_settings())) as c:
        yield c


def test_root_returns_expected_payload(client: TestClient) -> None:
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json() == {"message": "Hello from DevOps Task!", "status": "running", "version": "1.2.3"}


def test_health(client: TestClient) -> None:
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "healthy"}


def test_metrics_exposes_counters_and_histogram(client: TestClient) -> None:
    client.get("/")
    client.get("/does-not-exist")
    body = client.get("/metrics").text
    assert 'http_requests_total{method="GET",path="/",status="200"} 1.0' in body
    assert 'path="unmatched",status="404"' in body  # unknown paths collapse into one label
    assert "http_request_duration_seconds_bucket" in body
    assert "http_request_errors_total" in body
    assert 'app_build_info{env="test",version="1.2.3"} 1.0' in body


def test_error_endpoint_disabled_by_default(client: TestClient) -> None:
    assert client.get("/error").status_code == 404


def test_error_endpoint_counts_errors() -> None:
    with TestClient(create_app(make_settings(enable_error_endpoint=True))) as c:
        assert c.get("/error").status_code == 500
        body = c.get("/metrics").text
    assert 'http_request_errors_total{method="GET",path="/error"} 1.0' in body


def test_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PORT", "9000")
    monkeypatch.setenv("LOG_LEVEL", "debug")
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("APP_VERSION", "2.0.0")
    monkeypatch.setenv("ENABLE_ERROR_ENDPOINT", "true")
    s = Settings.from_env()
    assert (s.port, s.log_level, s.environment, s.app_version, s.enable_error_endpoint) == (
        9000,
        "DEBUG",
        "staging",
        "2.0.0",
        True,
    )


def test_invalid_log_level_falls_back_to_info(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LOG_LEVEL", "verbose")
    assert Settings.from_env().log_level == "INFO"


def test_json_formatter_includes_extra_fields() -> None:
    record = logging.makeLogRecord(
        {
            "name": "app",
            "levelname": "INFO",
            "levelno": 20,
            "msg": "request completed",
            "path": "/",
            "status": 200,
        }
    )
    out = json.loads(JsonFormatter("test", "1.2.3").format(record))
    assert out["level"] == "info"
    assert out["message"] == "request completed"
    assert out["path"] == "/" and out["status"] == 200
    assert out["env"] == "test" and out["version"] == "1.2.3"
