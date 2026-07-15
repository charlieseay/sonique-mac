"""
Docker Connector - Container management via docker CLI
"""

import subprocess
import json
import logging
from typing import Optional, List, Dict, Any
from .base import ConnectorBase, ConnectorResult

logger = logging.getLogger(__name__)


class DockerConnector(ConnectorBase):
    """Manage Docker containers via CLI"""

    def __init__(self):
        super().__init__("docker")

    def health_check(self) -> ConnectorResult:
        """Verify Docker daemon is running"""
        try:
            result = subprocess.run(
                ["docker", "ps"],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                return ConnectorResult(
                    success=True,
                    data={"status": "healthy"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error="Docker daemon not responding",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=f"Docker not available: {str(e)}",
                connector=self.name
            )

    def execute(self, operation: str, **kwargs) -> ConnectorResult:
        """Execute a Docker operation"""
        try:
            if operation == "list_containers":
                return self._list_containers()
            elif operation == "restart_container":
                return self._restart_container(container_name=kwargs.get("container"))
            elif operation == "stop_container":
                return self._stop_container(container_name=kwargs.get("container"))
            elif operation == "start_container":
                return self._start_container(container_name=kwargs.get("container"))
            elif operation == "container_status":
                return self._container_status(container_name=kwargs.get("container"))
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Unknown operation: {operation}",
                    connector=self.name
                )
        except Exception as e:
            logger.error(f"Docker error: {e}")
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _list_containers(self) -> ConnectorResult:
        """List all running containers"""
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "json"],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0:
                containers = json.loads(f"[{result.stdout.strip().replace(chr(10), ',')}]") if result.stdout.strip() else []
                return ConnectorResult(
                    success=True,
                    data={"containers": containers},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to list containers: {result.stderr}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _restart_container(self, container_name: str) -> ConnectorResult:
        """Restart a container"""
        try:
            result = subprocess.run(
                ["docker", "restart", container_name],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode == 0:
                logger.info(f"Container {container_name} restarted")
                return ConnectorResult(
                    success=True,
                    data={"container": container_name, "action": "restarted"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to restart {container_name}: {result.stderr}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _stop_container(self, container_name: str) -> ConnectorResult:
        """Stop a container"""
        try:
            result = subprocess.run(
                ["docker", "stop", container_name],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode == 0:
                logger.info(f"Container {container_name} stopped")
                return ConnectorResult(
                    success=True,
                    data={"container": container_name, "action": "stopped"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to stop {container_name}: {result.stderr}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _start_container(self, container_name: str) -> ConnectorResult:
        """Start a container"""
        try:
            result = subprocess.run(
                ["docker", "start", container_name],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode == 0:
                logger.info(f"Container {container_name} started")
                return ConnectorResult(
                    success=True,
                    data={"container": container_name, "action": "started"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to start {container_name}: {result.stderr}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _container_status(self, container_name: str) -> ConnectorResult:
        """Get status of a specific container"""
        try:
            result = subprocess.run(
                ["docker", "ps", "--all", "--filter", f"name={container_name}", "--format", "{{.Names}}|{{.Status}}"],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0 and result.stdout.strip():
                name, status = result.stdout.strip().split("|")
                return ConnectorResult(
                    success=True,
                    data={"container": name, "status": status},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Container {container_name} not found",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )
