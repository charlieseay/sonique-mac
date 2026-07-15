#!/usr/bin/env python3
"""
Quinn Brain Service - Intelligent model routing for conversational AI
Runs as a background service that SoniqueBar calls via HTTP
Haiku by default, escalates to Sonnet/Opus as needed
"""

from anthropic import Anthropic
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

# Read API key
API_KEY_PATH = Path("/Volumes/data/secrets/anthropic_api_key")
client = Anthropic(api_key=API_KEY_PATH.read_text().strip())

PERSONA = "You are Quinn, a conversational voice assistant. Keep responses natural and brief (1-2 sentences max). No markdown formatting."

def select_model(text: str) -> str:
    """Select the right model based on query complexity"""
    lower = text.lower()

    # For now, use Haiku for everything (fast, conversational)
    # TODO: Add Sonnet/Opus escalation when model IDs confirmed
    return "claude-haiku-4-5-20251001"

def get_response(text: str) -> dict:
    """Get conversational response from Claude"""
    try:
        model = select_model(text)
        logger.info(f"Using model: {model} for: {text[:50]}")

        message = client.messages.create(
            model=model,
            max_tokens=150,
            system=PERSONA,
            messages=[{"role": "user", "content": text}]
        )

        response_text = message.content[0].text.strip()
        logger.info(f"Response: {response_text[:50]}")

        return {
            "response": response_text,
            "model": model.split("-")[1],  # "haiku", "sonnet", or "opus"
            "status": "ok"
        }
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
