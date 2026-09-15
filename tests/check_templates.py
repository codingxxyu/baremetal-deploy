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
assert "registry.example.invalid" in config
print("template checks passed")
