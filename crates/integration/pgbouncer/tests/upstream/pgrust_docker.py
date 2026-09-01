"""Run PgBouncer's upstream pytest suite against a pgrust Docker backend.

Load this module with ``pytest -p pgrust_docker`` from a PgBouncer checkout.
It deliberately reuses the upstream test implementation; production pooler
code remains in Rust.
"""

from __future__ import annotations

import os
import subprocess
import time
import uuid
from pathlib import Path


def pytest_configure() -> None:
    from test import conftest, utils

    # The initial Rust pooler exposes a TCP admin console. The upstream test
    # harness otherwise prefers a Unix-domain admin socket on Unix platforms.
    utils.USE_UNIX_SOCKETS = False
    conftest.USE_UNIX_SOCKETS = False

    class DockerPgrust(utils.Postgres):
        """The upstream Postgres fixture backed by a disposable pgrust image."""

        def __init__(self, pgdata: Path) -> None:
            super().__init__(pgdata)
            self.image = os.environ.get("PGRUST_IMAGE", "pgrust:pgbouncer")
            self.container = f"pgrust-pgbouncer-test-{uuid.uuid4().hex}"
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            self.log_path.touch()

        def initdb(self) -> None:
            # The image entrypoint owns initdb. These local files preserve the
            # fixture shape expected by the upstream test code; the initial
            # adapter uses POSTGRES_HOST_AUTH_METHOD=trust for the container.
            self.pgdata.mkdir(parents=True, exist_ok=True)
            self.hba_path.touch()
            self.conf_path.touch()

        def start(self) -> None:
            subprocess.run(
                [
                    "docker",
                    "run",
                    "--detach",
                    "--rm",
                    "--name",
                    self.container,
                    "--publish",
                    f"127.0.0.1:{self.port}:5432",
                    "--env",
                    "POSTGRES_HOST_AUTH_METHOD=trust",
                    "--env",
                    "POSTGRES_USER=postgres",
                    self.image,
                ],
                check=True,
            )
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                try:
                    self.test()
                    return
                except Exception:
                    time.sleep(0.25)
            self._write_logs()
            raise TimeoutError(f"pgrust container {self.container} did not become ready")

        def stop(self) -> None:
            self._write_logs()
            subprocess.run(
                ["docker", "rm", "--force", self.container],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        def restart(self) -> None:
            self.restarted = True
            subprocess.run(["docker", "restart", self.container], check=True)

        def reload(self) -> None:
            subprocess.run(["docker", "kill", "--signal", "HUP", self.container], check=True)
            time.sleep(1)

        def pgctl(self, command, **_kwargs) -> None:
            if "reload" in command:
                self.reload()
            elif "restart" in command:
                self.restart()
            elif "stop" in command:
                self.stop()
            elif "start" in command:
                self.start()
            else:
                raise NotImplementedError(f"pgrust Docker adapter cannot run pg_ctl {command!r}")

        async def apgctl(self, command, **_kwargs):
            self.pgctl(command)

        def nossl_access(self, *_args, **_kwargs) -> None:
            pass

        def ssl_access(self, *_args, **_kwargs) -> None:
            pass

        def commit_hba(self) -> None:
            pass

        def reset_hba(self) -> None:
            pass

        def _write_logs(self) -> None:
            result = subprocess.run(
                ["docker", "logs", self.container],
                check=False,
                capture_output=True,
                text=True,
            )
            with self.log_path.open("a", encoding="utf-8") as log:
                log.write(result.stdout)
                log.write(result.stderr)

    utils.Postgres = DockerPgrust
    conftest.Postgres = DockerPgrust
