"""Herramienta de gestión de tareas."""

import datetime

from ..core.tasks_db import (
    add_task,
    clear_completed_tasks,
    complete_task,
    delete_task,
    edit_task,
    get_pending_tasks,
    get_task_by_id,
)


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
    confirm: bool = False,
) -> str:
    """Añade, completa, edita, elimina o lista tareas en PostgreSQL."""
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

    if action == "edit":
        if task_id is None or task_id < 1:
            return "Error: se requiere un task_id válido para editar una tarea."

        existing = get_task_by_id(task_id)
        if not existing:
            return f"Error: no se encontró la tarea #{task_id}."

        clean_desc = description.strip() if description else ""
        if clean_desc and len(clean_desc) > 2_000:
            return "Error: la descripción no puede superar 2000 caracteres."

        parsed_due_date = None
        clear_due = False
        if due_date is not None:
            due_str = due_date.strip().lower()
            if due_str in ("none", "clear", "null", ""):
                clear_due = True
            else:
                try:
                    parsed_due_date = datetime.datetime.strptime(
                        due_date.strip(),
                        "%Y-%m-%d %H:%M:%S",
                    )
                except (AttributeError, ValueError):
                    return "Error: due_date debe usar YYYY-MM-DD HH:MM:SS."

        clear_rec = False
        new_recurrence = None
        if recurrence is not None:
            rec_str = recurrence.strip().lower()
            if rec_str in ("none", "clear", "null", ""):
                clear_rec = True
            else:
                new_recurrence = rec_str

        # Validar recurrencia combinando valores existentes y nuevos
        if clear_rec:
            eff_recurrence = None
            eff_day = None
            eff_month = None
        else:
            eff_recurrence = new_recurrence if new_recurrence is not None else existing.get("recurrence")
            eff_day = recurrence_day if recurrence_day is not None else existing.get("recurrence_day")
            eff_month = recurrence_month if recurrence_month is not None else existing.get("recurrence_month")

            if eff_recurrence is not None or recurrence_day is not None or recurrence_month is not None:
                rec_error = _validate_recurrence(eff_recurrence, eff_day, eff_month)
                if rec_error:
                    return f"Error: {rec_error}."

        has_change = (
            bool(clean_desc)
            or clear_due
            or (parsed_due_date is not None)
            or clear_rec
            or (new_recurrence is not None)
            or (recurrence_day is not None)
            or (recurrence_month is not None)
        )
        if not has_change:
            return f"Error: no se indicaron campos para actualizar en la tarea #{task_id}."

        success = edit_task(
            task_id=task_id,
            description=clean_desc if clean_desc else None,
            due_date=parsed_due_date,
            recurrence=new_recurrence,
            recurrence_day=recurrence_day,
            recurrence_month=recurrence_month,
            clear_due_date=clear_due,
            clear_recurrence=clear_rec,
        )
        if not success:
            return f"Error al actualizar la tarea #{task_id} en la base de datos."

        changes = []
        if clean_desc:
            changes.append(f"descripción: '{clean_desc}'")
        if clear_due:
            changes.append("fecha límite eliminada")
        elif parsed_due_date:
            changes.append(f"fecha límite: {parsed_due_date}")
        if clear_rec:
            changes.append("recurrencia eliminada")
        elif new_recurrence or recurrence_day is not None or recurrence_month is not None:
            label = _RECURRENCE_LABELS.get(eff_recurrence, eff_recurrence)
            day_info = f" día {eff_day}" if eff_day is not None else ""
            month_info = f" mes {eff_month}" if eff_month is not None else ""
            changes.append(f"recurrencia: {label}{day_info}{month_info}")

        return f"Tarea #{task_id} actualizada correctamente ({', '.join(changes)})."

    if action == "delete":
        if task_id is None or task_id < 1:
            return "Error: se requiere un task_id válido para eliminar una tarea."

        task = get_task_by_id(task_id)
        if not task:
            return f"Error: no existe ninguna tarea con ID #{task_id}."

        if not confirm:
            due = f" | Vencimiento: {task['due_date']}" if task.get("due_date") else ""
            rec = f" | Recurrencia: {task['recurrence']}" if task.get("recurrence") else ""
            status = f" | Estado: {task.get('status', 'desconocido')}"
            return (
                f"Confirmación requerida para eliminar la tarea #{task_id}: "
                f"'{task['description']}'{status}{due}{rec}. "
                "Pide confirmación explícita al usuario en el chat antes de ejecutar la eliminación con confirm=True."
            )

        if delete_task(task_id):
            return f"Tarea #{task_id} ('{task['description']}') eliminada permanentemente."
        return f"Error al eliminar la tarea #{task_id} en la base de datos."

    if action == "clear_completed":
        deleted = clear_completed_tasks()
        if deleted is None:
            return "Error: no se pudieron limpiar las tareas completadas en PostgreSQL."
        if deleted == 0:
            return "No se encontraron tareas completadas no recurrentes para limpiar."
        return f"Se eliminaron {deleted} tarea(s) completada(s) del historial (las tareas recurrentes se conservaron)."

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

    return "Error: action debe ser add, complete, list, edit, delete o clear_completed."
