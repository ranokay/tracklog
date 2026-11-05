#!/usr/bin/env python3
"""Reject a pull request body that would close an issue by negation.

GitHub reads a closing keyword before an issue reference even when a negation
precedes it. This check works per sentence after issue references are masked
and Markdown emphasis is removed, so bold markers cannot hide a match.
"""

from __future__ import annotations

import os
import re
import sys

ISSUE_URL = re.compile(
    r"https?://(?:www\.)?github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:issues|pull)/\d+",
    re.IGNORECASE,
)
OWNER_REPO_ISSUE = re.compile(r"\b[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#\d+")
ISSUE = re.compile(r"#\d+")

SENTENCE_SPLIT = re.compile(r"(?<!\d)[.!?;]+|[!?;]+|\.(?!\d)")
BLOCK_START = re.compile(r"^(?:[-*+]|\d+\.)\s|^#{1,6}(?:[ \t]|\Z)|^>|^\|")
EMPHASIS = re.compile(r"[*_~]+")
CLOSING = re.compile(
    r"(?i)\b(?:close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)"
    r"\s*(?::\s*)?\x00ISSUE\d+\x00"
)
NEGATION = re.compile(
    r"(?i)\b(?:not|never|without|cannot|nothing|neither|no\s+longer|"
    r"(?:does|do|did|is|was|were|wo|ca|could|should|would|are|have|has|had|must|need)n[’']?t)\b"
)


def mask_references(body: str) -> tuple[str, dict[str, str]]:
    """Replace issue references with punctuation-free placeholders."""
    mapping: dict[str, str] = {}

    def replace(match: re.Match[str]) -> str:
        """Mask one issue reference and keep it for restoration."""
        token = f"\x00ISSUE{len(mapping)}\x00"
        mapping[token] = match.group(0)
        return token

    for pattern in (ISSUE_URL, OWNER_REPO_ISSUE, ISSUE):
        body = pattern.sub(replace, body)
    return body, mapping


def restore(sentence: str, mapping: dict[str, str]) -> str:
    """Put the original issue references back for the failure message."""
    for token, reference in mapping.items():
        sentence = sentence.replace(token, reference)
    return sentence


def split_sentences(text: str) -> list[str]:
    """Split on punctuation, and on newlines only before a new block."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    parts: list[str] = []
    current: list[str] = []
    for index, line in enumerate(lines):
        current.append(line)
        if index == len(lines) - 1:
            break
        next_line = lines[index + 1].strip()
        if not next_line or BLOCK_START.match(next_line):
            parts.append("\n".join(current))
            current = []
    if current:
        parts.append("\n".join(current))
    sentences: list[str] = []
    for part in parts:
        sentences.extend(SENTENCE_SPLIT.split(part))
    return [sentence for sentence in sentences if sentence.strip()]


def closing_sentences(body: str) -> list[str]:
    """Return sentences where a negation precedes a closing keyword."""
    if not body or not body.strip():
        return []
    masked, mapping = mask_references(body)
    offending: list[str] = []
    for sentence in split_sentences(masked):
        detect = EMPHASIS.sub("", sentence)
        for closing in CLOSING.finditer(detect):
            if any(
                negation.end() <= closing.start()
                for negation in NEGATION.finditer(detect)
            ):
                offending.append(restore(sentence, mapping))
                break
    return offending


def main() -> int:
    """Read PR_BODY and return 1 when a negated closing statement is found."""
    body = os.environ.get("PR_BODY", "")
    offending = closing_sentences(body)
    if not offending:
        return 0
    for sentence in offending:
        print(
            "error: the PR body contains a negated closing statement: "
            f"{sentence.strip()}",
            file=sys.stderr,
        )
    print('Use "Refs #N" or "Part of #N" instead.', file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
