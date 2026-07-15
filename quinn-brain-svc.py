#!/usr/bin/env python3
"""
Quinn Brain Service - Intelligent model routing for conversational AI
Runs as a background service that SoniqueBar calls via HTTP
Uses Claude CLI subscription (NOT API) - fallback to Bedrock if needed
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import subprocess
import json
import logging
import sys
import os
from pathlib import Path
from typing import Optional, Dict, Any

# Add connectors to path
sys.path.insert(0, str(Path(__file__).parent))

from connectors.registry import ConnectorRegistry

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

# Initialize connector registry
registry = ConnectorRegistry()


def _load_personality() -> str:
    """Load Quinn personality from iCloud brain files"""
    try:
        icloud_base = Path.home() / "Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/shared"

        identity = ""
        rules = ""
        soul = ""

        # Load IDENTITY.md
        identity_file = icloud_base / "IDENTITY.md"
        if identity_file.exists():
            with open(identity_file) as f:
                identity = f.read()

        # Load RULES.md
        rules_file = icloud_base / "RULES.md"
        if rules_file.exists():
            with open(rules_file) as f:
                rules = f.read()

        # Load SOUL.md
        soul_file = icloud_base / "SOUL.md"
        if soul_file.exists():
            with open(soul_file) as f:
                soul = f.read()

        # Combine into system prompt
        persona = f"""You are Quinn, a conversational voice assistant.

{identity}

{rules}

{soul}

