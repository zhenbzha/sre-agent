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
- [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)
- [Bicep resource dependencies](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/resource-dependencies)
- [Search AVM resource-name contract](https://github.com/Azure/bicep-registry-modules/blob/avm/res/search/search-service/0.13.0/avm/res/search/search-service/main.bicep)
- [Bicep role-assignment naming and identity recreation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/scenarios-rbac)
- [Official identity/role-assignment module sample](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.keyvault/key-vault-managed-identity-role-assignment)
