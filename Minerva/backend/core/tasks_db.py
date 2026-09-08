import datetime
import os

import psycopg2
from psycopg2.extras import RealDictCursor

from .io import emit_error


def get_connection(*, report_error: bool = True):
    """Abre PostgreSQL usando las variables de entorno configuradas."""
    try:
        conn = psycopg2.connect(
            host=os.getenv("DB_HOST", "localhost"),
            port=os.getenv("DB_PORT", "5432"),
            user=os.getenv("DB_USER", "postgres"),
            password=os.getenv("DB_PASSWORD", ""),
            dbname=os.getenv("DB_NAME", "postgres"),
            connect_timeout=5,
            application_name="minerva",
        )
        return conn
    except Exception as e:
        if report_error:
            emit_error(
                "No se pudo conectar a PostgreSQL: "
                f"{type(e).__name__}"
            )
        return None


def init_db(*, report_error: bool = True) -> bool:
    """Crea la tabla y sus columnas si todavía no existen."""
    conn = get_connection(report_error=report_error)
    if not conn:
        return False

    try:
        with conn:
            with conn.cursor() as cursor:
                # Tabla base
                cursor.execute("""
                    CREATE TABLE IF NOT EXISTS minerva_tasks (
                        id SERIAL PRIMARY KEY,
                        description TEXT NOT NULL,
                        status VARCHAR(20) DEFAULT 'pending',
                        due_date TIMESTAMP NULL,
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    );
                """)
                # Columnas de recurrencia: ADD COLUMN IF NOT EXISTS es idempotente
                # y funciona tanto en tablas nuevas como en las ya existentes.
                cursor.execute("""
                    ALTER TABLE minerva_tasks
                        ADD COLUMN IF NOT EXISTS recurrence VARCHAR(10) NULL;
                """)
                cursor.execute("""
                    ALTER TABLE minerva_tasks
                        ADD COLUMN IF NOT EXISTS recurrence_day INTEGER NULL;
                """)
                cursor.execute("""
                    ALTER TABLE minerva_tasks
                        ADD COLUMN IF NOT EXISTS recurrence_month INTEGER NULL;
                """)
        return True
    except Exception as e:
        if report_error:
            emit_error(
                "No se pudo inicializar la base de tareas: "
                f"{type(e).__name__}"
            )
        return False
    finally:
        conn.close()


def _next_due_date(current_due_date, recurrence, recurrence_day, recurrence_month=None):
    """
    Calcula la próxima fecha de vencimiento basada en la recurrencia.

    - 'daily'   → +1 día.
    - 'weekly'  → +7 días; si recurrence_day indica día de semana (0=lun…6=dom)
                  avanza hasta el siguiente día de esa semana.
    - 'monthly' → +1 mes anclado al recurrence_day del mes (si se proporcionó).
    - 'yearly'  → +1 año anclado al recurrence_day del mes (si se proporcionó).
    """
    if not recurrence or not current_due_date:
        return None

    try:
        from dateutil.relativedelta import relativedelta
    except ImportError:
        # Fallback sin dateutil: usar lógica básica de timedelta
        relativedelta = None

    new_date = None

    if recurrence == 'daily':
        new_date = current_due_date + datetime.timedelta(days=1)

    elif recurrence == 'weekly':
        if recurrence_day is not None:
            # Avanzar hasta el próximo día de la semana indicado
            days_ahead = (recurrence_day - current_due_date.weekday()) % 7
            if days_ahead == 0:
                days_ahead = 7  # mismo día de la semana, ir a la siguiente
            new_date = current_due_date + datetime.timedelta(days=days_ahead)
        else:
            new_date = current_due_date + datetime.timedelta(weeks=1)

    elif recurrence == 'monthly':
        if relativedelta:
            next_dt = current_due_date + relativedelta(months=1)
        else:
            # Sin dateutil: avanzar al primer día del mes siguiente y ajustar
            first_next = (
                current_due_date.replace(day=1)
                + datetime.timedelta(days=32)
            ).replace(day=1)
            next_dt = first_next
        if recurrence_day:
            import calendar
            max_day = calendar.monthrange(next_dt.year, next_dt.month)[1]
            next_dt = next_dt.replace(day=min(recurrence_day, max_day))
        new_date = next_dt

    elif recurrence == 'yearly':
        if relativedelta:
            next_dt = current_due_date + relativedelta(years=1)
        else:
            try:
                next_dt = current_due_date.replace(year=current_due_date.year + 1)
            except ValueError:  # 29 feb en año no bisiesto
                next_dt = current_due_date.replace(
                    year=current_due_date.year + 1,
                    day=28,
                )
        if recurrence_month:
            # Anclar al mes indicado aunque la fecha anterior fuese distinta.
            next_dt = next_dt.replace(month=recurrence_month)
        if recurrence_day:
            import calendar
            max_day = calendar.monthrange(next_dt.year, next_dt.month)[1]
            next_dt = next_dt.replace(day=min(recurrence_day, max_day))
        new_date = next_dt

    return new_date


