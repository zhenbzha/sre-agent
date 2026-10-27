import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "scm-auto-repair-guard.py"
SPEC = importlib.util.spec_from_file_location("scm_guard", SCRIPT)
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class ScmRepairGuardTests(unittest.TestCase):
    def context(self, command=None, tool="RunAzCliWriteCommands", mode="Autonomous"):
        return {
            "hook_event_name": "PreToolUse",
            "agent_mode": mode,
            "tool_name": tool,
            "tool_input": {"command": command or GUARD.REPAIR_COMMAND},
        }

    def assert_denied(self, context):
        result = GUARD.evaluate(context)
        self.assertFalse(result["ok"])
        self.assertEqual("deny", result["hookSpecificOutput"]["permissionDecision"])
        self.assertTrue(result["reason"].strip())

    def test_exact_autonomous_repair_has_explicit_allow(self):
        result = GUARD.evaluate(self.context())
        self.assertTrue(result["ok"])
        self.assertEqual("allow", result["hookSpecificOutput"]["permissionDecision"])

    def test_other_modes_cannot_override_policy(self):
        for mode in ("Review", "ReadOnly", "", None):
            with self.subTest(mode=mode):
                self.assert_denied(self.context(mode=mode))

    def test_target_value_and_other_properties_cannot_change(self):
        for before, after in (
            ("--access Allow", "--access Deny"),
            ("rg-flu-xzlxm7twvdxao", "another-resource-group"),
            ("PostgreSqlFaultInjection", "AnotherRule"),
            ("db4948d5", "ab4948d5"),
            ("--access Allow", "--access Allow --priority 99"),
            ("--output json", "--output yaml"),
        ):
            with self.subTest(after=after):
                self.assert_denied(self.context(GUARD.REPAIR_COMMAND.replace(before, after)))

    def test_extra_commands_flags_and_expansion_are_denied(self):
        for suffix in (
            "; az account show", " && az account show", "\naz account show",
            " --set priority=99", " > result.json", " # comment", " $(echo test)",
        ):
            with self.subTest(suffix=suffix):
                self.assert_denied(self.context(GUARD.REPAIR_COMMAND + suffix))

    def test_no_write_through_read_or_terminal_tool(self):
        for tool in ("RunAzCliReadCommands", "RunInTerminal", "Terminal", "ExecutePythonCode"):
            with self.subTest(tool=tool):
                self.assert_denied(self.context(tool=tool))

    def test_unknown_tools_and_mutations_are_denied(self):
        for tool in ("CreateGithubIssue", "SendOutlookEmail", "Task", "Agent", "CreateFile", "Unknown"):
            with self.subTest(tool=tool):
                self.assert_denied(self.context(tool=tool))

    def test_read_tools_do_not_override_normal_permission_evaluation(self):
        for tool in GUARD.READ_TOOLS:
            with self.subTest(tool=tool):
                self.assertEqual({"ok": True}, GUARD.evaluate(self.context(tool=tool)))

    def test_read_cli_handles_quoted_kql(self):
        command = (
            'az monitor log-analytics query -w workspace --analytics-query '
            '"AppRequests | where toint(ResultCode)>=500 | summarize count()"'
        )
        self.assertEqual(
            {"ok": True}, GUARD.evaluate(self.context(command, tool="RunAzCliReadCommands"))
        )

    def test_read_cli_cannot_chain_or_substitute_commands(self):
        for command in (
            "az network nsg rule show; az network nsg rule update --access Deny",
            "az resource list $(az account get-access-token)",
            "az resource list `az account get-access-token`",
            "az resource list > out.json",
            "az rest --method put --url https://management.azure.com",
            "az account get-access-token",
            "az postgres flexible-server start",
            "az webapp show",
        ):
            with self.subTest(command=command):
                self.assert_denied(self.context(command, tool="RunAzCliReadCommands"))

    def test_scoped_alert_get_is_read_only_without_policy_override(self):
        command = (
            "az rest --method get --url https://management.azure.com"
            "/subscriptions/db4948d5-b90c-47d4-91b5-d8c4c43493d2"
            "/resourceGroups/rg-flu-xzlxm7twvdxao/providers/Microsoft.OperationalInsights"
            "/workspaces/flu-xzlxm7twvdxao-logs/providers/Microsoft.AlertsManagement"
            "/alerts/edb9bc93-bf9b-f0fc-f08f-c6730e1b000f?api-version=2019-03-01"
            " --query properties.essentials.monitorCondition --output json"
        )
        self.assertEqual(
            {"ok": True}, GUARD.evaluate(self.context(command, tool="RunAzCliReadCommands"))
        )
        for changed in (
            command.replace("--method get", "--method patch"),
            command.replace("--method get", "--method post"),
            command.replace("--method get", ""),
            command.replace("management.azure.com", "example.invalid"),
            command.replace("rg-flu-xzlxm7twvdxao", "another-group"),
            command.replace("api-version=2019-03-01", "api-version=2019-03-01&extra=true"),
            command + " --body '{}'",
            command + " --headers X-HTTP-Method-Override=PUT",
            command + " --method put",
            command + " --uri https://example.invalid",
            command + " --resource https://example.invalid",
        ):
            with self.subTest(command=changed):
                self.assert_denied(self.context(changed, tool="RunAzCliReadCommands"))

    def test_malformed_context_and_argument_shapes_fail_closed(self):
        for context in (
            None, [], {}, {"hook_event_name": "PostToolUse"},
            {**self.context(), "tool_input": {"commands": [GUARD.REPAIR_COMMAND]}},
            {**self.context(), "tool_input": {"command": GUARD.REPAIR_COMMAND, "extra": True}},
        ):
            with self.subTest(context=context):
                self.assert_denied(context)

    def test_entrypoint_rejects_duplicate_authoritative_fields(self):
        raw = json.dumps(self.context())[:-1] + ', "tool_name": "ReadFile"}'
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], input=raw, text=True, capture_output=True, check=True
        )
        decision = json.loads(result.stdout)
        self.assertFalse(decision["ok"])
        self.assertEqual("deny", decision["hookSpecificOutput"]["permissionDecision"])

    def test_documented_command_matches_enforcement(self):
        instructions = SCRIPT.parents[1] / "knowledge" / "scm-auto-repair-instructions.md"
        self.assertIn(GUARD.REPAIR_COMMAND, instructions.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
