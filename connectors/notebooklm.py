"""
NotebookLM Connector - Query knowledge bases via nlm CLI
"""

import subprocess
import logging
from typing import Optional, Dict, Any
from .base import ConnectorBase, ConnectorResult

logger = logging.getLogger(__name__)


class NotebookLMConnector(ConnectorBase):
    """Query NotebookLM notebooks via CLI"""

    def __init__(self):
        super().__init__("notebooklm")
        self.team_kb_id = "d45f4666-0a50-4986-9f53-abe7d92107c1"
        self.team_kb_alias = "team-kb"
        self.projects_notebook_id = "201885bd-9c21-4d6d-ad7d-bb69e72d11df"

    def health_check(self) -> ConnectorResult:
        """Verify nlm CLI is available"""
        try:
            result = subprocess.run(
                ["which", "nlm"],
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
                    error="nlm CLI command not found",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=f"Health check failed: {str(e)}",
                connector=self.name
            )

    def execute(self, operation: str, **kwargs) -> ConnectorResult:
        """Execute a NotebookLM operation"""
        try:
            if operation == "query_team_kb":
                return self._query_notebook(
                    notebook_alias=self.team_kb_alias,
                    query=kwargs.get("query")
                )
            elif operation == "query_projects":
                return self._query_notebook(
                    notebook_id=self.projects_notebook_id,
                    query=kwargs.get("query")
                )
            elif operation == "query_notebook":
                return self._query_notebook(
                    notebook_id=kwargs.get("notebook_id"),
                    notebook_alias=kwargs.get("notebook_alias"),
                    query=kwargs.get("query")
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Unknown operation: {operation}",
                    connector=self.name
                )
        except Exception as e:
            logger.error(f"NotebookLM error: {e}")
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _query_notebook(
        self,
        query: str,
        notebook_id: Optional[str] = None,
        notebook_alias: Optional[str] = None
    ) -> ConnectorResult:
        """Query a NotebookLM notebook"""
        try:
            # Use alias if provided, otherwise use ID
            notebook_target = notebook_alias or notebook_id
            if not notebook_target:
                return ConnectorResult(
                    success=False,
                    error="Either notebook_id or notebook_alias required",
                    connector=self.name
                )

            # Call nlm CLI
            cmd = ["nlm", "notebook", "query", notebook_target, query]
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode == 0 and result.stdout:
                response = result.stdout.strip()
                logger.info(f"NotebookLM query successful: {query[:50]}")
                return ConnectorResult(
                    success=True,
                    data={
                        "query": query,
                        "notebook": notebook_target,
                        "response": response
                    },
                    connector=self.name
                )
            else:
                error_msg = result.stderr or "Query failed"
                return ConnectorResult(
                    success=False,
                    error=f"NotebookLM query failed: {error_msg}",
                    connector=self.name
                )
        except subprocess.TimeoutExpired:
            return ConnectorResult(
                success=False,
                error="NotebookLM query timed out (>30s)",
                connector=self.name
            )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )
