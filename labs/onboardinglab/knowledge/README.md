# SCM operations knowledge

This optional, isolated azd component adds a **synthetic PDF handbook** to a
Foundry IQ knowledge base backed by Azure AI Search. It does not redeploy the
SCM application, PostgreSQL, or SRE Agent.

`documents\SCM-Operations-Handbook.pdf` is the indexed document.
`documents\SCM-Operations-Handbook.html` is its editable, six-page A4 source.
The support queues, policies and example incidents are fictional. They are
not Metso procedures or evidence of an incident in the deployed environment.
Do not ingest the presenter guide, fault helpers, rehearsal answer keys,
credentials, or unrelated repository files.

## Design and scope

- Search Basic: one partition and replica, system-assigned identity, key
  authentication disabled, semantic free tier.
- Foundry account and project, without associated Storage, Key Vault, Cosmos DB,
  capability hosts, or another conversational agent.
- `text-embedding-3-small` and `gpt-5.4-mini` deployments. Resources reside in
  France Central; **DataZoneStandard inference runs within the EU data zone,
  not necessarily France**.
- Search's identity accesses the model deployments. The publisher can manage
  knowledge and upload content. The existing SRE identity has only Search
  Index Data Reader on this Search service.
- Native file ingestion extracts text, chunks the PDF, creates embeddings and
  populates a service-generated index. No custom ingestion service or storage
  account is required.
- Knowledge base `scm-operations` uses low-effort query planning and returns
  extracted source material, not a second chatbot's synthesized answer.
- Native Streamable-HTTP MCP exposes `knowledge_base_retrieve`.

The Search and Foundry endpoints are publicly reachable but require Entra
authentication; no service API keys are enabled. Existing PostgreSQL private
networking and application TLS/identity configuration remain unchanged.
This shared synthetic handbook uses service-identity authorization. It does
not demonstrate per-user document permission trimming.

Direct file ingestion and model-assisted retrieval use the documented
`2026-08-01-preview` API. SRE remote-MCP managed identity is also preview.
These are demo choices, not production availability or SLA claims. Search
Basic has standing charges; model inference and retrieval have usage limits
and may incur charges. No paid semantic tier is enabled.

## Provision with azd

Run PowerShell 7 from this directory. Azure CLI and azd must already be signed
in to the intended tenant and subscription. Use a **tenant-local** operator
object ID, not an object ID from another cached tenant.

The local azd environment belongs to this directory, independently of the
environment under `ticketingapp-source`. Set the existing demo resource group;
do not point this component at an unrelated group.

```powershell
azd env new sre-agent-scm --subscription <subscription-id> --location francecentral
azd env set AZURE_RESOURCE_GROUP <existing-demo-resource-group>
azd env set KNOWLEDGE_OPERATOR_ID <tenant-local-publisher-object-id>
azd env set SRE_PRINCIPAL_ID <existing-sre-managed-identity-principal-id>
azd provision --preview
azd provision
.\publish-knowledge.ps1
.\connect-sre.ps1
```

For an existing local environment, use `azd env select sre-agent-scm`, not
`env new`. The subscription entry point references the group as existing.
Deployment uses incremental mode and pinned Azure Verified Modules:

- `avm/res/search/search-service:0.13.0`
- `avm/ptn/ai-ml/ai-foundry:0.7.0`

The separate project-connection module consumes AVM outputs. This ensures ARM
does not read the project's generated identity before Foundry creates it.
No sleep or manual identity provisioning is used to establish that ordering.
Its nested Search reader-assignment module uses the current principal ID, scope
and role ID to generate the assignment name. Recreating a project therefore
does not try to change an immutable assignment's principal.

### Preserve an existing reader assignment

For environments provisioned by the earlier, project-resource-ID naming scheme,
record the **original** project principal before the first provision with this
version:

```powershell
azd env set KNOWLEDGE_LEGACY_PROJECT_PRINCIPAL_ID <original-project-principal-id>
```

