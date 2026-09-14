"""Run with the repository's matched Elixir/OTP pair on PATH."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "priv/skills/elixir-otp"
VERIFIER = SKILL / "references/verify_snippets.exs"

class SnippetVerifierTest(unittest.TestCase):
    def verify(self, content):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fixture.md"
            fixture.write_text(content)
            return subprocess.run(["elixir", str(VERIFIER), str(fixture)],
                                  capture_output=True, text=True, timeout=30)

    def test_empty_input_cannot_pass(self):
        result = self.verify("# No executable checks here\n")
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_runtime_failure_is_rejected(self):
        result = self.verify('```elixir-run\nraise "runtime failed"\n```\n')
        self.assertNotEqual(result.returncode, 0)

    def test_undefined_remote_call_is_rejected(self):
        result = self.verify('```elixir\nString.this_function_is_not_real("x")\n```\n')
        self.assertNotEqual(result.returncode, 0)

    def test_bad_example_must_really_fail(self):
        result = self.verify('```elixir-bad\n1 + 1\n```\n')
        self.assertNotEqual(result.returncode, 0)

    def test_runtime_assertion_and_negative_compile_control(self):
        result = self.verify('```elixir-run\n2 = 1 + 1\n```\n'
                             '```elixir-bad\ndefmodule Invalid do\n def f(x) when Map.get(x, :a), do: x\nend\n```\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_shipped_examples_execute(self):
        result = subprocess.run(["elixir", str(VERIFIER), str(SKILL / "SKILL.md"),
                                 str(SKILL / "references/syntax.md"),
                                 str(SKILL / "references/gotchas.md")],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("snippets verified", result.stdout)

if __name__ == "__main__":
    unittest.main()
