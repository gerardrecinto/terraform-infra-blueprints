import contextlib
import io
import json
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import compliance_evidence as ce  # noqa: E402

PROTECTED = {
    "required_status_checks": {"contexts": ["test"]},
    "required_pull_request_reviews": {"required_approving_review_count": 1, "require_code_owner_reviews": True},
    "allow_force_pushes": {"enabled": False},
    "allow_deletions": {"enabled": False},
    "enforce_admins": {"enabled": True},
    "required_signatures": {"enabled": True},
}


def facts(**over):
    base = {
        "repo": "o/r", "branch": "main", "protection": PROTECTED, "codeowners": True, "security_md": True,
        "dependency_alerts": True, "workflows": [".github/workflows/codeql.yml"], "last_run": "success",
        "info": {"security_and_analysis": {"secret_scanning": {"status": "enabled"},
                                           "secret_scanning_push_protection": {"status": "enabled"}}},
    }
    base.update(over)
    return base


class Evaluate(unittest.TestCase):
    def test_fully_protected_repo_meets_everything(self):
        res = ce.evaluate(facts())
        self.assertEqual({r["status"] for r in res.values()}, {ce.MET})
        self.assertEqual(set(res), set(ce.CHECKS))

    def test_no_protection_fails_the_change_controls(self):
        res = ce.evaluate(facts(protection=False))
        for key in ("branch-protection", "required-checks", "required-reviews", "no-force-push", "admins-included"):
            self.assertEqual(res[key]["status"], ce.NOT_MET, key)

    def test_unreadable_protection_is_unknown_not_failed(self):
        res = ce.evaluate(facts(protection=None))
        self.assertEqual(res["branch-protection"]["status"], ce.UNKNOWN)

    def test_reviews_not_required_is_not_met(self):
        p = dict(PROTECTED, required_pull_request_reviews=None)
        res = ce.evaluate(facts(protection=p))
        self.assertEqual(res["required-reviews"]["status"], ce.NOT_MET)
        self.assertEqual(res["code-owners"]["status"], ce.NOT_MET)

    def test_missing_codeql_and_failed_ci(self):
        res = ce.evaluate(facts(workflows=[".github/workflows/ci.yml"], last_run="failure"))
        self.assertEqual(res["code-scanning"]["status"], ce.NOT_MET)
        self.assertEqual(res["ci-green"]["status"], ce.NOT_MET)

    def test_unknown_when_a_call_failed(self):
        res = ce.evaluate(facts(dependency_alerts=None, workflows=None, last_run=None, info=None))
        for key in ("dependency-alerts", "code-scanning", "ci-green", "secret-scanning"):
            self.assertEqual(res[key]["status"], ce.UNKNOWN, key)


def fake_runner(table):
    def run(argv, **kw):
        path = argv[2]
        for prefix, (code, body) in table.items():
            if path.startswith(prefix):
                return subprocess.CompletedProcess(argv, code, stdout=json.dumps(body) if code == 0 else "", stderr="" if code == 0 else "gh: Not Found (HTTP 404)")
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="gh: Not Found (HTTP 404)")
    return run


class Collect(unittest.TestCase):
    def test_404_on_protection_means_no_rule(self):
        run = fake_runner({"repos/o/r/contents/": (0, {}), "repos/o/r/vulnerability-alerts": (0, {}),
                           "repos/o/r/actions/workflows": (0, {"workflows": []}),
                           "repos/o/r/actions/runs": (0, {"workflow_runs": []}),
                           "repos/o/r/branches": (1, None), "repos/o/r": (0, {"default_branch": "main"})})
        f = ce.collect("o/r", run)
        self.assertIs(f["protection"], False)
        self.assertEqual(f["last_run"], "none")

    def test_strict_exit_code_and_json(self):
        run = fake_runner({"repos/o/r": (0, {"default_branch": "main"})})
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(ce.main(["o/r", "--json"], run), 0)
            self.assertIn('"repos"', out.getvalue())
            self.assertEqual(ce.main(["o/r", "--strict"], run), 1)


if __name__ == "__main__":
    unittest.main()
