#!/usr/bin/env python3
"""Registro thread-safe y ciclo de vida de comandos en segundo plano."""

from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass


MAX_CAPTURED_OUTPUT = 64 * 1024
JOB_RETENTION_SECONDS = 30 * 60
MAX_RETAINED_JOBS = 200
MAX_JOBS_PER_TURN = 16
TERMINAL_STATES = frozenset({"completed", "failed", "cancelled"})


@dataclass(frozen=True, slots=True)
class JobSnapshot:
    """Vista inmutable de un job que puede cruzar fronteras de hilo."""

    job_id: str
    tool_call_id: str
    command: str
    is_sudo: bool
    status: str
    output: str
    returncode: int
    output_truncated: bool
    turn_id: str = ""
    in_turn: bool = False

    @property
    def is_terminal(self) -> bool:
        return self.status in TERMINAL_STATES


class CommandJob:
    """Estado interno mutable; solo debe modificarse bajo JobManager._lock."""

    __slots__ = (
        "job_id",
        "tool_call_id",
        "command",
        "is_sudo",
        "status",
        "returncode",
        "created_at",
        "finished_at",
        "process",
        "cancel_requested",
        "_output_parts",
        "_output_size",
        "_output_truncated",
        "result_consumed",
        "turn_id",
    )

    def __init__(
        self,
        job_id: str,
        tool_call_id: str,
        command: str,
        is_sudo: bool,
    ) -> None:
        self.job_id = job_id
        self.tool_call_id = tool_call_id
        self.command = command
        self.is_sudo = is_sudo
        self.status = "queued"
        self.returncode = -1
        self.created_at = time.time()
        self.finished_at: float | None = None
        self.process: subprocess.Popen | None = None
        self.cancel_requested = False
        self._output_parts: list[str] = []
        self._output_size = 0
        self._output_truncated = False
        self.result_consumed = False
        self.turn_id = ""

    @property
    def output(self) -> str:
        value = "".join(self._output_parts)
        if self._output_truncated:
            value += "\n[Salida truncada por Minerva]"
        return value

    @property
    def is_terminal(self) -> bool:
        return self.status in TERMINAL_STATES


