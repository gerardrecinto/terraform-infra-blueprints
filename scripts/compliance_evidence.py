#!/usr/bin/env python3
"""Collect change-management and security evidence for GitHub repositories.

Reads settings with the GitHub CLI (`gh`, already signed in) and prints a table per
repository, each check tied to the control areas in docs/compliance-controls-map.md.
Read-only: it never changes a repository. The mapping is my reading of what an auditor
asks for, not an auditor's, and a "met" row is a setting that is on, not proof the
control works.

    python3 scripts/compliance_evidence.py owner/repo [owner/repo ...] [--json] [--strict]

--strict exits 1 if any check is "not met". Needs Python 3.9+ and gh. No other packages.
"""
import argparse
import datetime
import json
import subprocess
import sys

MET, NOT_MET, UNKNOWN = "met", "not met", "unknown"

# check id -> (what is checked, control areas it supports)
CHECKS = {
    "branch-protection": ("Default branch is protected", "SOC 2 CC8.1, SOX ITGC change management, PCI DSS 6.5"),
    "required-checks": ("Merging needs passing status checks", "SOC 2 CC8.1, PCI DSS 6.5"),
    "required-reviews": ("Merging needs at least one approving review", "SOC 2 CC8.1, SOX ITGC segregation of duties"),
    "code-owners": ("CODEOWNERS file exists and reviews are required from owners", "SOC 2 CC8.1, SOX ITGC"),
    "no-force-push": ("Force pushes and branch deletion are blocked", "SOC 2 CC8.1, SOX ITGC"),
    "admins-included": ("Rules apply to admins too", "SOX ITGC segregation of duties"),
    "signed-commits": ("Commits must be signed", "SOC 2 CC8.1 (optional strengthening)"),
    "secret-scanning": ("Secret scanning and push protection are on", "SOC 2 CC6.1, PCI DSS 6.2"),
    "dependency-alerts": ("Dependency vulnerability alerts are on", "SOC 2 CC7.1, PCI DSS 6.3"),
    "code-scanning": ("A code scanning workflow (CodeQL) exists", "SOC 2 CC7.1, PCI DSS 6.2"),
    "security-policy": ("SECURITY.md tells people how to report a flaw", "SOC 2 CC7.1, PCI DSS 6.3"),
    "ci-green": ("Latest CI run on the default branch passed", "SOC 2 CC8.1 (evidence of tested changes)"),
}


def gh(path, runner=subprocess.run):
    """GET a GitHub API path. Returns (status, json or None). status is 'ok', 'missing' or 'error'."""
    p = runner(["gh", "api", path], capture_output=True, text=True, timeout=30)
    if p.returncode == 0:
        try:
            return "ok", json.loads(p.stdout) if p.stdout.strip() else {}
        except json.JSONDecodeError:
            return "error", None
    err = (p.stderr or "") + (p.stdout or "")
    return ("missing" if "404" in err or "Not Found" in err else "error"), None


def collect(repo, runner=subprocess.run):
    """Gather raw facts. Any call that fails for a reason other than 'not found' becomes None (unknown)."""
    facts = {"repo": repo}
    st, info = gh(f"repos/{repo}", runner)
    facts["info"] = info if st == "ok" else None
    branch = (info or {}).get("default_branch", "main")
    facts["branch"] = branch
    st, prot = gh(f"repos/{repo}/branches/{branch}/protection", runner)
    facts["protection"] = {"ok": prot, "missing": False, "error": None}[st] if st != "missing" else False
    for key, path in (("codeowners", ".github/CODEOWNERS"), ("security_md", "SECURITY.md")):
        s, _ = gh(f"repos/{repo}/contents/{path}", runner)
        facts[key] = True if s == "ok" else (False if s == "missing" else None)
    s, _ = gh(f"repos/{repo}/vulnerability-alerts", runner)
    facts["dependency_alerts"] = True if s == "ok" else (False if s == "missing" else None)
    s, wf = gh(f"repos/{repo}/actions/workflows", runner)
    facts["workflows"] = [w.get("path", "") for w in (wf or {}).get("workflows", [])] if s == "ok" else None
    s, runs = gh(f"repos/{repo}/actions/runs?branch={branch}&per_page=1&status=completed", runner)
    run = ((runs or {}).get("workflow_runs") or [None])[0] if s == "ok" else None
    facts["last_run"] = run.get("conclusion") if run else (None if s != "ok" else "none")
    return facts


def _row(status, note):
    return {"status": status, "note": note}


