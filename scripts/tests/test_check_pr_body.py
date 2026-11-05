#!/usr/bin/env python3
"""Tests for the pull-request body check."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_pr_body


class CheckPRBodyTests(unittest.TestCase):
    def assert_fails(self, body: str) -> None:
        self.assertTrue(check_pr_body.closing_sentences(body), body)

    def assert_passes(self, body: str) -> None:
        self.assertEqual(check_pr_body.closing_sentences(body), [], body)

    def test_empty_body_passes(self) -> None:
        self.assert_passes("")
        self.assert_passes("   \n")

    def test_part_of_and_positive_close_pass(self) -> None:
        self.assert_passes("Part of #76")
        self.assert_passes("Closes #12")
        self.assert_passes("Refs #76")

    def test_the_two_real_strings_fail(self) -> None:
        self.assert_fails("does not close #76")
        self.assert_fails("this does **not** close #80")

    def test_bold_forms_fail(self) -> None:
        self.assert_fails("does **not** close **#80**")
        self.assert_fails("not **close** #12")
        self.assert_fails("**not** **close** **#12**")

    def test_contractions_and_curly_apostrophes_fail(self) -> None:
        self.assert_fails("doesn't, by itself, close #80")
        self.assert_fails("doesn’t close #80")
        self.assert_fails("won't fix #12")
        self.assert_fails("won’t fix #12")
        self.assert_fails("isn't going to close #12")

    def test_words_between_negation_and_keyword_fail(self) -> None:
        self.assert_fails("does not fully close #76")
        self.assert_fails("never closes #76")
        self.assert_fails("cannot resolve #76")

    def test_issue_reference_forms_fail(self) -> None:
        self.assert_fails("does not close https://github.com/ranokay/tracklog/issues/76")
        self.assert_fails("does not close ranokay/tracklog#76")

    def test_sentence_boundaries(self) -> None:
        self.assert_passes("Closes #12. It does not touch charts.")
        self.assert_passes("fixes a bug that does not reproduce; closes #5")
        self.assert_passes("Closes #12 but not #13")
        self.assert_fails("Closes #12 and does not close #13")

    def test_hard_wrapped_negations_fail(self) -> None:
        self.assert_fails("this does not\nclose #76")
        self.assert_fails("does **not**\nclose #80")
        self.assert_fails("Does not touch charts\nCloses #5")

    def test_newlines_before_a_new_block_bound_a_sentence(self) -> None:
        self.assert_passes("- does not touch charts\n- Closes #5")
        self.assert_passes("Does not touch charts.\nCloses #5")
        self.assert_passes("> does not touch charts\n> Closes #5")
        self.assert_passes("| does not touch charts\n| Closes #5")

    def test_a_heading_is_not_an_issue_reference(self) -> None:
        self.assert_passes("# Summary\nPart of #76")

    def test_multi_level_headings_bound_a_sentence(self) -> None:
        self.assert_passes("Does not touch charts\n## Issues\nCloses #5")
        self.assert_passes("Does not touch charts\n### Details\nCloses #5")

    def test_cli_fails_with_the_offending_sentence(self) -> None:
        import subprocess

        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parents[1] / "check_pr_body.py")],
            env={"PR_BODY": "does not close #76"},
            capture_output=True,
            check=False,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not close #76", result.stderr)
        self.assertIn("Refs #N", result.stderr)
        self.assertIn("Part of #N", result.stderr)


if __name__ == "__main__":
    unittest.main()
