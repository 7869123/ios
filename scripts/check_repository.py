"""Source hygiene and optional Swift grammar check. This is NOT swift build/test."""
from pathlib import Path
import argparse
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--swift-grammar", action="store_true")
args = parser.parse_args()
errors = []
sources = sorted(ROOT.glob("Packages/**/*.swift")) + sorted(ROOT.glob("PoCs/**/*.swift")) + sorted(ROOT.glob("Apps/**/*.swift"))
sources = [p for p in sources if ".build" not in p.parts and ".swiftpm" not in p.parts]
for path in sources:
    text = path.read_text(encoding="utf-8")
    relative = path.relative_to(ROOT)
    if re.search(r"\b(?:print|debugPrint|dump|NSLog|os_log)\s*\(", text):
        errors.append(f"{relative}: unexpected source logging")
    if re.search(r"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{40,}", text):
        errors.append(f"{relative}: possible embedded credential")
    if "Sources" in path.parts and "TODO" in text:
        errors.append(f"{relative}: unfinished production placeholder")
for path in list(ROOT.glob("PoCs/**/*.plist")) + list(ROOT.glob("Apps/**/*.plist")):
    try:
        with path.open("rb") as stream:
            plistlib.load(stream)
    except Exception as error:
        errors.append(f"{path.relative_to(ROOT)}: invalid plist ({type(error).__name__})")
if args.swift_grammar:
    import tree_sitter
    import tree_sitter_swift
    language = tree_sitter.Language(tree_sitter_swift.language())
    swift_parser = tree_sitter.Parser(language)
    for path in sources:
        source = path.read_bytes()
        tree = swift_parser.parse(source)
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            if node.type == "ERROR" or node.is_missing:
                errors.append(f"{path.relative_to(ROOT)}:{node.start_point.row + 1}: Swift grammar {node.type}")
            stack.extend(reversed(node.children))
if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"PASS: {len(sources)} Swift files; source hygiene and plist validation" + ("; Swift grammar parsed" if args.swift_grammar else ""))
print("NOT RUN: Swift type checking, Swift unit tests, Apple SDK build, device validation")
