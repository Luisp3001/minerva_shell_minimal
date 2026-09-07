"""Herramienta de gestión de tareas."""

import datetime

from ..core.tasks_db import add_task, complete_task, get_pending_tasks


_RECURRENCE_LABELS = {
    "daily": "Diaria",
    "weekly": "Semanal",
    "monthly": "Mensual",
    "yearly": "Anual",
}
MAX_RENDERED_TASKS = 200
MAX_TASK_OUTPUT = 64 * 1024


def _validate_recurrence(
    recurrence: str | None,
    recurrence_day: int | None,
    recurrence_month: int | None,
) -> str | None:
    if recurrence is None:
        if recurrence_day is not None or recurrence_month is not None:
            return "recurrence_day/month requieren recurrence"
        return None
    if recurrence not in _RECURRENCE_LABELS:
        return "recurrence debe ser daily, weekly, monthly o yearly"
    if recurrence == "weekly" and recurrence_day is not None:
        if not 0 <= recurrence_day <= 6:
            return "recurrence_day semanal debe estar entre 0 y 6"
    elif recurrence in {"monthly", "yearly"} and recurrence_day is not None:
        if not 1 <= recurrence_day <= 31:
            return "recurrence_day mensual/anual debe estar entre 1 y 31"
    if recurrence_month is not None:
        if recurrence != "yearly" or not 1 <= recurrence_month <= 12:
            return "recurrence_month solo aplica a yearly y debe estar entre 1 y 12"
    return None


def tool_manage_tasks(
    action: str,
    description: str = "",
    task_id: int | None = None,
    due_date: str | None = None,
    recurrence: str | None = None,
    recurrence_day: int | None = None,
    recurrence_month: int | None = None,
) -> str:
    """Añade, completa o lista tareas en PostgreSQL."""
    if action == "add":
        description = description.strip()
        if not description:
            return "Error: se requiere una descripción para añadir una tarea."
        if len(description) > 2_000:
            return "Error: la descripción no puede superar 2000 caracteres."
        parsed_due_date = None
        if due_date:
            try:
                parsed_due_date = datetime.datetime.strptime(
                    due_date.strip(),
                    "%Y-%m-%d %H:%M:%S",
                )
            except (AttributeError, ValueError):
                return "Error: due_date debe usar YYYY-MM-DD HH:MM:SS."
        recurrence_error = _validate_recurrence(
            recurrence,
            recurrence_day,
            recurrence_month,
        )
        if recurrence_error:
            return f"Error: {recurrence_error}."
        if not add_task(
            description,
            parsed_due_date,
            recurrence,
            recurrence_day,
            recurrence_month,
        ):
            return "Error al añadir la tarea a la base de datos."

        recurrence_info = ""
        if recurrence:
            label = _RECURRENCE_LABELS[recurrence]
            day_info = (
                f" (día {recurrence_day})"
                if recurrence_day is not None
                else ""
            )
            month_info = (
                f" del mes {recurrence_month}"
                if recurrence_month is not None
                else ""
            )
            recurrence_info = (
                f" | Recurrencia: {label}{day_info}{month_info}"
            )
        return f"Tarea '{description}' añadida.{recurrence_info}"

    if action == "complete":
        if task_id is None or task_id < 1:
            return "Error: se requiere un task_id válido."
        if complete_task(task_id):
            return f"Tarea #{task_id} marcada como completada."
        return f"Error al completar la tarea #{task_id}."

    if action == "list":
        tasks = get_pending_tasks()
        if tasks is None:
            return "Error: no se pudo consultar PostgreSQL."
        if not tasks:
            return "No hay tareas pendientes en este momento."

        lines = ["Tareas pendientes:"]
        for task in tasks[:MAX_RENDERED_TASKS]:
            due = f" (Para: {task['due_date']})" if task.get("due_date") else ""
            recurrence_value = task.get("recurrence")
            recurrence_text = ""
            if recurrence_value:
                label = _RECURRENCE_LABELS.get(
                    recurrence_value,
                    recurrence_value,
                )
                day = task.get("recurrence_day")
                month = task.get("recurrence_month")
                day_info = f" día {day}" if day is not None else ""
                month_info = f" mes {month}" if month is not None else ""
                recurrence_text = (
                    f" [Recurrencia: {label}{day_info}{month_info}]"
                )
            lines.append(
                f"- [ID: {task['id']}] {task['description']}"
                f"{due}{recurrence_text}"
            )
            if sum(map(len, lines)) >= MAX_TASK_OUTPUT:
                lines.append("… salida de tareas truncada")
                break
        if len(tasks) > MAX_RENDERED_TASKS:
            lines.append(f"… {len(tasks) - MAX_RENDERED_TASKS} tareas omitidas")
        return "\n".join(lines)[:MAX_TASK_OUTPUT]

    return "Error: action debe ser add, complete o list."
