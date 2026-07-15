"""
Async task handler for long-running Quinn operations
Returns immediate acknowledgment, processes in background, notifies when complete
"""

import threading
import uuid
import time
import logging
from typing import Dict, Any, Callable, Optional
from datetime import datetime

logger = logging.getLogger(__name__)


class TaskStatus:
    """Track status of async tasks"""
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class AsyncTaskHandler:
    """Manages async tasks with status tracking"""

    def __init__(self):
        self.tasks: Dict[str, Dict[str, Any]] = {}
        self.max_tasks = 100  # Keep last 100 tasks

    def create_task(
        self,
        name: str,
        work_func: Callable,
        acknowledgment: str,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Create async task, return immediate acknowledgment

        Args:
            name: Task name (e.g., "notebooklm_query")
            work_func: Function to execute in background
            acknowledgment: Immediate response to user
            **kwargs: Args to pass to work_func

        Returns:
            Dict with task_id, acknowledgment, and status
        """
        task_id = str(uuid.uuid4())[:8]

        task = {
            "id": task_id,
            "name": name,
            "status": TaskStatus.PENDING,
            "created": datetime.now().isoformat(),
            "result": None,
            "error": None
        }

        self.tasks[task_id] = task

        # Start background thread
        thread = threading.Thread(
            target=self._execute_task,
            args=(task_id, work_func, kwargs),
            daemon=True
        )
        thread.start()

        logger.info(f"[async] Created task {task_id}: {name}")

        return {
            "response": acknowledgment,
            "task_id": task_id,
            "status": "async",
            "message": "I'm working on that in the background."
        }

    def _execute_task(self, task_id: str, work_func: Callable, kwargs: dict):
        """Execute task in background thread"""
        task = self.tasks[task_id]
        task["status"] = TaskStatus.RUNNING
        task["started"] = datetime.now().isoformat()

        try:
            logger.info(f"[async] Starting task {task_id}")
            result = work_func(**kwargs)

            task["status"] = TaskStatus.COMPLETED
            task["result"] = result
            task["completed"] = datetime.now().isoformat()

            logger.info(f"[async] Task {task_id} completed")

        except Exception as e:
            logger.error(f"[async] Task {task_id} failed: {e}")
            task["status"] = TaskStatus.FAILED
            task["error"] = str(e)
            task["completed"] = datetime.now().isoformat()

    def get_status(self, task_id: str) -> Optional[Dict[str, Any]]:
        """Get task status"""
        return self.tasks.get(task_id)

    def list_active(self) -> list:
        """List all active (pending/running) tasks"""
        return [
            {"id": tid, **task}
            for tid, task in self.tasks.items()
            if task["status"] in (TaskStatus.PENDING, TaskStatus.RUNNING)
        ]

    def cleanup_old(self, max_age_seconds: int = 3600):
        """Remove completed tasks older than max_age_seconds"""
        now = time.time()
        to_remove = []

        for task_id, task in self.tasks.items():
            if task["status"] in (TaskStatus.COMPLETED, TaskStatus.FAILED):
                completed = datetime.fromisoformat(task.get("completed", ""))
                age = now - completed.timestamp()
                if age > max_age_seconds:
                    to_remove.append(task_id)

        for task_id in to_remove:
            del self.tasks[task_id]
            logger.info(f"[async] Cleaned up old task {task_id}")


# Global task handler
task_handler = AsyncTaskHandler()


def is_long_running_operation(text: str) -> bool:
    """
    Determine if an operation should run async based on keywords

    Returns True for:
    - NotebookLM queries (30s+)
    - Multi-step research ("research", "analyze", "investigate")
    - Complex tasks ("solve", "figure out", "work through")
    """
    lower = text.lower()

    # Always async
    if any(word in lower for word in [
        "query team-kb",
        "query projects",
        "notebook",
        "research",
        "analyze",
        "investigate",
        "solve",
        "figure out",
        "work through",
        "complex",
        "multi-step"
    ]):
        return True

    return False


def get_acknowledgment(operation_type: str) -> str:
    """Get appropriate acknowledgment message for async operation"""

    acknowledgments = {
        "notebooklm": "I'm checking the knowledge base. This might take a minute.",
        "research": "I'm researching that. Give me a moment.",
        "analysis": "I'm analyzing that. One moment.",
        "complex": "That's a complex question. Let me work through it.",
        "default": "I'm working on that. Just a moment."
    }

    return acknowledgments.get(operation_type, acknowledgments["default"])
