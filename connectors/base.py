"""
Base connector protocol - all connectors implement this interface
"""

from dataclasses import dataclass
from typing import Any, Optional, Dict
from abc import ABC, abstractmethod


@dataclass
class ConnectorResult:
    """Standard result from any connector operation"""
    success: bool
    data: Any = None
    error: Optional[str] = None
    connector: str = ""

    def to_dict(self) -> dict:
        return {
            "success": self.success,
            "data": self.data,
            "error": self.error,
            "connector": self.connector
        }


class ConnectorBase(ABC):
    """Base class for all connectors"""

    def __init__(self, name: str):
        self.name = name

    @abstractmethod
    def health_check(self) -> ConnectorResult:
        """Verify the connector is working"""
        pass

    @abstractmethod
    def execute(self, operation: str, **kwargs) -> ConnectorResult:
        """Execute an operation. Operation name is connector-specific."""
        pass
