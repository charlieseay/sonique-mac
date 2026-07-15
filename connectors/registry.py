"""
Connector Registry - Manages all lab connectors
Provides a unified interface to route Quinn commands to the right system
"""

import logging
from typing import Dict, Optional, Any
from .base import ConnectorBase, ConnectorResult
from .helmsman import HelmsmanConnector
from .docker import DockerConnector
from .notebooklm import NotebookLMConnector
from .vault import VaultConnector
from .home_assistant import HomeAssistantConnector

logger = logging.getLogger(__name__)


class ConnectorRegistry:
    """Registry of all available connectors"""

    def __init__(self):
        self.connectors: Dict[str, ConnectorBase] = {}
        self._initialize_connectors()

    def _initialize_connectors(self):
        """Initialize all connectors"""
        self.connectors["helmsman"] = HelmsmanConnector()
        self.connectors["docker"] = DockerConnector()
        self.connectors["notebooklm"] = NotebookLMConnector()
        self.connectors["vault"] = VaultConnector()
        self.connectors["home_assistant"] = HomeAssistantConnector()
        logger.info(f"Initialized {len(self.connectors)} connectors")

    def health_check_all(self) -> Dict[str, Dict[str, Any]]:
        """Check health of all connectors"""
        results = {}
        for name, connector in self.connectors.items():
            result = connector.health_check()
            results[name] = result.to_dict()
        return results

    def execute(self, connector_name: str, operation: str, **kwargs) -> ConnectorResult:
        """Execute an operation on a specific connector"""
        if connector_name not in self.connectors:
            return ConnectorResult(
                success=False,
                error=f"Unknown connector: {connector_name}",
                connector=connector_name
            )

        connector = self.connectors[connector_name]
        return connector.execute(operation, **kwargs)

    def get_connector(self, name: str) -> Optional[ConnectorBase]:
        """Get a specific connector by name"""
        return self.connectors.get(name)

    def list_connectors(self) -> Dict[str, str]:
        """List all available connectors"""
        return {name: name for name in self.connectors.keys()}
