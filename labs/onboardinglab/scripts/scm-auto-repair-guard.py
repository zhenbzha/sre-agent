#!/usr/bin/env python3
"""Pre-execution guard for the dedicated SCM incident investigator."""

import json
import re
import shlex
import sys
from urllib.parse import parse_qs, urlsplit

REPAIR_COMMAND = (
    "az network nsg rule update "
    "--subscription db4948d5-b90c-47d4-91b5-d8c4c43493d2 "
    "--resource-group rg-flu-xzlxm7twvdxao "
    "--nsg-name flu-xzlxm7twvdxao-app-nsg "
    "--name PostgreSqlFaultInjection --access Allow --only-show-errors --output json"
)

READ_TOOLS = {
    "GetAzCliHelp",
    "QueryAppInsightsUsingAppId",
    "ReadFile",
    "ListDir",
    "FileSearch",
    "GrepSearch",
    "SearchMemory",
    "FetchGithubIssue",
    "FetchGithubIssues",
    "ListOutlookEmails",
    "PlotAreaChartWithCorrelation",
    "PlotBarChart",
    "read_skill_file",
    "scm-foundry-iq_knowledge_base_retrieve",
    "scm-workiq-managed_workiqmcp_InvokeWorkIQMCP",
    "system-mcp-monitor_monitor_resource_log_query",
    "system-mcp-monitor_monitor_workspace_log_query",
    "system-mcp-monitor_monitor_metrics_query",
    "system-mcp-monitor_monitor_resource_log_schema",
}

READ_COMMANDS = (
    "az monitor log-analytics query",
    "az monitor app-insights query",
    "az monitor app-insights component show",
    "az monitor metrics list",
    "az monitor metrics list-definitions",
    "az monitor activity-log list",
    "az monitor scheduled-query show",
    "az monitor scheduled-query list",
    "az network nsg show",
    "az network nsg list",
    "az network nsg rule show",
    "az network nsg rule list",
    "az network vnet show",
    "az network vnet list",
    "az network vnet subnet show",
    "az network vnet subnet list",
    "az network private-dns zone show",
    "az network private-dns record-set a list",
    "az network private-dns link vnet list",
    "az network route-table show",
    "az network route-table route list",
    "az postgres flexible-server show",
    "az postgres flexible-server list",
    "az postgres flexible-server parameter show",
    "az postgres flexible-server parameter list",
    "az webapp vnet-integration list",
    "az appservice plan show",
    "az resource show",
    "az resource list",
    "az graph query",
)

ALERT_PATH = re.compile(
    r"/subscriptions/db4948d5-b90c-47d4-91b5-d8c4c43493d2"
    r"/resourcegroups/rg-flu-xzlxm7twvdxao"
    r"/providers/microsoft\.operationalinsights/workspaces/flu-xzlxm7twvdxao-logs"
    r"/providers/microsoft\.alertsmanagement/alerts/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
    re.IGNORECASE,
)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def deny(reason):
    return {
        "ok": False,
        "reason": "SCM repair guard: " + reason,
        "hookSpecificOutput": {"permissionDecision": "deny"},
    }


def is_alert_read(tokens):
    if tokens[:2] != ["az", "rest"]:
        return False
    aliases = {
        "--method": "method", "-m": "method",
        "--url": "url", "--uri": "url", "-u": "url",
        "--query": "query", "--output": "output", "-o": "output",
    }
    options = {}
    index = 2
    while index < len(tokens):
        if tokens[index] == "--only-show-errors":
            index += 1
            continue
        key = aliases.get(tokens[index])
        if key is None or key in options or index + 1 >= len(tokens):
            return False
        options[key] = tokens[index + 1]
        index += 2
    if options.get("method", "").lower() != "get":
        return False
    try:
        url = urlsplit(options.get("url", ""))
        query = parse_qs(url.query, strict_parsing=True)
    except ValueError:
        return False
    return (
        url.scheme == "https"
        and url.netloc == "management.azure.com"
        and not url.fragment
        and ALERT_PATH.fullmatch(url.path) is not None
        and query == {"api-version": ["2019-03-01"]}
    )


def is_read_command(command):
    if not isinstance(command, str) or any(
        character in command for character in ("\n", "\r", "\0", "$", "`")
    ):
        return False
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        return False
    if any(token and all(character in ";&|<>" for character in token) for token in tokens):
        return False
    return (
        any(tokens[:len(prefix.split())] == prefix.split() for prefix in READ_COMMANDS)
        or is_alert_read(tokens)
    )


def evaluate(context):
    if not isinstance(context, dict) or context.get("hook_event_name") != "PreToolUse":
        return deny("missing or invalid PreToolUse context.")
    tool = context.get("tool_name")
    if not isinstance(tool, str):
        return deny("missing or invalid tool name.")
    if tool in READ_TOOLS:
        return {"ok": True}
    arguments = context.get("tool_input")
    if not isinstance(arguments, dict) or set(arguments) != {"command"}:
        return deny("only registered read tools and a single CLI command are permitted.")
    command = arguments["command"]
    if tool == "RunAzCliReadCommands" and is_read_command(command):
        return {"ok": True}
    if (
        tool == "RunAzCliWriteCommands"
        and context.get("agent_mode") == "Autonomous"
        and command == REPAIR_COMMAND
    ):
        # This administrator-owned exception intentionally overrides global deny.
        return {"ok": True, "hookSpecificOutput": {"permissionDecision": "allow"}}
    return deny(
        "only read-only investigation and the exact approved NSG access=Allow "
        "command in Autonomous mode are permitted. Do not retry via another tool."
    )


def main():
    try:
        context = json.load(sys.stdin, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        result = deny("malformed or ambiguous JSON context.")
    else:
        result = evaluate(context)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