class JobManager:
    """Registro de jobs con transiciones atómicas y cancelación real."""

    def __init__(self) -> None:
        self._jobs: dict[str, CommandJob] = {}
        self._turn_job_ids: dict[str, list[str]] = {}
        self._turn_sealed: dict[str, bool] = {}
        self._lock = threading.RLock()

    @staticmethod
    def _turn_key(turn_id: str | None) -> str:
        return turn_id or "__default__"

    def _active_turn_job_ids_locked(self) -> set[str]:
        return {
            job_id
            for job_ids in self._turn_job_ids.values()
            for job_id in job_ids
        }

    def _snapshot(self, job: CommandJob) -> JobSnapshot:
        return JobSnapshot(
            job_id=job.job_id,
            tool_call_id=job.tool_call_id,
            command=job.command,
            is_sudo=job.is_sudo,
            status=job.status,
            output=job.output,
            returncode=job.returncode,
            output_truncated=job._output_truncated,
            turn_id=job.turn_id,
            in_turn=job.job_id in self._active_turn_job_ids_locked(),
        )

    def _prune_locked(self) -> None:
        cutoff = time.time() - JOB_RETENTION_SECONDS
        active_job_ids = self._active_turn_job_ids_locked()
        removable = [
            job_id
            for job_id, job in self._jobs.items()
            if job.is_terminal
            and job_id not in active_job_ids
            and (job.finished_at or job.created_at) < cutoff
        ]
        for job_id in removable:
            self._jobs.pop(job_id, None)

        if len(self._jobs) <= MAX_RETAINED_JOBS:
            return
        terminal = sorted(
            (
                job
                for job in self._jobs.values()
                if job.is_terminal and job.job_id not in active_job_ids
            ),
            key=lambda job: job.finished_at or job.created_at,
        )
        for job in terminal[: len(self._jobs) - MAX_RETAINED_JOBS]:
            self._jobs.pop(job.job_id, None)

    def create(
        self,
        tool_call_id: str,
        command: str,
        is_sudo: bool,
    ) -> CommandJob:
        job = CommandJob(uuid.uuid4().hex, tool_call_id, command, is_sudo)
        with self._lock:
            self._prune_locked()
            self._jobs[job.job_id] = job
        return job

    def get(self, job_id: str) -> JobSnapshot | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return self._snapshot(job) if job else None

    def claim(
        self,
        job_id: str,
        *,
        expected_sudo: bool,
    ) -> JobSnapshot | None:
        """Cambia queued->running una sola vez y valida el canal de aprobación."""
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or job.status != "queued" or job.is_sudo != expected_sudo:
                return None
            job.status = "running"
            return self._snapshot(job)

    def attach_process(self, job_id: str, process: subprocess.Popen) -> bool:
        """Registra el proceso; devuelve False si el job ya fue cancelado."""
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or job.cancel_requested or job.status == "cancelled":
                return False
            job.process = process
            return True

    def append_output(self, job_id: str, text: str) -> str:
        """Añade hasta el límite del job y devuelve solo el fragmento retenido."""
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or not text or job.status == "cancelled":
                return ""
            remaining = MAX_CAPTURED_OUTPUT - job._output_size
            if remaining <= 0:
                job._output_truncated = True
                return ""
            captured = text[:remaining]
            job._output_parts.append(captured)
            job._output_size += len(captured)
            if len(captured) != len(text):
                job._output_truncated = True
            return captured

    def should_cancel(self, job_id: str) -> bool:
        with self._lock:
            job = self._jobs.get(job_id)
            return not job or job.cancel_requested or job.status == "cancelled"

    def set_result(
        self,
        job_id: str,
        output: str | None,
        returncode: int,
        success: bool,
    ) -> JobSnapshot | None:
        """Finaliza un job sin revivir uno que ya fue cancelado."""
        with self._lock:
            job = self._jobs.get(job_id)
            if not job:
                return None
            if output and not job._output_parts:
                self.append_output(job_id, output)
            job.process = None
            if job.status != "cancelled":
                job.returncode = returncode
                job.status = "completed" if success else "failed"
            job.finished_at = time.time()
            return self._snapshot(job)

    @staticmethod
    def _signal_process(
        process: subprocess.Popen,
        sig: signal.Signals,
    ) -> None:
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError, OSError):
            try:
                process.send_signal(sig)
            except (ProcessLookupError, OSError):
                pass

    def cancel(self, job_id: str) -> JobSnapshot | None:
        """Marca el job como cancelado y termina su grupo de procesos."""
        process = None
        with self._lock:
            job = self._jobs.get(job_id)
            if not job or job.is_terminal:
                return None
            job.cancel_requested = True
            job.status = "cancelled"
            job.returncode = -signal.SIGTERM
            job.finished_at = time.time()
            process = job.process
            snapshot = self._snapshot(job)
        if process is not None:
            self._signal_process(process, signal.SIGTERM)
        return snapshot

    def start_turn(
        self,
        job_ids: list[str],
        turn_id: str | None = None,
    ) -> None:
        """Registra de una vez un turno ya cerrado (compatibilidad)."""
        key = self._turn_key(turn_id)
        with self._lock:
            self._turn_job_ids[key] = [
                job_id for job_id in job_ids if job_id in self._jobs
            ][:MAX_JOBS_PER_TURN]
            self._turn_sealed[key] = True
            for job_id in self._turn_job_ids[key]:
                self._jobs[job_id].turn_id = key

    def begin_turn(self, turn_id: str | None = None) -> None:
        """Abre un turno antes de publicar jobs al frontend."""
        key = self._turn_key(turn_id)
        with self._lock:
            self._turn_job_ids[key] = []
            self._turn_sealed[key] = False

    def add_turn_job(self, job_id: str, turn_id: str | None = None) -> bool:
        key = self._turn_key(turn_id)
        with self._lock:
            job_ids = self._turn_job_ids.setdefault(key, [])
            self._turn_sealed.setdefault(key, False)
            if job_id not in job_ids and len(job_ids) >= MAX_JOBS_PER_TURN:
                return False
            if job_id in self._jobs and job_id not in job_ids:
                job_ids.append(job_id)
                self._jobs[job_id].turn_id = key
                return True
            return job_id in job_ids

    def seal_turn(self, turn_id: str | None = None) -> None:
        key = self._turn_key(turn_id)
        with self._lock:
            if key in self._turn_job_ids:
                self._turn_sealed[key] = True

    def consume_finished_turn_jobs(
        self,
        turn_id: str | None = None,
    ) -> list[JobSnapshot]:
        """Entrega una sola vez resultados terminales cuando el turno ya cerró."""
        key = self._turn_key(turn_id)
        with self._lock:
            if not self._turn_sealed.get(key, True):
                return []
            snapshots = []
            for job_id in self._turn_job_ids.get(key, []):
                job = self._jobs.get(job_id)
                if job and job.is_terminal and not job.result_consumed:
                    job.result_consumed = True
                    snapshots.append(self._snapshot(job))
            return snapshots

    def get_turn_job_ids(self, turn_id: str | None = None) -> list[str]:
        key = self._turn_key(turn_id)
        with self._lock:
            return list(self._turn_job_ids.get(key, []))

    def is_turn_job(
        self,
        job_id: str,
        turn_id: str | None = None,
    ) -> bool:
        key = self._turn_key(turn_id)
        with self._lock:
            return job_id in self._turn_job_ids.get(key, [])

    def all_turn_finished(self, turn_id: str | None = None) -> bool:
        key = self._turn_key(turn_id)
        with self._lock:
            job_ids = self._turn_job_ids.get(key, [])
            if not self._turn_sealed.get(key, True) or not job_ids:
                return False
            return all(
                (job := self._jobs.get(job_id)) is None or job.is_terminal
                for job_id in job_ids
            )

    def clear_turn(self, turn_id: str | None = None) -> None:
        """Desacopla el turno y conserva resultados durante un TTL corto."""
        key = self._turn_key(turn_id)
        with self._lock:
            for job_id in self._turn_job_ids.pop(key, []):
                job = self._jobs.get(job_id)
                if job and job.turn_id == key:
                    job.turn_id = ""
            self._turn_sealed.pop(key, None)
            self._prune_locked()

    def detach_turn(self, turn_id: str | None = None) -> None:
        self.clear_turn(turn_id)

    def cancel_turn(self, turn_id: str | None = None) -> list[JobSnapshot]:
        snapshots = []
        for job_id in self.get_turn_job_ids(turn_id):
            snapshot = self.cancel(job_id)
            if snapshot:
                snapshots.append(snapshot)
        return snapshots

    def get_all_jobs(self) -> list[dict]:
        with self._lock:
            self._prune_locked()
            return [
                {
                    "job_id": snapshot.job_id,
                    "command": snapshot.command,
                    "status": snapshot.status,
                    "returncode": snapshot.returncode,
                    "output": snapshot.output[:1024],
                    "in_turn": snapshot.in_turn,
                }
                for snapshot in map(self._snapshot, self._jobs.values())
            ]


job_mgr = JobManager()
