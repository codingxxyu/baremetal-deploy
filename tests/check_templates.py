from pathlib import Path
import re
import yaml

root = Path(__file__).parents[1]
for path in (root / "manifests" / "templates").glob("*.yaml"):
    text = path.read_text()
    assert "build-harbor.alauda.cn" not in text, path
    assert "cpaas-system" in text, path
    # Templates intentionally contain multiline placeholders; validate required resource shape
    # here, while rendered YAML is parsed in the deployment environment after substitution.
    assert re.search(r"^apiVersion:\s*[^\n]+", text, re.M), path
    assert re.search(r"^kind:\s*[^\n]+", text, re.M), path
    assert re.search(r"^\s*namespace:\s*cpaas-system\s*$", text, re.M), path

config = (root / "config" / "environments" / "customer.template.yaml").read_text()
assert "architecture: amd64" in config
assert "mode: platform-bootstrap" in config
assert "bootstrap_address:" in config
assert "cos_state_size_mib: 20480" in config
assert "install_device_acknowledged: false" in config
for path in (root / "manifests" / "global").glob("*-registration.yaml"):
    text = path.read_text()
    assert "SeedImage" in text, path
    assert "partitions.yaml" in text, path
    assert "System Information/UUID" in text, path
for path in (root / "manifests" / "workload").glob("*-registration.yaml"):
    text = path.read_text()
    assert "SeedImage" in text, path
    assert "partitions.yaml" in text, path
    assert "System Information/UUID" in text, path
print("template checks passed")
