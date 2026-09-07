import signal
import unittest

from backend.core.job_manager import (
    MAX_CAPTURED_OUTPUT,
    MAX_JOBS_PER_TURN,
    JobManager,
)


class JobManagerTests(unittest.TestCase):
    def setUp(self):
        self.manager = JobManager()

    def test_claim_is_atomic_and_checks_privilege_channel(self):
        job = self.manager.create("call-1", "echo ok", is_sudo=False)

        self.assertIsNone(
            self.manager.claim(job.job_id, expected_sudo=True)
        )
        claimed = self.manager.claim(job.job_id, expected_sudo=False)
        self.assertIsNotNone(claimed)
        self.assertEqual(claimed.status, "running")
        self.assertIsNone(
            self.manager.claim(job.job_id, expected_sudo=False)
        )

    def test_cancelled_job_cannot_be_revived_by_late_completion(self):
        job = self.manager.create("call-2", "sleep 1", is_sudo=False)
        self.manager.claim(job.job_id, expected_sudo=False)

        cancelled = self.manager.cancel(job.job_id)
        late_output = self.manager.append_output(job.job_id, "too late")
        completed = self.manager.set_result(job.job_id, "late", 0, True)

        self.assertEqual(cancelled.status, "cancelled")
        self.assertEqual(completed.status, "cancelled")
        self.assertEqual(completed.returncode, -signal.SIGTERM)
        self.assertEqual(late_output, "")
        self.assertNotIn("too late", completed.output)

    def test_completed_job_cannot_be_relabelled_as_cancelled(self):
        job = self.manager.create("call-done", "true", is_sudo=False)
        self.manager.claim(job.job_id, expected_sudo=False)
        completed = self.manager.set_result(job.job_id, "ok", 0, True)

        cancelled = self.manager.cancel(job.job_id)

        self.assertEqual(completed.status, "completed")
        self.assertIsNone(cancelled)
        self.assertEqual(self.manager.get(job.job_id).status, "completed")

    def test_output_is_bounded(self):
        job = self.manager.create("call-3", "yes", is_sudo=False)
        self.manager.append_output(job.job_id, "x" * (MAX_CAPTURED_OUTPUT * 2))

        snapshot = self.manager.get(job.job_id)

        self.assertTrue(snapshot.output_truncated)
        self.assertLess(
            len(snapshot.output),
            MAX_CAPTURED_OUTPUT + 100,
        )

    def test_open_turn_does_not_finish_before_it_is_sealed(self):
        self.manager.begin_turn()
        job = self.manager.create("call-4", "true", is_sudo=False)
        self.manager.add_turn_job(job.job_id)
        self.manager.claim(job.job_id, expected_sudo=False)
        self.manager.set_result(job.job_id, "ok", 0, True)

        self.assertFalse(self.manager.all_turn_finished())
        self.assertEqual(self.manager.consume_finished_turn_jobs(), [])

        self.manager.seal_turn()
        self.assertTrue(self.manager.all_turn_finished())
        first = self.manager.consume_finished_turn_jobs()
        second = self.manager.consume_finished_turn_jobs()
        self.assertEqual([item.job_id for item in first], [job.job_id])
        self.assertEqual(second, [])

    def test_concurrent_turns_are_isolated(self):
        self.manager.begin_turn("request-a")
        self.manager.begin_turn("request-b")
        first = self.manager.create("call-a", "true", is_sudo=False)
        second = self.manager.create("call-b", "false", is_sudo=False)
        self.manager.add_turn_job(first.job_id, "request-a")
        self.manager.add_turn_job(second.job_id, "request-b")
        self.manager.seal_turn("request-a")
        self.manager.seal_turn("request-b")

        self.manager.claim(first.job_id, expected_sudo=False)
        self.manager.set_result(first.job_id, "ok", 0, True)

        self.assertTrue(self.manager.all_turn_finished("request-a"))
        self.assertFalse(self.manager.all_turn_finished("request-b"))
        self.assertEqual(
            [job.job_id for job in self.manager.consume_finished_turn_jobs(
                "request-a"
            )],
            [first.job_id],
        )
        self.assertEqual(
            self.manager.consume_finished_turn_jobs("request-b"),
            [],
        )

    def test_turn_rejects_more_than_the_bounded_job_limit(self):
        self.manager.begin_turn("bounded-turn")
        accepted = []
        for index in range(MAX_JOBS_PER_TURN + 1):
            job = self.manager.create(f"call-{index}", "true", False)
            accepted.append(
                self.manager.add_turn_job(job.job_id, "bounded-turn")
            )

        self.assertTrue(all(accepted[:MAX_JOBS_PER_TURN]))
        self.assertFalse(accepted[-1])
        self.assertEqual(
            len(self.manager.get_turn_job_ids("bounded-turn")),
            MAX_JOBS_PER_TURN,
        )


if __name__ == "__main__":
    unittest.main()