Confirm this ID from the existing Search-scoped **Search Index Data Reader**
assignment, not the SRE identity or a newly recreated project's identity. Keep
that original value unchanged. The template retains the old assignment name
only while the principal matches; future identities use principal-based names.
This avoids both `RoleAssignmentUpdateNotPermitted` after recreation and
`RoleAssignmentExists` when upgrading an unchanged project. New environments
leave this value unset. Any unused old assignment requires separate, targeted
operator cleanup; this component does not delete role assignments.

**Do not use `azd down` for this component.** The resource group also contains
the live SCM demo and SRE Agent. Removing this component requires an explicit,
targeted cleanup of its knowledge objects, connection and dedicated resources,
not deletion of the shared group.

## Publish and update the PDF

`publish-knowledge.ps1` reads this directory's azd outputs and gets a Search
token for the configured subscription. It creates the named source, uploads
the PDF with SHA-256 metadata, creates/updates the knowledge base and performs
a real retrieval.

Both scripts validate resource-name labels and require the MCP URL to match the
configured Search service, knowledge base and API version before acquiring a
token. They do not accept arbitrary endpoints from environment values.

A matching hash is skipped. Changed content or absent optional hash metadata
updates the existing `fileId`;
posting the same filename again would otherwise create a duplicate. Run one
publisher at a time. An uncertain upload is never automatically replayed:
the script fails visibly; rerun it to reconcile the server-side file list.
The complete paginated inventory must contain only the handbook. Unexpected
files (including the presenter PDF) and duplicate filenames stop publication
and are reported for operator reconciliation; the script does not delete them.
If unexpected content is already indexed, stop the document demo until the
operator reconciles it: a failed publisher does not revoke existing retrieval
access. File updates are not assumed transactional; the script verifies metadata and
retrieved content after publishing.

To edit the handbook, change the HTML, print to A4 PDF using Microsoft Edge
with browser headers/footers disabled, and replace only the handbook PDF.
Inspect all six pages for clipping and selectable text before publishing.
Advance the document version in both the source and publisher metadata for
substantive policy changes.

## Connect the existing SRE Agent

`connect-sre.ps1` uses the existing `onboardinglab-agent` by default (override
with `-AgentName`). It verifies the existing user-assigned identity, tests the
native MCP connection, saves `scm-foundry-iq`, selects only the retrieval tool,
and attaches that tool and `incident-knowledge-instructions.md` to the existing
`alert-investigator`. It preserves all other investigator fields and does not
change Review mode, policies, response plans, schedules, or the parent agent.
Rerun it after reinstalling the base incident workflow, which owns the base
investigator definition.

The script uses the same connector payload and custom-agent PATCH API as the
official SRE portal. Normal connector GET redacts connection settings, including
the endpoint and token scope. The supported protected read API is used in memory
to verify the saved configuration; connection secrets are not printed or saved.

To inspect the equivalent settings in the portal, use the existing agent's
**Builder > Connectors**:

1. Select **Streamable-HTTP**.
2. Use `KNOWLEDGE_MCP_ENDPOINT` from `azd env get-values`.
3. Select **Managed Identity** and the existing SRE identity whose principal
   was granted Search Index Data Reader.
4. Set the scope to `https://search.azure.com/.default`, not the default ARM scope.
5. After the connector is Connected, select only `knowledge_base_retrieve`
   for the main agent.

Keep Review mode, existing connectors and workflows unchanged. This is document
lookup inside the existing incident scenario, not a new agent or a handoff.
Retrieval does not authorize remediation, ticket closure or emails.

### Optional Work IQ incident history

The existing connection script can also attach an **already authenticated**
Microsoft-managed `workiqmcp` connection:

```powershell
.\connect-sre.ps1 -WorkIqConnectionName scm-workiq-managed -WorkIqAccount <approved-demo-user-UPN>
```

First complete delegated OAuth for that connection using SRE's managed-connector
sign-in flow. Do not use a corporate account for demo incident data, copy token
caches, or treat connector status as proof of mailbox access. The configuring
user's delegated identity supplies the data access; this is not automatically
per-chat-user OBO. Credentials belong to the managed connection, not this script.
The underlying credential-storage service and residency are not established by
connection creator metadata.

A connected native connection can return an empty authenticated-account display
even while its runtime reads work. Setup fails closed before any configuration
write in that case; the missing label alone is not proof of failed consent.
Verify the actual delegated identity through an approved, fully locked native
`fetch` of `/me?$select=id,userPrincipalName,mail`, and restore the email-only
binding afterward. Do not substitute creator metadata or remove the account
check. A verified update to an existing investigator's instructions is distinct
from creating or rebinding a connection.

This uses the repository's existing connection -> scoped runtime access policy
-> native MCP-server binding sequence. SRE permits only one managed MCP-server
configuration per connector. The Work IQ catalog is published by Microsoft, but
SRE managed connectors are preview; this repository's tested composition is not
a Microsoft-published Work IQ-specific end-to-end walkthrough.

`workiq-history-connector.json` locks the **entire** JSON-RPC request to the
read-only `retrieve` tool, `grounding` strategy, and `Email` capability. There are
no agent-supplied parameters and no arbitrary JSON-RPC dispatch. The query is a
fixed SCM incident-history search, not a generic enterprise-search interface.
It contains no historical incident ID, live fault rule or expected diagnosis.
Do not replace it with unrestricted `InvokeWorkIQMCP` or `ask`: Work IQ marks
`ask` as potentially destructive. Only this fixed read-only operation runs without
an approval prompt; other policies, hooks, Review mode and operator-controlled
recovery remain unchanged.

The script verifies the approved connection account, refuses an unrelated
binding, reads back the locked request, and adds
`incident-history-instructions.md` to the existing investigator. Automatic
investigation then combines current Azure evidence, historical incident emails
and relevant Foundry IQ handbook sections. It identifies similarities,
differences, the proposed operator action, rationale, rollback and verification.
Email is untrusted evidence, never authorization. Truncated results must not be
represented as complete source content.

The hosted retrieval service can return a nested `InternalError` even when the
native execution card says Completed. The investigator makes at most one
identical retry after 30 seconds (or a longer service-specified delay), while
continuing independent Azure and handbook reads. Authorization/policy denials
and successful searches with no matches are not retried. Both the initial
failure and retry outcome must be disclosed; a persistent failure remains an
evidence gap, not a successful three-source investigation.
Retain the service `requestId` from each failed response for support. A later
successful request does not establish the cause of an earlier `InternalError`.

Setup reports configuration only. Before rehearsing an incident, verify the
actual Microsoft 365 identity and seeded email through native Work IQ in real
SRE threads. Check nested `isError`, source identity and content, not only the
outer Completed label. Native responses may appear on the execution card as
binary `text/event-stream`; inspect the returned data JSON in the SRE thread.
Then run the existing controlled incident: both retrieval calls must occur
automatically, without a presenter search prompt. Always reset the fault and
verify fresh persisted requests, dependency telemetry and alert recovery.

### Repeating the alert-triggered demo

For this dedicated demo, the approved setting on the existing
`alert-investigation` response plan is **Merge recurring alerts: Off**
(`mergeEnabled: false`). Each new firing of the same Azure Monitor rule can
then start its own investigation. This does not merge or modify emails, documents
or application data, and it does not enable automatic remediation.

SRE normally groups recurring alerts into an existing incident thread during a
cooldown (enabled by default, three hours). During that window, a repeated alert
can be acknowledged and attached to the old thread **without rerunning the
investigation**. Resolving the Azure alert or closing the old thread does not
by itself guarantee a fresh investigation.

