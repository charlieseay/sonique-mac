"""
Vault Connector - Direct filesystem search of Obsidian vault using ripgrep
"""

import subprocess
import logging
from pathlib import Path
from typing import Optional, Dict, Any, List
from .base import ConnectorBase, ConnectorResult

logger = logging.getLogger(__name__)


class VaultConnector(ConnectorBase):
    """Query Obsidian vault via direct filesystem access using ripgrep"""

    def __init__(self):
        super().__init__("vault")
        self.vault_path = Path.home() / "Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet"
        self.rg_path = "/opt/homebrew/bin/rg"

    def health_check(self) -> ConnectorResult:
        """Verify vault path exists and ripgrep is available"""
        try:
            if not self.vault_path.exists():
                return ConnectorResult(
                    success=False,
                    error=f"Vault path not found: {self.vault_path}",
                    connector=self.name
                )

            if not Path(self.rg_path).exists():
                return ConnectorResult(
                    success=False,
                    error=f"ripgrep not found: {self.rg_path}",
                    connector=self.name
                )

            return ConnectorResult(
                success=True,
                data={"status": "healthy", "vault_path": str(self.vault_path)},
                connector=self.name
            )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=f"Health check failed: {str(e)}",
                connector=self.name
            )

    def execute(self, operation: str, **kwargs) -> ConnectorResult:
        """Execute a vault operation"""
        try:
            if operation == "search":
                return self._search(query=kwargs.get("query"))
            elif operation == "read_note":
                return self._read_note(path=kwargs.get("path"))
            elif operation == "list_project_notes":
                return self._list_project_notes()
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

    def _search(self, query: str) -> ConnectorResult:
        """
        Search vault - uses fast project-note lookup instead of ripgrep
        (4,664 markdown files + iCloud on-demand = ripgrep times out)
        """
        try:
            # Strategy: search only main project notes (fast, <100 files)
            projects_dir = self.vault_path / "Projects"
            matches = []

            # Scan project folders for main notes
            for project_dir in projects_dir.iterdir():
                if not project_dir.is_dir() or project_dir.name.startswith("."):
                    continue

                # Check main project note
                project_note = project_dir / f"{project_dir.name}.md"
                if project_note.exists():
                    try:
                        with open(project_note, "r") as f:
                            content = f.read()

                        # Case-insensitive search
                        if query.lower() in content.lower():
                            # Find first occurrence and extract snippet
                            idx = content.lower().find(query.lower())
                            snippet_start = max(0, idx - 50)
                            snippet_end = min(len(content), idx + 100)
                            snippet = content[snippet_start:snippet_end].replace("\n", " ").strip()

                            matches.append({
                                "file": f"Projects/{project_dir.name}/{project_note.name}",
                                "snippet": snippet
                            })

                            if len(matches) >= 5:
                                break
                    except Exception as e:
                        logger.debug(f"Skipping {project_note}: {e}")
                        continue

            # Format results
            if matches:
                file_count = len(matches)
                summary = f"Found in {file_count} project notes: " + ", ".join(
                    [Path(m["file"]).stem for m in matches[:3]]
                )

                return ConnectorResult(
                    success=True,
                    data={
                        "matches": matches,
                        "summary": summary
                    },
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=True,
                    data={
                        "matches": [],
                        "summary": f"No project notes found for '{query}'"
                    },
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _read_note(self, path: str) -> ConnectorResult:
        """Read a note from vault"""
        try:
            full_path = self.vault_path / path

            if not full_path.exists():
                return ConnectorResult(
                    success=False,
                    error=f"Note not found: {path}",
                    connector=self.name
                )

            with open(full_path, "r") as f:
                content = f.read()

            # Return first 500 chars to avoid overwhelming voice output
            preview = content[:500]
            if len(content) > 500:
                preview += "..."

            return ConnectorResult(
                success=True,
                data={
                    "path": path,
                    "content": preview,
                    "full_length": len(content)
                },
                connector=self.name
            )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _list_project_notes(self) -> ConnectorResult:
        """List all project notes"""
        try:
            projects_dir = self.vault_path / "Projects"

            if not projects_dir.exists():
                return ConnectorResult(
                    success=False,
                    error="Projects directory not found",
                    connector=self.name
                )

            # Find all project folders
            projects = []
            for item in projects_dir.iterdir():
                if item.is_dir() and not item.name.startswith("."):
                    # Check for main project note
                    project_note = item / f"{item.name}.md"
                    if project_note.exists():
                        projects.append(item.name)

            return ConnectorResult(
                success=True,
                data={
                    "projects": sorted(projects),
                    "count": len(projects)
                },
                connector=self.name
            )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )
