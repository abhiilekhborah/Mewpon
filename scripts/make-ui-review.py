#!/usr/bin/env python3
"""Package an isolated native visual-review copy; never stops the user's app."""
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parent.parent
root = pathlib.Path(tempfile.mkdtemp(prefix="mewpon-ui-review-", dir="/private/tmp"))
app = root / "Mewpon Review.app"
shutil.copytree(project / "build/Mewpon.app", app)
info = app / "Contents/Info.plist"
data = plistlib.loads(info.read_bytes())
data.update(CFBundleIdentifier="local.mewpon.uireview", CFBundleName="Mewpon Review", CFBundleDisplayName="Mewpon Review", MewponReviewOutput=str(project / "Verification/UIRevamp"))
data.pop("NSServices", None)
info.write_bytes(plistlib.dumps(data))
resources = app / "Contents/Resources"
shutil.rmtree(resources / "Metadata.appintents", ignore_errors=True)
shutil.copyfile(project / "Verification/Phase4/mewpon-phase4-fixture.pdf", resources / "review-fixture.pdf")
output = project / "Verification/UIRevamp"
output.mkdir(parents=True, exist_ok=True)
identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True, check=True).stdout
matches = [re.search(r"[A-F0-9]{40}", line).group() for line in identities.splitlines() if "Apple Development" in line and re.search(r"[A-F0-9]{40}", line)]
identity = matches[0] if len(matches) == 1 else "-"
subprocess.run(["codesign", "--force", "--deep", "--sign", identity, str(app)], capture_output=True, check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
(output / "review-app-path.txt").write_text(str(app) + "\n")
print(app)
