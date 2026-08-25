#!/usr/bin/env python3
"""Generate secret detector holdout corpus fixtures for §21.3 quality gates."""

from __future__ import annotations

import json
import random
import string
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "fixtures" / "secret_detector_corpus"
POSITIVE_DIR = ROOT / "positive"
NEGATIVE_DIR = ROOT / "negative"
ENTROPY_DIR = ROOT / "entropy"


def aws_access_key_id() -> str:
    body = "".join(random.choice(string.ascii_uppercase + string.digits) for _ in range(16))
    return "AKIA" + body


def aws_session_access_key_id() -> str:
    body = "".join(random.choice(string.ascii_uppercase + string.digits) for _ in range(16))
    return "ASIA" + body


def github_pat(prefix: str) -> str:
    body = "".join(random.choice(string.ascii_letters + string.digits + "_") for _ in range(36))
    return prefix + body


def github_fine_grained() -> str:
    body = "".join(random.choice(string.ascii_letters + string.digits + "_") for _ in range(82))
    return "github_pat_" + body


def slack_token(kind: str) -> str:
    first = str(random.randint(10**10, 10**13 - 1))
    second = str(random.randint(10**10, 10**13 - 1))
    body = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(24))
    return f"{kind}-{first}-{second}-{body}"


def stripe_key(prefix: str) -> str:
    body = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(24))
    return prefix + body


POSITIVE_GENERATORS: list[tuple[str, callable]] = [
    ("secret.aws.access_key_id", aws_access_key_id),
    ("secret.aws.session_access_key_id", aws_session_access_key_id),
    ("secret.github.pat", lambda: github_pat("ghp_")),
    ("secret.github.oauth", lambda: github_pat("gho_")),
    ("secret.github.user_to_server", lambda: github_pat("ghu_")),
    ("secret.github.server_to_server", lambda: github_pat("ghs_")),
    ("secret.github.refresh", lambda: github_pat("ghr_")),
    ("secret.github.fine_grained_pat", github_fine_grained),
    ("secret.slack.bot_token", lambda: slack_token("xoxb")),
    ("secret.slack.app_token", lambda: slack_token("xapp")),
    ("secret.slack.user_token", lambda: slack_token("xoxp")),
    ("secret.stripe.secret_key", lambda: stripe_key("sk_live_")),
    ("secret.stripe.test_secret_key", lambda: stripe_key("sk_test_")),
    ("secret.stripe.restricted_key", lambda: stripe_key("rk_live_")),
    ("secret.stripe.test_restricted_key", lambda: stripe_key("rk_test_")),
]

NEGATIVE_TEMPLATES: list[str] = [
    "export const apiKey = \"placeholder-not-a-secret\";",
    "README: configure your API key in the dashboard settings panel.",
    "# Example: AKIA followed by only fifteen characters AKIA123456789012",
    "const token = \"ghp_short\"; // too short to be a PAT",
    "password = \"xoxb-not-enough-segments\"",
    "stripe dashboard shows sk_live prefix in documentation screenshots only",
    "let hash = \"{random}\";",
    "npm install --save-dev eslint@8.57.0",
    "function authenticate(user) { return user.isAdmin; }",
    "minified: !function(e){e.AKIAfake}(window);",
    "json: {\"client_id\":\"my-app\",\"redirect\":\"https://example.com\"}",
    "base64-looking but not a provider token: YWJjZGVmZ2hpams=",
    "uuid = \"550e8400-e29b-41d4-a716-446655440000\";",
    "commit message: fix ghp_ regression in tests without real token",
    "const x = \"sk_live_tooshort\";",
    "slack docs mention xoxb- format without valid segments",
    "ASIA123456789012345",  # wrong length
    "AKIA lowercase tail akia0123456789ABCDEF",
]

ENTROPY_TEMPLATES: list[str] = [
    lambda: "".join(random.choice(string.ascii_letters + string.digits) for _ in range(64)),
    lambda: "".join(random.choice(string.ascii_letters + string.digits + "+/=") for _ in range(80)),
    lambda: "".join(chr(random.randint(33, 126)) for _ in range(96)),
]


def wrap_positive(token: str, category: str, index: int) -> str:
    wrappers = [
        f"const credential = \"{token}\";",
        f"export API_TOKEN={token}",
        f"# deploy secret\n{token}",
        f"\"auth\": \"{token}\"",
        f"password={token}\n",
        f"// generated fixture {index}\n{token}\n// end",
    ]
    if category == "minified":
        return f"!function(){{var s=\"{token}\";return s}}();"
    if category == "docs":
        return f"Documentation example (synthetic): {token}"
    return random.choice(wrappers)


def wrap_negative(template: str, index: int) -> str:
    if "{random}" in template:
        random_value = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(48))
        return template.replace("{random}", random_value)
    return template + f" // negative-{index}"


def main() -> None:
    random.seed(0x50454152)  # deterministic corpus

    for directory in (POSITIVE_DIR, NEGATIVE_DIR, ENTROPY_DIR):
        directory.mkdir(parents=True, exist_ok=True)
        for existing in directory.glob("*.txt"):
            existing.unlink()

    manifest: dict[str, list[dict[str, str]]] = {
        "positives": [],
        "negatives": [],
        "entropy_only": [],
    }

    categories = ["code", "fixture", "docs", "generated", "minified"]
    positive_count = 0
    target_positives = 200
    generator_index = 0

    while positive_count < target_positives:
        rule_id, generator = POSITIVE_GENERATORS[generator_index % len(POSITIVE_GENERATORS)]
        category = categories[positive_count % len(categories)]
        token = generator()
        content = wrap_positive(token, category, positive_count)
        filename = f"p{positive_count:04d}.txt"
        path = POSITIVE_DIR / filename
        path.write_text(content, encoding="utf-8")
        manifest["positives"].append(
            {
                "file": f"positive/{filename}",
                "rule_id": rule_id,
                "category": category,
            }
        )
        positive_count += 1
        generator_index += 1

    for index in range(1000):
        template = NEGATIVE_TEMPLATES[index % len(NEGATIVE_TEMPLATES)]
        content = wrap_negative(template, index)
        filename = f"n{index:04d}.txt"
        path = NEGATIVE_DIR / filename
        path.write_text(content, encoding="utf-8")
        manifest["negatives"].append({"file": f"negative/{filename}"})

    for index in range(50):
        generator = ENTROPY_TEMPLATES[index % len(ENTROPY_TEMPLATES)]
        content = generator()
        filename = f"e{index:04d}.txt"
        path = ENTROPY_DIR / filename
        path.write_text(content, encoding="utf-8")
        manifest["entropy_only"].append({"file": f"entropy/{filename}"})

    manifest_path = ROOT / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(
        f"Generated {len(manifest['positives'])} positives, "
        f"{len(manifest['negatives'])} negatives, "
        f"{len(manifest['entropy_only'])} entropy-only samples at {ROOT}"
    )


if __name__ == "__main__":
    main()
