"""Render the web-service chart with helm and assert the properties that matter in production.

Run from the repository root:  python -m pytest helm/tests -v
Needs helm 3 on PATH (or HELM=/path/to/helm) and PyYAML.
"""

import os
import subprocess
from pathlib import Path

import pytest
import yaml

CHART = Path(__file__).resolve().parents[1] / "charts" / "web-service"
HELM = os.environ.get("HELM", "helm")
DIGEST = "sha256:" + "a" * 64


def render(*sets, values=None):
    cmd = [HELM, "template", "rel", str(CHART), "--kube-version", "1.31.0"]
    for s in sets:
        cmd += ["--set", s]
    if values:
        cmd += ["-f", str(values)]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    return [d for d in yaml.safe_load_all(out) if d]


def kinds(docs):
    return {d["kind"] for d in docs}


def one(docs, kind):
    found = [d for d in docs if d["kind"] == kind]
    assert len(found) == 1, f"expected one {kind}, found {len(found)}"
    return found[0]


def container(docs):
    return one(docs, "Deployment")["spec"]["template"]["spec"]["containers"][0]


def test_default_render_has_the_production_objects():
    docs = render()
    assert {"Deployment", "Service", "ServiceAccount", "HorizontalPodAutoscaler", "PodDisruptionBudget", "NetworkPolicy"} <= kinds(docs)
    assert "Ingress" not in kinds(docs)
    assert "ServiceMonitor" not in kinds(docs)


def test_rollout_never_removes_a_ready_pod_early():
    spec = one(render(), "Deployment")["spec"]
    assert spec["strategy"]["rollingUpdate"]["maxUnavailable"] == 0
    assert spec["progressDeadlineSeconds"] == 90


def test_replicas_are_left_to_the_hpa_when_autoscaling():
    assert "replicas" not in one(render(), "Deployment")["spec"]


def test_replicas_are_set_when_autoscaling_is_off():
    docs = render("autoscaling.enabled=false", "replicaCount=5")
    assert one(docs, "Deployment")["spec"]["replicas"] == 5
    assert "HorizontalPodAutoscaler" not in kinds(docs)


def test_hpa_targets_the_deployment():
    hpa = one(render(), "HorizontalPodAutoscaler")["spec"]
    assert (hpa["minReplicas"], hpa["maxReplicas"]) == (3, 20)
    assert hpa["metrics"][0]["resource"]["target"]["averageUtilization"] == 70
    assert hpa["scaleTargetRef"]["name"] == one(render(), "Deployment")["metadata"]["name"]


def test_container_is_locked_down():
    docs = render()
    pod = one(docs, "Deployment")["spec"]["template"]["spec"]
    ctr = container(docs)
    assert pod["securityContext"]["runAsNonRoot"] is True
    assert pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
    assert ctr["securityContext"]["allowPrivilegeEscalation"] is False
    assert ctr["securityContext"]["readOnlyRootFilesystem"] is True
    assert ctr["securityContext"]["capabilities"]["drop"] == ["ALL"]
    assert pod["automountServiceAccountToken"] is False


def test_probes_and_graceful_shutdown_are_configured():
    docs = render()
    pod = one(docs, "Deployment")["spec"]["template"]["spec"]
    ctr = container(docs)
    for probe in ("startupProbe", "livenessProbe", "readinessProbe"):
        assert ctr[probe]["httpGet"]["port"] == "http"
    assert ctr["lifecycle"]["preStop"]["sleep"]["seconds"] == 10
    assert pod["terminationGracePeriodSeconds"] == 45


def test_pods_spread_across_zones_and_nodes():
    pod = one(render(), "Deployment")["spec"]["template"]["spec"]
    keys = {c["topologyKey"] for c in pod["topologySpreadConstraints"]}
    assert keys == {"topology.kubernetes.io/zone", "kubernetes.io/hostname"}


def test_spread_can_be_disabled():
    pod = one(render("topologySpread.enabled=false"), "Deployment")["spec"]["template"]["spec"]
    assert "topologySpreadConstraints" not in pod


def test_pdb_defaults_to_max_unavailable_and_honors_min_available():
    assert one(render(), "PodDisruptionBudget")["spec"]["maxUnavailable"] == 1
    spec = one(render("podDisruptionBudget.minAvailable=2"), "PodDisruptionBudget")["spec"]
    assert spec["minAvailable"] == 2 and "maxUnavailable" not in spec


def test_irsa_annotation_only_when_a_role_is_given():
    assert "annotations" not in one(render(), "ServiceAccount")["metadata"]
    role = "arn:aws:iam::123456789012:role/web"
    sa = one(render(f"serviceAccount.roleArn={role}"), "ServiceAccount")
    assert sa["metadata"]["annotations"]["eks.amazonaws.com/role-arn"] == role


def test_digest_wins_over_tag():
    assert container(render(f"image.digest={DIGEST}", "image.tag=1.2.3"))["image"].endswith("@" + DIGEST)
    assert container(render("image.tag=1.2.3"))["image"].endswith(":1.2.3")


def test_network_policy_restricts_ingress_to_named_namespaces():
    np = one(render("networkPolicy.ingressNamespaces={edge}"), "NetworkPolicy")["spec"]
    peer = np["ingress"][0]["from"][0]
    assert peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"] == "edge"
    assert np["ingress"][0]["ports"][0]["port"] == 8080


def test_ingress_renders_when_enabled():
    ing = one(render("ingress.enabled=true"), "Ingress")["spec"]
    assert ing["ingressClassName"] == "alb"
    assert ing["rules"][0]["host"] == "app.example.com"


@pytest.mark.parametrize(
    "bad",
    ["replicaCount=0", "image.digest=sha256:short", "service.port=70000", "autoscaling.targetCPUUtilizationPercentage=150"],
)
def test_schema_rejects_bad_values(bad):
    with pytest.raises(subprocess.CalledProcessError):
        render(bad)