def evaluate(facts):
    """Turn facts into one result per check. Pure function, no network."""
    prot, out = facts["protection"], {}
    if prot is None:
        for k in ("branch-protection", "required-checks", "required-reviews", "code-owners",
                  "no-force-push", "admins-included", "signed-commits"):
            out[k] = _row(UNKNOWN, "could not read branch protection (permission or API error)")
    elif prot is False:
        out["branch-protection"] = _row(NOT_MET, f"no protection rule on {facts['branch']}")
        for k in ("required-checks", "required-reviews", "no-force-push", "admins-included", "signed-commits"):
            out[k] = _row(NOT_MET, "no protection rule")
        out["code-owners"] = _row(NOT_MET if facts["codeowners"] is False else UNKNOWN,
                                  "no protection rule, so owner review cannot be required")
    else:
        out["branch-protection"] = _row(MET, f"rule on {facts['branch']}")
        ctx = (prot.get("required_status_checks") or {}).get("contexts") or []
        out["required-checks"] = _row(MET if ctx else NOT_MET, ", ".join(ctx) if ctx else "no required checks")
        rev = prot.get("required_pull_request_reviews") or {}
        n = rev.get("required_approving_review_count", 0) if rev else 0
        out["required-reviews"] = _row(MET if n >= 1 else NOT_MET,
                                       f"{n} approving review(s) required" if rev else "pull request reviews not required")
        owners = bool(facts["codeowners"]) and bool(rev.get("require_code_owner_reviews"))
        out["code-owners"] = _row(MET if owners else NOT_MET,
                                  "CODEOWNERS present: %s; owner review required: %s" % (facts["codeowners"], bool(rev.get("require_code_owner_reviews"))))
        fp = (prot.get("allow_force_pushes") or {}).get("enabled")
        dl = (prot.get("allow_deletions") or {}).get("enabled")
        out["no-force-push"] = _row(MET if fp is False and dl is False else NOT_MET, f"force pushes allowed: {fp}, deletions allowed: {dl}")
        ea = (prot.get("enforce_admins") or {}).get("enabled")
        out["admins-included"] = _row(MET if ea else NOT_MET, f"enforce admins: {ea}")
        sig = (prot.get("required_signatures") or {}).get("enabled")
        out["signed-commits"] = _row(MET if sig else NOT_MET, f"required signatures: {sig}")
    sa = ((facts["info"] or {}).get("security_and_analysis")) or {}
    if facts["info"] is None:
        out["secret-scanning"] = _row(UNKNOWN, "could not read repository settings")
    else:
        ss = (sa.get("secret_scanning") or {}).get("status")
        pp = (sa.get("secret_scanning_push_protection") or {}).get("status")
        out["secret-scanning"] = _row(MET if ss == "enabled" and pp == "enabled" else NOT_MET,
                                      f"secret scanning: {ss}, push protection: {pp}")
    d = facts["dependency_alerts"]
    out["dependency-alerts"] = _row(UNKNOWN if d is None else (MET if d else NOT_MET), f"alerts enabled: {d}")
    wf = facts["workflows"]
    if wf is None:
        out["code-scanning"] = _row(UNKNOWN, "could not list workflows")
    else:
        has = any("codeql" in w.lower() for w in wf)
        out["code-scanning"] = _row(MET if has else NOT_MET, "CodeQL workflow found" if has else "no CodeQL workflow")
    sm = facts["security_md"]
    out["security-policy"] = _row(UNKNOWN if sm is None else (MET if sm else NOT_MET), f"SECURITY.md present: {sm}")
    lr = facts["last_run"]
    out["ci-green"] = _row(UNKNOWN if lr in (None, "none") else (MET if lr == "success" else NOT_MET), f"latest run on {facts['branch']}: {lr}")
    return out


def render(repo, results):
    lines = [f"### {repo}", "", "| Check | Status | Detail | Supports |", "|---|---|---|---|"]
    for key, (label, controls) in CHECKS.items():
        r = results[key]
        lines.append(f"| {label} | {r['status']} | {r['note']} | {controls} |")
    c = {s: sum(1 for r in results.values() if r["status"] == s) for s in (MET, NOT_MET, UNKNOWN)}
    lines += ["", f"{c[MET]} met, {c[NOT_MET]} not met, {c[UNKNOWN]} unknown.", ""]
    return "\n".join(lines)


def main(argv=None, runner=subprocess.run):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("repos", nargs="+", help="owner/repo")
    ap.add_argument("--json", action="store_true", help="print JSON instead of tables")
    ap.add_argument("--strict", action="store_true", help="exit 1 if any check is not met")
    a = ap.parse_args(argv)
    report, failed = {}, False
    for repo in a.repos:
        res = evaluate(collect(repo, runner))
        report[repo] = res
        failed = failed or any(r["status"] == NOT_MET for r in res.values())
    if a.json:
        print(json.dumps({"generated": datetime.date.today().isoformat(), "repos": report}, indent=2))
    else:
        print(f"# Evidence collected {datetime.date.today().isoformat()}\n")
        print("\n".join(render(r, res) for r, res in report.items()))
    return 1 if (a.strict and failed) else 0


if __name__ == "__main__":
    sys.exit(main())
