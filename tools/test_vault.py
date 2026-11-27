"""Check project IDs and the local Obsidian links used by NoahVault."""

from collections import Counter
import argparse
import json
from pathlib import Path
import re
import sys


ID = re.compile(r'''(?m)^id:[ \t]*["']?([A-Z]+-[A-Za-z0-9_-]+)["']?[ \t]*$''')
LINK = re.compile(r"\[\[([^\]#|]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]")
NOTE_TYPES = {".md", ".base", ".canvas", ".png", ".jpg", ".jpeg", ".webp"}


def check(vault: Path) -> tuple[int, list[str]]:
    files = [
        path for path in vault.rglob("*")
        if path.suffix.lower() in NOTE_TYPES and path.is_file()
    ]
    known = {
        target.casefold()
        for path in files
        for target in ([path.name, path.stem] if path.suffix == ".md" else [path.name])
    }
    ids: Counter[str] = Counter()
    issues = []
    for path in files:
        if path.suffix == ".md":
            text = path.read_text(encoding="utf-8-sig")
            if text.startswith("---\n"):
                header = text.split("\n---", 1)[0]
                found = ID.search(header)
                if found:
                    ids[found[1]] += 1
            for target in LINK.findall(text):
                name = target.rsplit("/", 1)[-1].casefold()
                if name not in known:
                    issues.append(f"{path.name}: missing {target}")
        elif path.suffix == ".canvas":
            canvas = json.loads(path.read_text(encoding="utf-8-sig"))
            nodes = {node["id"] for node in canvas["nodes"]}
            for node in canvas["nodes"]:
                if node["type"] == "file" and not (vault / node["file"]).is_file():
                    issues.append(f"{path.name}: missing {node['file']}")
            for edge in canvas["edges"]:
                if edge["fromNode"] not in nodes or edge["toNode"] not in nodes:
                    issues.append(f"{path.name}: dangling edge {edge['id']}")
    issues.extend(f"Duplicate ID: {record_id}" for record_id, count in ids.items() if count > 1)
    return len(ids), issues


def main() -> int:
    fallback = Path(__file__).resolve().parents[2] / "NoahVault"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", type=Path, default=fallback)
    vault = parser.parse_args().vault
    if not (vault / "00 Command Center" / "Command Center.md").is_file():
        parser.error(f"NoahVault was not found at {vault}")
    unique_ids, issues = check(vault)
    if issues:
        print("\n".join(issues), file=sys.stderr)
        return 1
    print(f"Verified {unique_ids} unique IDs and internal note / canvas links.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