def get_pending_tasks(*, report_error: bool = True) -> list | None:
    """Devuelve una lista de tareas pendientes."""
    conn = get_connection(report_error=report_error)
    if not conn:
        return None

    tasks = None
    try:
        with conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                cursor.execute("""
                    SELECT id, description, status, due_date, recurrence,
                           recurrence_day, recurrence_month
                    FROM minerva_tasks
                    WHERE status = 'pending'
                    ORDER BY created_at ASC
                    LIMIT 500;
                """)
                tasks = cursor.fetchall()
    except Exception as e:
        if report_error:
            emit_error(
                "No se pudieron consultar las tareas: "
                f"{type(e).__name__}"
            )
    finally:
        conn.close()
    return tasks


def _initial_due_date(
    recurrence: str,
    recurrence_day: int | None,
    recurrence_month: int | None = None,
) -> datetime.datetime | None:
    """
    Calcula la primera fecha de vencimiento para una tarea recurrente nueva
    que no trae due_date explícito.

    Lógica: busca la próxima ocurrencia a partir de HOY.
    - 'daily'   → mañana a medianoche.
    - 'weekly'  → el próximo recurrence_day de semana (0=lun…6=dom), o en 7 días.
    - 'monthly' → siguiente recurrence_day mensual.
    - 'yearly'  → siguiente recurrence_day anual.
    """
    import calendar
    try:
        from dateutil.relativedelta import relativedelta
        _has_dateutil = True
    except ImportError:
        _has_dateutil = False

    now = datetime.datetime.now()
    today = now.date()

    if recurrence == "daily":
        return datetime.datetime.combine(
            today + datetime.timedelta(days=1),
            datetime.time(8, 0),
        )

    if recurrence == "weekly":
        target_weekday = (
            recurrence_day
            if recurrence_day is not None
            else today.weekday()
        )
        days_ahead = (target_weekday - today.weekday()) % 7
        if days_ahead == 0:
            days_ahead = 7  # hoy mismo → próxima semana
        return datetime.datetime.combine(
            today + datetime.timedelta(days=days_ahead),
            datetime.time(8, 0),
        )

    if recurrence == "monthly":
        day = recurrence_day or today.day
        max_day = calendar.monthrange(today.year, today.month)[1]
        day = min(day, max_day)
        candidate = datetime.date(today.year, today.month, day)
        if candidate <= today:
            # Ya pasó este mes → ir al siguiente
            if _has_dateutil:
                next_month = (today.replace(day=1) + relativedelta(months=1))
            else:
                next_month = (
                    today.replace(day=1) + datetime.timedelta(days=32)
                ).replace(day=1)
            max_day = calendar.monthrange(next_month.year, next_month.month)[1]
            candidate = datetime.date(
                next_month.year,
                next_month.month,
                min(day, max_day),
            )
        return datetime.datetime.combine(candidate, datetime.time(8, 0))

    if recurrence == "yearly":
        month = recurrence_month or today.month
        day = recurrence_day or today.day
        max_day = calendar.monthrange(today.year, month)[1]
        day = min(day, max_day)
        candidate = datetime.date(today.year, month, day)
        if candidate <= today:
            next_year = today.year + 1
            max_day = calendar.monthrange(next_year, month)[1]
            candidate = datetime.date(next_year, month, min(day, max_day))
        return datetime.datetime.combine(candidate, datetime.time(8, 0))

    return None