Keep responses natural, brief (1-2 sentences max), and action-oriented.
No markdown formatting.
"""
        logger.info("Loaded Quinn personality from iCloud brain")
        return persona.strip()
    except Exception as e:
        logger.warning(f"Failed to load personality: {e}, using default")
        return "You are Quinn, a conversational voice assistant. Keep responses natural and brief (1-2 sentences max). No markdown formatting."


def _load_bedrock_env() -> dict:
    """Load Bedrock AWS credentials from secrets"""
    env_file = "/Volumes/data/secrets/aws_bedrock.env"
    env = {}
    try:
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, val = line.split('=', 1)
                    env[key] = val
    except:
        pass
    return env


def select_model(text: str) -> str:
    """Select the right model based on query complexity"""
    lower = text.lower()

    # Sonnet for questions, reasoning, complex tasks
    if any(word in lower for word in ["why", "how", "explain", "understand", "think", "reason"]):
        return "sonnet"

    # Opus for very complex tasks
    if any(word in lower for word in ["analyze", "comprehensive", "complex", "detailed"]):
        return "opus"

    # Haiku for everything else (fast, conversational)
    return "haiku"


def _try_connector_operation(text: str, registry: ConnectorRegistry) -> Optional[Dict[str, Any]]:
    """Try to route to a connector if the text matches a known pattern"""
    lower = text.lower()

    # Helmsman operations
    if "create" in lower and "task" in lower:
        # Extract task description
        parts = text.split(":", 1)
        if len(parts) > 1:
            task_desc = parts[1].strip()
            result = registry.execute("helmsman", "create_task", task=task_desc)
            if result.success:
                return {
                    "response": f"Task created successfully: {task_desc}",
                    "connector": "helmsman",
                    "status": "ok"
                }

    if "pending" in lower and ("task" in lower or "queue" in lower):
        result = registry.execute("helmsman", "list_pending")
        if result.success:
            tasks = result.data.get("tasks", []) if isinstance(result.data, dict) else result.data
            task_count = len(tasks) if tasks else 0
            return {
                "response": f"You have {task_count} pending tasks.",
                "connector": "helmsman",
                "status": "ok"
            }

    # Docker operations
    if "restart" in lower and "container" in lower:
        words = lower.split()
        container_idx = words.index("container") if "container" in words else -1
        if container_idx >= 0 and container_idx + 1 < len(words):
            container_name = words[container_idx + 1]
            result = registry.execute("docker", "restart_container", container=container_name)
            if result.success:
                return {
                    "response": f"Restarted container {container_name}.",
                    "connector": "docker",
                    "status": "ok"
                }

    if "list" in lower and "container" in lower:
        result = registry.execute("docker", "list_containers")
        if result.success:
            containers = result.data.get("containers", [])
            count = len(containers)
            return {
                "response": f"You have {count} running containers.",
                "connector": "docker",
                "status": "ok"
            }

    # NotebookLM operations
    if "query" in lower and ("notebook" in lower or "team-kb" in lower or "projects" in lower):
        # Extract query
        parts = text.split(":", 1)
        if len(parts) > 1:
            query = parts[1].strip()
            # Default to team-kb if not specified
            result = registry.execute("notebooklm", "query_team_kb", query=query)
            if result.success:
                response = result.data.get("response", "No response")
                return {
                    "response": response[:500],  # Truncate to avoid very long responses
                    "connector": "notebooklm",
                    "status": "ok"
                }

    # Home Assistant operations
    if ("turn" in lower and "on" in lower) or ("turn" in lower and "off" in lower):
        if "light" in lower or "bedroom" in lower or "kitchen" in lower or "living" in lower:
            if "on" in lower:
                result = registry.execute("home_assistant", "turn_on", entity_id="light.bedroom")
                if result.success:
                    return {
                        "response": "Turned on the light.",
                        "connector": "home_assistant",
                        "status": "ok"
                    }
            else:
                result = registry.execute("home_assistant", "turn_off", entity_id="light.bedroom")
                if result.success:
                    return {
                        "response": "Turned off the light.",
                        "connector": "home_assistant",
                        "status": "ok"
                    }

    # Vault operations
    if "search vault" in lower or "vault search" in lower or "find in vault" in lower:
        # Extract search query
        parts = text.split(":", 1) if ":" in text else text.split("for", 1)
        if len(parts) > 1:
            query = parts[1].strip()
            result = registry.execute("vault", "search", query=query)
            if result.success:
                data = result.data
                matches = data.get("matches", [])
                if matches:
                    # Format first match
                    first = matches[0]
                    response = f"Found in {first['file']}: {first['snippet'][:100]}"
                    return {
                        "response": response,
                        "connector": "vault",
                        "status": "ok"
                    }
                else:
                    return {
                        "response": f"No vault notes found for '{query}'.",
                        "connector": "vault",
                        "status": "ok"
                    }

    if "list projects" in lower or "what projects" in lower:
        result = registry.execute("vault", "list_project_notes")
        if result.success:
            projects = result.data.get("projects", [])
            count = len(projects)
            return {
                "response": f"You have {count} active projects: {', '.join(projects[:5])}.",
                "connector": "vault",
                "status": "ok"
            }

    # No connector matched
    return None


def get_response(text: str, registry: ConnectorRegistry) -> dict:
    """Get conversational response from Claude subscription with connector support"""
    try:
        model = select_model(text)
        logger.info(f"Using model: {model} for: {text[:50]}")

        # Check if this is a connector operation
        connector_result = _try_connector_operation(text, registry)
        if connector_result:
            return connector_result

        # Load personality
        persona_prompt = _load_personality()

        # Use Claude CLI subscription (NOT API)
        prompt = f"{persona_prompt}\n\nUser: {text}"
        result = subprocess.run(
            ["/opt/homebrew/bin/claude", "-p", "--model", model, prompt],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode == 0 and result.stdout:
            response_text = result.stdout.strip()
            logger.info(f"Response: {response_text[:50]}")
            return {
                "response": response_text,
                "model": model,
                "status": "ok"
            }
        else:
            # Fallback to Bedrock if CLI fails
            logger.warning(f"CLI failed, trying Bedrock: {result.stderr}")
            bedrock_env = _load_bedrock_env()
            bedrock_result = subprocess.run(
                ["/Users/charlieseay/.local/bin/ask_claude_bedrock", prompt],
                capture_output=True,
                text=True,
                timeout=30,
                env={**subprocess.os.environ, **bedrock_env}
            )

            if bedrock_result.returncode == 0:
                response_text = bedrock_result.stdout.strip()
                logger.info(f"Bedrock response: {response_text[:50]}")
                return {
                    "response": response_text,
                    "model": f"bedrock-{model}",
                    "status": "ok"
                }
            else:
                raise Exception(f"Both CLI and Bedrock failed")
    except Exception as e:
        logger.error(f"Error: {e}")
        return {
            "response": f"I heard you say: {text}",
            "model": "fallback",
            "status": "error",
            "error": str(e)
        }


class QuinnHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        """Suppress default HTTP logs"""
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "service": "quinn-brain"}).encode())
        elif self.path == "/connectors/health":
            health = registry.health_check_all()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(health).encode())
        elif self.path == "/connectors":
            connectors = registry.list_connectors()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(connectors).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/respond":
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length))
            text = body.get("text", "")

            result = get_response(text, registry)

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    PORT = 5912
    server = HTTPServer(("127.0.0.1", PORT), QuinnHandler)
    logger.info(f"Quinn Brain Service running on port {PORT}")
    logger.info("Model routing: Haiku (default) → Sonnet (medium) → Opus (complex)")
    logger.info(f"Connectors initialized: {', '.join(registry.list_connectors().keys())}")
    server.serve_forever()
