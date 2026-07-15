"""
Vault Connector - Query Obsidian vault via MCP vault-mcp server
"""

import requests
import json
import logging
from typing import Optional, Dict, Any
from .base import ConnectorBase, ConnectorResult

logger = logging.getLogger(__name__)


class VaultConnector(ConnectorBase):
    """Query Obsidian vault via MCP vault-mcp server"""

    def __init__(self, mcp_url: str = "http://localhost:3700"):
        super().__init__("vault")
        self.mcp_url = mcp_url

    def health_check(self) -> ConnectorResult:
        """Verify MCP vault server is reachable"""
        try:
            resp = requests.get(f"{self.mcp_url}/health", timeout=5)
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
        """Execute a vault operation"""
        try:
            if operation == "read_note":
                return self._read_note(path=kwargs.get("path"))
            elif operation == "search":
                return self._search(query=kwargs.get("query"))
            elif operation == "create_note":
                return self._create_note(
                    path=kwargs.get("path"),
                    content=kwargs.get("content")
                )
            elif operation == "append_note":
                return self._append_note(
                    path=kwargs.get("path"),
                    content=kwargs.get("content")
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Unknown operation: {operation}",
                    connector=self.name
                )
        except Exception as e:
            logger.error(f"Vault error: {e}")
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _read_note(self, path: str) -> ConnectorResult:
        """Read a note from vault"""
        try:
            payload = {"path": path}
            resp = requests.post(f"{self.mcp_url}/read", json=payload, timeout=10)
            if resp.status_code == 200:
                data = resp.json()
                return ConnectorResult(
                    success=True,
                    data=data,
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to read note: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _search(self, query: str) -> ConnectorResult:
        """Search vault for notes"""
        try:
            payload = {"query": query}
            resp = requests.post(f"{self.mcp_url}/search", json=payload, timeout=10)
            if resp.status_code == 200:
                data = resp.json()
                return ConnectorResult(
                    success=True,
                    data=data,
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Search failed: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _create_note(self, path: str, content: str) -> ConnectorResult:
        """Create a new note in vault"""
        try:
            payload = {"path": path, "content": content}
            resp = requests.post(f"{self.mcp_url}/create", json=payload, timeout=10)
            if resp.status_code in (200, 201):
                return ConnectorResult(
                    success=True,
                    data={"path": path, "action": "created"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to create note: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _append_note(self, path: str, content: str) -> ConnectorResult:
        """Append content to an existing note"""
        try:
            payload = {"path": path, "content": content}
            resp = requests.post(f"{self.mcp_url}/append", json=payload, timeout=10)
            if resp.status_code == 200:
                return ConnectorResult(
                    success=True,
                    data={"path": path, "action": "appended"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to append to note: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )
