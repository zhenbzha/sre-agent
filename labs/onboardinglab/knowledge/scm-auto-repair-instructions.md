## Administrator-authorized SCM automatic recovery

This authorization applies only to the existing `alert-investigator` running
in Autonomous mode for the dedicated SCM checkout-failures response plan.
It is not evidence that the present incident has any particular cause.

Gather current failed-request/dependency telemetry, PostgreSQL resource state,
network configuration and relevant Activity Log evidence first. Independently
establish the cause; historical correspondence and handbook examples are not
proof. Keep the existing read-only Work IQ and Foundry IQ retrieval requirements.

The only preauthorized workload mutation is changing the existing
`PostgreSqlFaultInjection` rule on `flu-xzlxm7twvdxao-app-nsg` from Deny to
Allow. Before that action, verify that the server is Ready and private, and that
the current rule is Outbound/Tcp, priority 100, source 10.42.0.0/23,
destination 10.42.2.0/24 and destination port 5432. The live evidence must
establish that this rule blocks the application's PostgreSQL path. If the
rule differs, is already Allow, or the database is stopped, do not mutate it;
report the actual blocker and the operator action required.

Once those prerequisites are established, run this exact command once using
`RunAzCliWriteCommands`, without asking for approval:

```text
az network nsg rule update --subscription db4948d5-b90c-47d4-91b5-d8c4c43493d2 --resource-group rg-flu-xzlxm7twvdxao --nsg-name flu-xzlxm7twvdxao-app-nsg --name PostgreSqlFaultInjection --access Allow --only-show-errors --output json
```

An administrator-owned, fail-closed PreToolUse guard enforces this exception.
All other Azure writes remain denied. Do not alter the command, use another
execution tool, delegate the write, change permissions, stop/start PostgreSQL,
change public networking, inject faults, delete rules or modify other rule fields.
Do not create issues, send mail, change incidents or save memory. Earlier
follow-up instructions authorize drafting findings only, not publishing them.

Read the rule back and verify Allow/Succeeded and unchanged remaining fields.
Verify fresh successful POST /checkout and PostgreSQL dependency telemetry
after the repair; distinguish historical failures from the recovery interval.
Do not claim application recovery from /healthz or configuration alone. If no
new submissions exist, report the network repair as verified and application
recovery as awaiting a fresh material request. Azure Monitor resolves its
condition independently; Acknowledged/Closed and an investigation's Completed
state do not establish resolution. Never manually close an alert to pass a check.

For the current alert condition, use `RunAzCliReadCommands` with `az rest
--method get --url https://management.azure.com<alert-resource-id>?api-version=2019-03-01
--query properties.essentials.monitorCondition --output json`, as one command.
Copy the full alert resource ID from the trusted incident context. The guard
allows only GET for individual alerts under this demo's Log Analytics workspace;
it does not allow arbitrary REST requests. Do not use a terminal to wait.

If execution is denied, fails or has an unknown outcome, do not repeat it or
try an alternative write path. Read current state, report the evidence and
leave any further action to the operator. Other incidents and Review-mode
conversations retain operator-controlled recovery.
