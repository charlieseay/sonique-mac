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

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

PERSONA = "You are Quinn, a conversational voice assistant. Keep responses natural and brief (1-2 sentences max). No markdown formatting."

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

    # For now, use Haiku for everything (fast, conversational)
    # TODO: Add Sonnet/Opus escalation when confirmed working
    return "haiku"

def get_response(text: str) -> dict:
    """Get conversational response from Claude subscription"""
    try:
        model = select_model(text)
        logger.info(f"Using model: {model} for: {text[:50]}")

        # Use Claude CLI subscription (NOT API)
        prompt = f"{PERSONA}\n\nUser: {text}"
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
            bedrock_result = subprocess.run(
                ["/Users/charlieseay/.local/bin/ask_claude_bedrock", prompt],
                capture_output=True,
                text=True,
                timeout=30,
                env={**subprocess.os.environ, **_load_bedrock_env()}
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
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/respond":
            content_length = int(self.headers['Content-Length'])
            body = json.loads(self.rfile.read(content_length))
            text = body.get("text", "")

            result = get_response(text)

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
    server.serve_forever()
