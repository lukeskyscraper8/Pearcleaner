#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS_ROOT="$ROOT/script/fixtures/secret_detector_corpus"
MANIFEST="$CORPUS_ROOT/manifest.json"
DERIVED_DATA="${SECRET_DETECTOR_CORPUS_DERIVED_DATA:-$ROOT/.build/SecretDetectorCorpusDerivedData}"
SOURCE_PACKAGES="${SECRET_DETECTOR_CORPUS_SOURCE_PACKAGES:-$ROOT/.build/SourcePackages}"

fail() {
    echo "secret detector corpus gate failed: $1" >&2
    exit 1
}

[[ -f "$MANIFEST" ]] || fail "corpus manifest is missing: $MANIFEST"

/usr/bin/python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
root = manifest_path.parent

positives = manifest.get("positives")
negatives = manifest.get("negatives")
entropy_only = manifest.get("entropy_only")

if not isinstance(positives, list) or not isinstance(negatives, list) or not isinstance(entropy_only, list):
    raise SystemExit("corpus manifest must include positives, negatives, and entropy_only arrays")

if len(positives) < 200:
    raise SystemExit(f"corpus positives below §21.3 threshold: {len(positives)} < 200")
if len(negatives) < 1000:
    raise SystemExit(f"corpus negatives below §21.3 threshold: {len(negatives)} < 1000")

def require_fixture(relative_path: str) -> None:
    path = root / relative_path
    if not path.is_file():
        raise SystemExit(f"corpus fixture is missing: {relative_path}")

for entry in positives:
  if not isinstance(entry, dict) or not entry.get("file") or not entry.get("rule_id"):
      raise SystemExit("positive corpus entry must include file and rule_id")
  require_fixture(entry["file"])

for entry in negatives:
  if not isinstance(entry, dict) or not entry.get("file"):
      raise SystemExit("negative corpus entry must include file")
  require_fixture(entry["file"])

for entry in entropy_only:
  if not isinstance(entry, dict) or not entry.get("file"):
      raise SystemExit("entropy_only corpus entry must include file")
  require_fixture(entry["file"])

print(
    f"secret detector corpus manifest ok: "
    f"{len(positives)} positives, {len(negatives)} negatives, {len(entropy_only)} entropy-only"
)
PY

echo "Running SecretDetectorCorpusTests..."
xcodebuild -quiet \
    -project "$ROOT/Pearcleaner.xcodeproj" \
    -scheme ProjectScannerCore \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -disableAutomaticPackageResolution \
    -only-testing:ProjectScannerCoreTests/SecretDetectorCorpusTests \
    CODE_SIGNING_ALLOWED=NO \
    test

echo "secret detector corpus gates passed"
