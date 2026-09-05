"""Dependency-free CI checks. Reports paths, never credential contents."""
import pathlib
import plistlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
errors = []
manifest = ROOT / "QuickCue/Resources/PrivacyInfo.xcprivacy"
try:
    privacy = plistlib.loads(manifest.read_bytes())
    reasons = {
        item["NSPrivacyAccessedAPIType"]: item["NSPrivacyAccessedAPITypeReasons"]
        for item in privacy["NSPrivacyAccessedAPITypes"]
    }
    if "CA92.1" not in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", []):
        errors.append("PrivacyInfo.xcprivacy: UserDefaults CA92.1 declaration is missing")
    if privacy.get("NSPrivacyTracking") is not False:
        errors.append("PrivacyInfo.xcprivacy: tracking must remain disabled")
except (OSError, ValueError, KeyError, TypeError):
    errors.append("PrivacyInfo.xcprivacy: invalid or missing manifest")

project = (ROOT / "project.yml").read_text(encoding="utf-8")
if not re.search(r"CURRENT_PROJECT_VERSION:\s*6\s", project):
    errors.append("project.yml: expected build 6")
if not re.search(r"MARKETING_VERSION:\s*0\.3\.1\s", project):
    errors.append("project.yml: expected version 0.3.1")
if not re.search(r'CFBundleShortVersionString:\s*["\']?\$\(MARKETING_VERSION\)["\']?\s', project):
    errors.append("project.yml: packaged version must reference MARKETING_VERSION")
if not re.search(r'CFBundleVersion:\s*["\']?\$\(CURRENT_PROJECT_VERSION\)["\']?\s', project):
    errors.append("project.yml: packaged build must reference CURRENT_PROJECT_VERSION")

# Include untracked candidates during local validation so a newly added secret
# cannot pass merely because it has not been staged yet. Ignored build/tool
# folders remain outside the scan; tracked files are checked even if ignored.
tracked = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT
).decode("utf-8").split("\0")
patterns = [
    re.compile(rb"\bsk-(?:proj-|ant-api03-)?[A-Za-z0-9_-]{24,}"),
    re.compile(rb"\b(?:ghp|github_pat)_[A-Za-z0-9_]{30,}"),
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
]
for relative in filter(None, tracked):
    path = ROOT / relative
    if (path.name.startswith(".env") and path.name != ".env.example") or path.suffix in {".p12", ".mobileprovision", ".pem", ".key"}:
        errors.append(f"Credential/signing file is tracked: {relative}")
        continue
    if path.suffix not in {".swift", ".md", ".json", ".yml", ".yaml", ".xcconfig", ".txt", ".env"}:
        continue
    if path.is_file() and any(pattern.search(path.read_bytes()) for pattern in patterns):
        errors.append(f"Possible credential requires review: {relative}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
print("Repository safety, privacy manifest and release version checks passed.")
