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
        self.assertEqual(parsed_due_date.minute, 30)


if __name__ == "__main__":
    unittest.main()
