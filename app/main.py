"""FastAPI application: /, /health, /metrics."""

from __future__ import annotations

import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from starlette.routing import Match

from app.config import Settings
from app.logging_config import configure_logging

logger = logging.getLogger("app")

# Buckets tuned for a fast JSON API: 5ms .. 5s.
LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0)


class Metrics:
    """Per-app registry so tests can create isolated instances."""

    def __init__(self, settings: Settings) -> None:
        self.registry = CollectorRegistry()
        self.requests = Counter(
            "http_requests_total",
            "Total HTTP requests.",
            ["method", "path", "status"],
            registry=self.registry,
        )
        self.errors = Counter(
            "http_request_errors_total",
            "Total HTTP requests that returned a 5xx status or raised.",
            ["method", "path"],
            registry=self.registry,
        )
        self.latency = Histogram(
            "http_request_duration_seconds",
            "HTTP request latency in seconds.",
            ["method", "path"],
            buckets=LATENCY_BUCKETS,
            registry=self.registry,
        )
        self.in_progress = Gauge(
            "http_requests_in_progress", "In-flight HTTP requests.", registry=self.registry
        )
        build = Gauge("app_build_info", "Build information.", ["version", "env"], registry=self.registry)
        build.labels(version=settings.app_version, env=settings.environment).set(1)


def _route_template(request: Request) -> str:
    """Return the matched route template (e.g. /items/{id}) to keep label cardinality bounded."""
    for route in request.app.router.routes:
        match, _ = route.matches(request.scope)
        if match == Match.FULL:
            return getattr(route, "path", "unmatched")
    return "unmatched"


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging(settings.log_level, settings.environment, settings.app_version)
    metrics = Metrics(settings)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        logger.info("application started", extra={"port": settings.port})
        yield
        # Runs after uvicorn received SIGTERM and drained in-flight requests.
        logger.info("application shutting down gracefully")

    app = FastAPI(
        title="devops-task", version=settings.app_version, lifespan=lifespan, docs_url=None, redoc_url=None
    )
    app.state.settings = settings
    app.state.metrics = metrics

    @app.middleware("http")
    async def observe(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        path = _route_template(request)
        method = request.method
        start = time.perf_counter()
        metrics.in_progress.inc()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        except Exception:
            logger.exception("unhandled exception", extra={"method": method, "path": path})
            raise
        finally:
            duration = time.perf_counter() - start
            metrics.in_progress.dec()
            metrics.requests.labels(method=method, path=path, status=str(status)).inc()
            metrics.latency.labels(method=method, path=path).observe(duration)
            if status >= 500:
                metrics.errors.labels(method=method, path=path).inc()
            if path not in ("/health", "/metrics"):  # avoid probe/scrape noise
                log = logger.error if status >= 500 else logger.info
                log(
                    "request completed",
                    extra={
                        "method": method,
                        "path": path,
                        "status": status,
                        "duration_ms": round(duration * 1000, 2),
                        "client": request.client.host if request.client else None,
                    },
                )

    @app.get("/")
    async def root() -> dict[str, str]:
        return {"message": "Hello from DevOps Task!", "status": "running", "version": settings.app_version}

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "healthy"}

    @app.get("/metrics")
    async def prometheus_metrics() -> Response:
        return Response(generate_latest(metrics.registry), media_type=CONTENT_TYPE_LATEST)

    @app.get("/error", include_in_schema=False)
    async def simulate_error() -> JSONResponse:
        """Demo-only endpoint used to trigger an error spike; disabled unless explicitly enabled."""
        if not settings.enable_error_endpoint:
            raise HTTPException(status_code=404, detail="Not Found")
        return JSONResponse(status_code=500, content={"error": "simulated failure"})

    return app