def add_task(
    description,
    due_date=None,
    recurrence=None,
    recurrence_day=None,
    recurrence_month=None,
):
    """
    Agrega una nueva tarea a la base de datos.

    Si la tarea es recurrente y no se proporciona due_date, calcula
    automáticamente la primera fecha de vencimiento usando _initial_due_date().
    """
    conn = get_connection()
    if not conn:
        return False

    # Auto-calcular due_date para tareas recurrentes sin fecha explícita
    if recurrence and not due_date:
        due_date = _initial_due_date(recurrence, recurrence_day, recurrence_month)

    try:
        with conn:
            with conn.cursor() as cursor:
                cursor.execute("""
                    INSERT INTO minerva_tasks (
                        description, due_date, recurrence,
                        recurrence_day, recurrence_month
                    )
                    VALUES (%s, %s, %s, %s, %s);
                """, (
                    description,
                    due_date,
                    recurrence,
                    recurrence_day,
                    recurrence_month,
                ))
        return True
    except Exception as exc:
        emit_error(f"Error agregando tarea: {type(exc).__name__}")
        return False
    finally:
        conn.close()


def complete_task(task_id):
    """
    Marca una tarea como completada.

    Para tareas recurrentes la renovación (nuevo due_date + status='pending')
    la gestiona renew_recurring_tasks() en el worker de fondo, no aquí.
    """
    conn = get_connection()
    if not conn:
        return False

    try:
        with conn:
            with conn.cursor() as cursor:
                cursor.execute("""
                    UPDATE minerva_tasks
                    SET status = 'completed'
                    WHERE id = %s AND status = 'pending';
                """, (task_id,))
                updated = cursor.rowcount
        return updated == 1
    except Exception as exc:
        emit_error(f"Error completando tarea: {type(exc).__name__}")
        return False
    finally:
        conn.close()


def renew_recurring_tasks(*, report_error: bool = True) -> bool:
    """
    Revisa tareas recurrentes cuyo due_date ya pasó y las renueva en el futuro.

    Estrategia: actualiza el due_date de la fila existente a la próxima ocurrencia
    y la deja como 'pending', en lugar de crear filas nuevas. Así el historial no
    crece indefinidamente.

    Si el backend estuvo apagado varios ciclos, avanza en bucle hasta que el
    próximo due_date quede en el futuro.

    Llamado desde _tasks_worker en main.py antes de consultar pendientes.
    """
    conn = get_connection(report_error=report_error)
    if not conn:
        return False

    now = datetime.datetime.now()
    try:
        with conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                cursor.execute("""
                    SELECT id, due_date, recurrence, recurrence_day,
                           recurrence_month
                    FROM minerva_tasks
                    WHERE recurrence IS NOT NULL
                      AND due_date IS NOT NULL
                      AND due_date < %s
                """, (now,))
                expired = cursor.fetchall()

        for task in expired:
            next_due = _next_due_date(
                task["due_date"],
                task["recurrence"],
                task.get("recurrence_day"),
                task.get("recurrence_month"),
            )
            if not next_due:
                continue
            # Si sigue en el pasado, avanzar hasta la siguiente ocurrencia.
            advances = 0
            while next_due < now and advances < 10_000:
                next_due = _next_due_date(
                    next_due,
                    task["recurrence"],
                    task.get("recurrence_day"),
                    task.get("recurrence_month"),
                )
                advances += 1
                if not next_due:
                    break

            if next_due:
                with conn:
                    with conn.cursor() as cursor:
                        cursor.execute("""
                            UPDATE minerva_tasks
                            SET due_date = %s, status = 'pending'
                            WHERE id = %s;
                        """, (next_due, task["id"]))
        return True
    except Exception as e:
        if report_error:
            emit_error(
                "No se pudieron renovar las tareas: "
                f"{type(e).__name__}"
            )
        return False
    finally:
        conn.close()


