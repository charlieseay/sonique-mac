"""
Slack Connector - Post messages via slack-post-filtered command
"""

import subprocess
import logging
from typing import Optional
from .base import ConnectorBase, ConnectorResult

logger = logging.getLogger(__name__)


class SlackConnector(ConnectorBase):
    """Post messages to Slack via CLI"""

    def __init__(self):
        super().__init__("slack")

    def health_check(self) -> ConnectorResult:
        """Verify slack-post-filtered is available"""
        try:
            result = subprocess.run(
                ["which", "slack-post-filtered"],
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
                    error="slack-post-filtered command not found",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=f"Health check failed: {str(e)}",
                connector=self.name
            )

    def execute(self, operation: str, **kwargs) -> ConnectorResult:
        """Execute a Slack operation"""
        try:
            if operation == "post_message":
                return self._post_message(
                    channel=kwargs.get("channel"),
                    message=kwargs.get("message"),
                    priority=kwargs.get("priority", "normal")
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Unknown operation: {operation}",
                    connector=self.name
                )
        except Exception as e:
            logger.error(f"Slack error: {e}")
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _post_message(self, channel: str, message: str, priority: str = "normal") -> ConnectorResult:
        """Post a message to Slack"""
        try:
            # Map priority to slack-post-filtered levels
            # high/question/error show notification, low/normal are silent
            priority_map = {
                "low": "low",
                "normal": "low",
                "high": "high",
                "question": "question",
                "error": "error"
            }
            slack_priority = priority_map.get(priority, "low")

            cmd = [
                "slack-post-filtered",
                channel,
                message,
                f"--priority={slack_priority}"
            ]

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0:
                logger.info(f"Message posted to {channel}")
                return ConnectorResult(
                    success=True,
                    data={
                        "channel": channel,
                        "message": message,
                        "priority": priority
                    },
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to post message: {result.stderr}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )
