"""Entrypoint: `python -m app`. Uvicorn handles SIGTERM by draining in-flight requests."""

import uvicorn

from app.config import Settings
from app.main import create_app


def main() -> None:
    settings = Settings.from_env()
    uvicorn.run(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        log_config=None,  # keep our JSON logging configuration
        access_log=False,
        timeout_graceful_shutdown=settings.graceful_timeout,
        proxy_headers=True,
        server_header=False,
    )


if __name__ == "__main__":
    main()