def get_task_by_id(task_id: int, *, report_error: bool = True) -> dict | None:
    """Devuelve los detalles de una tarea específica por su ID."""
    conn = get_connection(report_error=report_error)
    if not conn:
        return None

    task = None
    try:
        with conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cursor:
                cursor.execute("""
                    SELECT id, description, status, due_date, recurrence,
                           recurrence_day, recurrence_month
                    FROM minerva_tasks
                    WHERE id = %s;
                """, (task_id,))
                task = cursor.fetchone()
    except Exception as e:
        if report_error:
            emit_error(
                f"No se pudo consultar la tarea #{task_id}: "
                f"{type(e).__name__}"
            )
    finally:
        conn.close()
    return task


def delete_task(task_id: int) -> bool:
    """
    Elimina permanentemente una tarea por su ID.
    Solo debe llamarse tras confirmación explícita del usuario.
    """
    conn = get_connection()
    if not conn:
        return False

    try:
        with conn:
            with conn.cursor() as cursor:
                cursor.execute("""
                    DELETE FROM minerva_tasks
                    WHERE id = %s;
                """, (task_id,))
                deleted = cursor.rowcount
        return deleted == 1
    except Exception as exc:
        emit_error(f"Error eliminando tarea #{task_id}: {type(exc).__name__}")
        return False
    finally:
        conn.close()


def clear_completed_tasks(*, report_error: bool = True) -> int | None:
    """
    Elimina permanentemente las tareas completadas que NO sean recurrentes.

    Las tareas periódicas (recurrence IS NOT NULL) se conservan intactas para
    permitir su auto-renovación por parte de renew_recurring_tasks().

    Retorna el número de tareas eliminadas o None en caso de error.
    """
    conn = get_connection(report_error=report_error)
    if not conn:
        return None

    try:
        with conn:
            with conn.cursor() as cursor:
                cursor.execute("""
                    DELETE FROM minerva_tasks
                    WHERE status = 'completed'
                      AND (recurrence IS NULL OR recurrence = '');
                """)
                deleted_count = cursor.rowcount
        return deleted_count
    except Exception as exc:
        if report_error:
            emit_error(
                f"Error limpiando tareas completadas: {type(exc).__name__}"
            )
        return None
    finally:
        conn.close()


def edit_task(
    task_id: int,
    description: str | None = None,
    due_date: datetime.datetime | str | None = None,
    recurrence: str | None = None,
    recurrence_day: int | None = None,
    recurrence_month: int | None = None,
    clear_due_date: bool = False,
    clear_recurrence: bool = False,
) -> bool:
    """
    Actualiza campos específicos de una tarea existente.
    Solo modifica las columnas pasadas de forma explícita.
    """
    sets = []
    params = []

    if description is not None and description.strip():
        sets.append("description = %s")
        params.append(description.strip())

    if clear_due_date:
        sets.append("due_date = NULL")
    elif due_date is not None:
        sets.append("due_date = %s")
        params.append(due_date)

    if clear_recurrence:
        sets.extend(["recurrence = NULL", "recurrence_day = NULL", "recurrence_month = NULL"])
    else:
        if recurrence is not None:
            sets.append("recurrence = %s")
            params.append(recurrence)
        if recurrence_day is not None:
            sets.append("recurrence_day = %s")
            params.append(recurrence_day)
        if recurrence_month is not None:
            sets.append("recurrence_month = %s")
            params.append(recurrence_month)

    if not sets:
        return False

    params.append(task_id)

    conn = get_connection()
    if not conn:
        return False

    try:
        with conn:
            with conn.cursor() as cursor:
                query = f"""
                    UPDATE minerva_tasks
                    SET {", ".join(sets)}
                    WHERE id = %s;
                """
                cursor.execute(query, tuple(params))
                updated = cursor.rowcount
        return updated == 1
    except Exception as exc:
        emit_error(f"Error editando tarea #{task_id}: {type(exc).__name__}")
        return False
    finally:
        conn.close()

