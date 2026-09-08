import unittest
from unittest import mock

from backend.tools import tasks


class TaskValidationTests(unittest.TestCase):
    def test_add_rejects_ambiguous_due_date_before_database_access(self):
        with mock.patch.object(tasks, "add_task") as add_task:
            result = tasks.tool_manage_tasks(
                "add",
                description="Pay invoice",
                due_date="tomorrow",
            )

        self.assertIn("YYYY-MM-DD HH:MM:SS", result)
        add_task.assert_not_called()

    def test_add_passes_a_parsed_datetime_to_database(self):
        with mock.patch.object(tasks, "add_task", return_value=True) as add_task:
            result = tasks.tool_manage_tasks(
                "add",
                description="Pay invoice",
                due_date="2027-01-02 08:30:00",
            )

        self.assertIn("añadida", result)
        parsed_due_date = add_task.call_args.args[1]
        self.assertEqual(parsed_due_date.year, 2027)
    def test_delete_requires_confirmation_when_not_confirmed(self):
        fake_task = {
            "id": 42,
            "description": "Comprar despensa",
            "status": "pending",
            "due_date": None,
            "recurrence": None,
        }
        with mock.patch.object(tasks, "get_task_by_id", return_value=fake_task) as get_task, \
             mock.patch.object(tasks, "delete_task") as del_task:
            result = tasks.tool_manage_tasks("delete", task_id=42, confirm=False)

        self.assertIn("Confirmación requerida", result)
        self.assertIn("Comprar despensa", result)
        self.assertIn("confirm=True", result)
        get_task.assert_called_once_with(42)
        del_task.assert_not_called()

    def test_delete_rejects_nonexistent_task(self):
        with mock.patch.object(tasks, "get_task_by_id", return_value=None) as get_task, \
             mock.patch.object(tasks, "delete_task") as del_task:
            result = tasks.tool_manage_tasks("delete", task_id=999, confirm=False)

        self.assertIn("no existe ninguna tarea con ID #999", result)
        del_task.assert_not_called()

    def test_delete_executes_only_when_confirmed(self):
        fake_task = {
            "id": 42,
            "description": "Comprar despensa",
            "status": "pending",
            "due_date": None,
            "recurrence": None,
        }
        with mock.patch.object(tasks, "get_task_by_id", return_value=fake_task), \
             mock.patch.object(tasks, "delete_task", return_value=True) as del_task:
            result = tasks.tool_manage_tasks("delete", task_id=42, confirm=True)

        self.assertIn("eliminada permanentemente", result)
        del_task.assert_called_once_with(42)

    def test_clear_completed_calls_clear_completed_tasks(self):
        with mock.patch.object(tasks, "clear_completed_tasks", return_value=5) as clear_tasks:
            result = tasks.tool_manage_tasks("clear_completed")

        self.assertIn("Se eliminaron 5 tarea(s) completada(s)", result)
        self.assertIn("las tareas recurrentes se conservaron", result)
        clear_tasks.assert_called_once()

    def test_edit_validates_and_updates_task(self):
        fake_task = {
            "id": 10,
            "description": "Antigua",
            "status": "pending",
            "due_date": None,
            "recurrence": "monthly",
            "recurrence_day": 15,
            "recurrence_month": None,
        }
        with mock.patch.object(tasks, "get_task_by_id", return_value=fake_task), \
             mock.patch.object(tasks, "edit_task", return_value=True) as edit_fn:
            result = tasks.tool_manage_tasks(
                "edit",
                task_id=10,
                description="Nueva descripción",
                due_date="2027-05-10 12:00:00",
            )

        self.assertIn("actualizada correctamente", result)
        edit_fn.assert_called_once()
        call_kwargs = edit_fn.call_args.kwargs
        self.assertEqual(call_kwargs["task_id"], 10)
        self.assertEqual(call_kwargs["description"], "Nueva descripción")
        self.assertEqual(call_kwargs["due_date"].year, 2027)

    def test_edit_clear_recurrence(self):
        fake_task = {
            "id": 10,
            "description": "Tarea recurrente",
            "status": "pending",
            "due_date": None,
            "recurrence": "daily",
            "recurrence_day": None,
            "recurrence_month": None,
        }
        with mock.patch.object(tasks, "get_task_by_id", return_value=fake_task), \
             mock.patch.object(tasks, "edit_task", return_value=True) as edit_fn:
            result = tasks.tool_manage_tasks(
                "edit",
                task_id=10,
                recurrence="none",
            )

        self.assertIn("recurrencia eliminada", result)
        call_kwargs = edit_fn.call_args.kwargs
        self.assertTrue(call_kwargs["clear_recurrence"])


if __name__ == "__main__":
    unittest.main()