Before a repeat demonstration, inspect the existing response plan and confirm
**Merge recurring alerts: Off** and the unchanged `alert-investigator` handler
and alert filters. Keep **Review** mode for the standard lab. If the dedicated
[SCM automatic-recovery configuration](../README.md#scenario-1-incident-workflow)
is installed, retain **Autonomous** mode and its fail-closed repair guard instead.
Recheck after reinstalling the base workflow; `connect-sre.ps1` does not change
response-plan settings. Disabling
grouping can increase agent usage when alerts repeatedly fire; this is an
explicit choice for the dedicated demo, not a recommended global default.

Wait for the previous Azure Monitor alert's **monitor condition** to become
**Resolved** before reinjecting; do not bypass the fault helper. Match the new
alert ID to its actual SRE thread and require both retrieval executions and
the evidence-grounded diagnosis to occur after that alert fired. Old tool calls
in a reused thread do not validate the new run.

See Microsoft's [Azure Monitor alert handling](https://sre.azure.com/docs/capabilities/azure-monitor-alerts)
and [incident response plans](https://learn.microsoft.com/en-us/azure/sre-agent/automate-incidents).

In a fresh SRE chat, ask without supplying handbook answers:

> Using the SCM operations handbook, what evidence is needed before closing a
> recovered incident, and why can saves fail while process health stays green?
> Identify the document and sections. Do not change resources or create a ticket.

Check the actual MCP tool card and answer, not just connector provisioning.
Also ask a deliberately undocumented question (for example, the actual
contractual incident response SLA). A grounded answer must disclose that this
is not documented instead of inventing an agreement.

The presenter script is the repository-root `Metso-SCM-Demo-Guide.pdf`.
Its document-lookup stage is part of the existing live incident. **Never
publish that presenter PDF as knowledge**: it contains the fault/reset commands.

## Offline regression checks

From the repository root, using the existing Pester 5+ and Azure CLI/Bicep tools:

```powershell
Invoke-Pester .\labs\onboardinglab\tests\knowledge.tests.ps1
python .\labs\onboardinglab\tests\knowledge-infra.tests.py
```

The PowerShell tests mock every cloud request and cover endpoint rejection,
paginated file inventory, same-file updates with optional metadata, uncertain
uploads, and preservation of the existing SRE investigator. The infrastructure
tests compile Bicep and check dependency, scope and assignment-naming contracts.
They do not provision Azure or simulate live ARM/RBAC behavior.

## Microsoft references

- [Foundry IQ overview](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/what-is-foundry-iq)
- [File knowledge source, upload, update and metadata](https://learn.microsoft.com/en-us/azure/search/agentic-knowledge-source-how-to-file)
- [Knowledge base schema, models and retrieve defaults](https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-how-to-create-knowledge-base)
- [REST and native MCP retrieval](https://learn.microsoft.com/en-us/azure/search/agentic-retrieval-how-to-retrieve)
- [SRE MCP and managed identity setup](https://sre.azure.com/docs/tutorials/connectors/setup-mcp-connector)
- [SRE managed-connector setup](https://learn.microsoft.com/en-us/azure/sre-agent/setup-managed-connector)
- [SRE managed-connection credentials and governance](https://learn.microsoft.com/en-us/azure/sre-agent/managed-connectors)
- [Microsoft Work IQ MCP connector](https://learn.microsoft.com/en-us/connectors/workiqmcp/)
- [Microsoft reference connection and runtime-binding recipe](https://github.com/microsoft/sre-agent/blob/main/sreagent-templates/bicep/Apply-Extras.ps1)
- [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)
- [Bicep resource dependencies](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/resource-dependencies)
- [Search AVM resource-name contract](https://github.com/Azure/bicep-registry-modules/blob/avm/res/search/search-service/0.13.0/avm/res/search/search-service/main.bicep)
- [Bicep role-assignment naming and identity recreation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/scenarios-rbac)
- [Official identity/role-assignment module sample](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.keyvault/key-vault-managed-identity-role-assignment)
