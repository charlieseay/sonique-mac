"""
Home Assistant Connector - Control smart home devices via REST API
"""

import requests
import logging
from typing import Optional, Dict, Any, List
from .base import ConnectorBase, ConnectorResult

logger = logging.getLogger(__name__)


class HomeAssistantConnector(ConnectorBase):
    """Control Home Assistant devices via REST API"""

    def __init__(self, base_url: str = "http://192.168.68.80:8123", token: Optional[str] = None):
        super().__init__("home_assistant")
        self.base_url = base_url
        self.token = token or self._load_token()
        self.headers = {}
        if self.token:
            self.headers["Authorization"] = f"Bearer {self.token}"

    def _load_token(self) -> Optional[str]:
        """Load HA token from secrets"""
        try:
            with open("/Volumes/data/secrets/home_assistant_token") as f:
                return f.read().strip()
        except:
            return None

    def health_check(self) -> ConnectorResult:
        """Verify Home Assistant is reachable"""
        try:
            resp = requests.get(
                f"{self.base_url}/api/",
                headers=self.headers,
                timeout=5
            )
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
        """Execute a Home Assistant operation"""
        try:
            if operation == "turn_on":
                return self._turn_on_device(entity_id=kwargs.get("entity_id"))
            elif operation == "turn_off":
                return self._turn_off_device(entity_id=kwargs.get("entity_id"))
            elif operation == "toggle":
                return self._toggle_device(entity_id=kwargs.get("entity_id"))
            elif operation == "set_brightness":
                return self._set_brightness(
                    entity_id=kwargs.get("entity_id"),
                    brightness=kwargs.get("brightness")
                )
            elif operation == "activate_scene":
                return self._activate_scene(scene_name=kwargs.get("scene"))
            elif operation == "list_devices":
                return self._list_devices()
            elif operation == "get_state":
                return self._get_state(entity_id=kwargs.get("entity_id"))
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Unknown operation: {operation}",
                    connector=self.name
                )
        except Exception as e:
            logger.error(f"Home Assistant error: {e}")
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _turn_on_device(self, entity_id: str) -> ConnectorResult:
        """Turn on a device"""
        try:
            payload = {}
            resp = requests.post(
                f"{self.base_url}/api/services/light/turn_on",
                json={"entity_id": entity_id, **payload},
                headers=self.headers,
                timeout=10
            )
            if resp.status_code == 200:
                logger.info(f"Turned on {entity_id}")
                return ConnectorResult(
                    success=True,
                    data={"entity_id": entity_id, "action": "on"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to turn on {entity_id}: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _turn_off_device(self, entity_id: str) -> ConnectorResult:
        """Turn off a device"""
        try:
            resp = requests.post(
                f"{self.base_url}/api/services/light/turn_off",
                json={"entity_id": entity_id},
                headers=self.headers,
                timeout=10
            )
            if resp.status_code == 200:
                logger.info(f"Turned off {entity_id}")
                return ConnectorResult(
                    success=True,
                    data={"entity_id": entity_id, "action": "off"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to turn off {entity_id}: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _toggle_device(self, entity_id: str) -> ConnectorResult:
        """Toggle a device"""
        try:
            resp = requests.post(
                f"{self.base_url}/api/services/light/toggle",
                json={"entity_id": entity_id},
                headers=self.headers,
                timeout=10
            )
            if resp.status_code == 200:
                logger.info(f"Toggled {entity_id}")
                return ConnectorResult(
                    success=True,
                    data={"entity_id": entity_id, "action": "toggled"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to toggle {entity_id}: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _set_brightness(self, entity_id: str, brightness: int) -> ConnectorResult:
        """Set brightness of a light (0-255)"""
        try:
            brightness = max(0, min(255, brightness))  # Clamp to 0-255
            resp = requests.post(
                f"{self.base_url}/api/services/light/turn_on",
                json={"entity_id": entity_id, "brightness": brightness},
                headers=self.headers,
                timeout=10
            )
            if resp.status_code == 200:
                logger.info(f"Set {entity_id} brightness to {brightness}")
                return ConnectorResult(
                    success=True,
                    data={"entity_id": entity_id, "brightness": brightness},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to set brightness: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _activate_scene(self, scene_name: str) -> ConnectorResult:
        """Activate a Home Assistant scene"""
        try:
            # Scene entity_id is typically "scene.scene_name"
            entity_id = f"scene.{scene_name}" if not scene_name.startswith("scene.") else scene_name
            resp = requests.post(
                f"{self.base_url}/api/services/scene/turn_on",
                json={"entity_id": entity_id},
                headers=self.headers,
                timeout=10
            )
            if resp.status_code == 200:
                logger.info(f"Activated scene {scene_name}")
                return ConnectorResult(
                    success=True,
                    data={"scene": scene_name, "action": "activated"},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to activate scene: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _list_devices(self) -> ConnectorResult:
        """List all available devices/entities"""
        try:
            resp = requests.get(
                f"{self.base_url}/api/states",
                headers=self.headers,
                timeout=10
            )
            if resp.status_code == 200:
                states = resp.json()
                # Filter to just light and switch entities
                devices = [
                    {"entity_id": s["entity_id"], "state": s["state"]}
                    for s in states
                    if s["entity_id"].startswith(("light.", "switch.", "climate."))
                ]
                return ConnectorResult(
                    success=True,
                    data={"devices": devices},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Failed to list devices: {resp.status_code}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )

    def _get_state(self, entity_id: str) -> ConnectorResult:
        """Get current state of a device"""
        try:
            resp = requests.get(
                f"{self.base_url}/api/states/{entity_id}",
                headers=self.headers,
                timeout=10
            )
            if resp.status_code == 200:
                data = resp.json()
                return ConnectorResult(
                    success=True,
                    data={"entity_id": entity_id, "state": data.get("state")},
                    connector=self.name
                )
            else:
                return ConnectorResult(
                    success=False,
                    error=f"Entity not found: {entity_id}",
                    connector=self.name
                )
        except Exception as e:
            return ConnectorResult(
                success=False,
                error=str(e),
                connector=self.name
            )
