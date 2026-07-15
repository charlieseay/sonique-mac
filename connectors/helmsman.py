"""
Helmsman Connector - Task queue integration via helmsman.db REST API
"""

import requests
import logging
from typing import Optional, List, Dict, Any
from .base import ConnectorBase, ConnectorResult

logger = logging.getLogger(__name__)


class HelmsmanConnector(ConnectorBase):
    """Interact with helmsman.db via REST API"""

    def __init__(self, base_url: str = "http://localhost:5682"):
        super().__init__("helmsman")
        self.base_url = base_url

    def health_check(self) -> ConnectorResult:
        """Verify helmsman.db is reachable"""
        try:
            resp = requests.get(f"{self.base_url}/health", timeout=5)
            if resp.status_code == 200:
                return ConnectorResult(
                    success=True,
                    data={"status": "healthy"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Health check returned {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=f"Connection failed: {str(e)}",
                connector=self.name
            )

    def execute(self, operation: str, **kwargs) -> ConnectorResult:
        """Execute a helmsman operation"""
        try:
            if operation == "create_task":
                return self._create_task(
                    task=kwargs.get("task"),
                    effort=kwargs.get("effort", "medium"),
                    owner=kwargs.get("owner", "CLAUDE")
                )
            elif operation == "list_pending":
                return self._list_pending()
            elif operation == "get_task":
                return self._get_task(task_id=kwargs.get("task_id"))
            elif operation == "complete_task":
                return self._complete_task(task_id=kwargs.get("task_id"))
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Unknown operation: {operation}",
                    connector=self.name
                )
        except Exception as e:
            logger.error(f"Helmsman error: {e}")
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _create_task(self, task: str, effort: str = "medium", owner: str = "CLAUDE") -> ConnectorResult:
        """Create a new task in helmsman.db"""
        try:
            payload = {
                "task": task,
                "effort": effort,
                "owner": owner,
                "status": "pending"
            }
            resp = requests.post(f"{self.base_url}/tasks", json=payload, timeout=10)
            if resp.status_code in (200, 201):
                data = resp.json()
                logger.info(f"Task created: {data}")
                return ConnectorResult(
                    success=True,
                    data=data,
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to create task: {resp.status_code} {resp.text}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _list_pending(self, owner: Optional[str] = None) -> ConnectorResult:
        """List pending tasks"""
        try:
            params = {"status": "pending"}
            if owner:
                params["owner"] = owner
            resp = requests.get(f"{self.base_url}/tasks", params=params, timeout=10)
            if resp.status_code == 200:
                tasks = resp.json()
                return ConnectorResult(
                    success=True,
                    data=tasks,
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to list tasks: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _get_task(self, task_id: int) -> ConnectorResult:
        """Get details about a specific task"""
        try:
            resp = requests.get(f"{self.base_url}/tasks/{task_id}", timeout=10)
            if resp.status_code == 200:
                task = resp.json()
                return ConnectorResult(
                    success=True,
                    data=task,
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Task not found: {task_id}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _complete_task(self, task_id: int) -> ConnectorResult:
        """Mark a task as complete"""
        try:
            payload = {"status": "completed"}
            resp = requests.patch(f"{self.base_url}/tasks/{task_id}", json=payload, timeout=10)
            if resp.status_code in (200, 204):
                return ConnectorResult(
                    success=True,
                    data={"task_id": task_id, "status": "completed"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to complete task: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )
