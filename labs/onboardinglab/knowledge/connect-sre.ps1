#Requires -Version 7.3
[CmdletBinding()]
param(
    [string]$EnvironmentName = 'sre-agent-scm',
    [string]$AgentName = 'onboardinglab-agent',
    [string]$WorkIqConnectionName,
    [string]$WorkIqAccount
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'knowledge-common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\internal\JsonComparison.ps1')

if ($WorkIqConnectionName -or $WorkIqAccount) {
    if ($WorkIqConnectionName -notmatch '\A[a-zA-Z0-9-]+\z' -or
        [string]::IsNullOrWhiteSpace($WorkIqAccount)) {
        throw 'Supply both a valid WorkIqConnectionName and the approved WorkIqAccount.'
    }
}

$environment = azd -C $PSScriptRoot env get-values --environment $EnvironmentName --output json |
    ConvertFrom-Json -AsHashtable
foreach ($key in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'SRE_PRINCIPAL_ID', 'KNOWLEDGE_MCP_ENDPOINT')) {
    if ([string]::IsNullOrWhiteSpace($environment[$key])) { throw "Missing azd output $key." }
}
$configuration = Get-KnowledgeConfiguration $environment
if ($AgentName -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid SRE Agent resource name.' }
$agentId = "/subscriptions/$($environment.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($environment.AZURE_RESOURCE_GROUP)/providers/Microsoft.App/agents/$AgentName"
$agent = az rest --method GET --subscription $environment.AZURE_SUBSCRIPTION_ID `
    --url "https://management.azure.com$agentId`?api-version=2026-01-01" --output json |
    ConvertFrom-Json -AsHashtable
$identities = @($agent.identity.userAssignedIdentities.GetEnumerator() |
    Where-Object { $_.Value.principalId -eq $environment.SRE_PRINCIPAL_ID })
if ($identities.Count -ne 1) {
    throw 'Exactly one existing agent user-assigned identity must match the Search reader grant.'
}
$endpoint = $agent.properties.agentEndpoint.TrimEnd('/')
if (([uri]$endpoint).Scheme -ne 'https' -or ([uri]$endpoint).Host -notlike '*.azuresre.ai') {
    throw 'The agent did not return an expected Azure SRE endpoint.'
}
$token = az account get-access-token --subscription $environment.AZURE_SUBSCRIPTION_ID `
    --resource https://azuresre.dev --query accessToken --output tsv
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Azure CLI returned no SRE access token.' }
$credential = ConvertTo-SecureString $token -AsPlainText -Force
Remove-Variable token

function Invoke-Sre {
    param([string]$Method, [string]$Path, [object]$Body)
    $parameters = @{
        Uri = "$endpoint$Path"
        Method = $Method
        Authentication = 'Bearer'
        Token = $credential
        TimeoutSec = 120
        MaximumRedirection = 0
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 30 -Compress
    }
    Invoke-RestMethod @parameters
}

$workiqBinding = $null
$workiqTool = $null
if ($WorkIqConnectionName) {
    $connectionPath = "/api/v2/connectorV2/connections/$WorkIqConnectionName"
    $connection = Invoke-Sre -Method GET -Path $connectionPath
    if ($connection.properties.connectorName -eq 'workiqmcp' -and
        $connection.properties.overallStatus -eq 'Connected' -and
        [string]::IsNullOrWhiteSpace($connection.properties.authenticatedUser.name)) {
        throw 'Work IQ is Connected, but its authenticated-account display is empty. Setup has made no changes. Verify the actual delegated identity through an approved native /me read; do not assume the account or weaken this check.'
    }
    if ($connection.properties.connectorName -ne 'workiqmcp' -or
        $connection.properties.overallStatus -ne 'Connected' -or
        $connection.properties.authenticatedUser.name -ine $WorkIqAccount) {
        throw 'Work IQ must already be Connected as the explicitly approved account.'
    }
    $managedServers = Invoke-Sre -Method GET -Path '/api/v2/connectorV2/mcpservers'
    $matches = @($managedServers.value | Where-Object {
        $_.name -eq $WorkIqConnectionName -or
        'workiqmcp' -in @($_.properties.connectors.name)
    })
    if ($matches.Count -gt 1 -or ($matches.Count -eq 1 -and (
        $matches[0].name -ne $WorkIqConnectionName -or
        $matches[0].properties.description -ne 'Read-only SCM incident history from the authenticated demo mailbox.' -or
        @($matches[0].properties.connectors).Count -ne 1 -or
        $matches[0].properties.connectors[0].connectionName -ne $WorkIqConnectionName))) {
        throw 'An unrelated managed connector binding exists; refusing to overwrite it.'
    }
    $workiqBinding = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'workiq-history-connector.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $workiqBinding.properties.connectors[0].connectionName = $WorkIqConnectionName
    if ($matches.Count -eq 1) {
        foreach ($property in @('policies', 'disableApiKeyAuth')) {
            if ($matches[0].properties.PSObject.Properties[$property]) {
                $workiqBinding.properties[$property] = $matches[0].properties.$property
            }
        }
    }
    $workiqTool = "${WorkIqConnectionName}_workiqmcp_InvokeWorkIQMCP"
}

$name = 'scm-foundry-iq'
$path = "/api/v2/extendedAgent/connectors/$name"
$inventory = Invoke-Sre -Method GET -Path '/api/v2/extendedAgent/connectors/listSecrets'
$existing = @($inventory.value | Where-Object { $_.name -eq $name })
if ($existing.Count -gt 1) { throw 'SRE returned more than one connector with this name.' }
if ($existing.Count -eq 1 -and
    ($existing[0].properties.dataConnectorType -ne 'Mcp' -or
     $existing[0].properties.extendedProperties.endpoint -ne $configuration.McpEndpoint)) {
    throw 'An unrelated connector already uses the requested name; refusing to overwrite it.'
}

# This is the same identity/scope payload used by the official SRE connector UI.
$connector = @{
    name = $name
    type = 'AgentConnector'
    properties = @{
        dataConnectorType = 'Mcp'
        dataSource = 'placeholder'
        identity = $identities[0].Key
        extendedProperties = @{
            type = 'http'
            endpoint = $configuration.McpEndpoint
            authType = 'AzureARM'
            armScope = 'https://search.azure.com/.default'
        }
    }
}
$test = Invoke-Sre -Method POST -Path "$path/testconnection" -Body $connector
if (-not $test.success) { throw "SRE MCP connection test failed: $($test.errorMessage)" }
$tools = @($test.tools | Where-Object {
    $_.name -eq 'knowledge_base_retrieve' -or $_.name -eq "${name}_knowledge_base_retrieve"
})
if ($tools.Count -ne 1) {
    throw "Expected one knowledge_base_retrieve tool; discovered: $($test.tools.name -join ', ')."
}
$connector.properties.extendedProperties.selectedTools = @('knowledge_base_retrieve')
$connector.properties.extendedProperties.toolsVisibleToMetaAgent = @("${name}_knowledge_base_retrieve")
$null = Invoke-Sre -Method PUT -Path $path -Body $connector

$deadline = [datetime]::UtcNow.AddMinutes(3)
do {
    $discovered = Invoke-Sre -Method GET -Path "$path/tools"
    if ($discovered.connectionStatus -eq 'Connected') { break }
    if ($discovered.connectionStatus -eq 'Failed') {
        throw "SRE connector failed: $($discovered.errorMessage)"
    }
    Start-Sleep -Seconds 10
} while ([datetime]::UtcNow -lt $deadline)
if ($discovered.connectionStatus -ne 'Connected') { throw 'SRE connector did not become Connected within three minutes.' }
if (@($discovered.tools | Where-Object { $_.name -match '(^|_)knowledge_base_retrieve$' }).Count -ne 1) {
    throw 'The connected SRE connector did not expose the expected retrieval tool.'
}
# Ordinary GET redacts connection properties, including the nonsecret endpoint/scope.
$storedInventory = Invoke-Sre -Method GET -Path '/api/v2/extendedAgent/connectors/listSecrets'
$stored = @($storedInventory.value | Where-Object { $_.name -eq $name })[0]
if ($stored.properties.extendedProperties.armScope -ne 'https://search.azure.com/.default' -or
    $stored.properties.identity -ne $identities[0].Key) {
    throw 'The persisted SRE identity or Search scope does not match the requested configuration.'
}

if ($workiqBinding) {
    $null = Invoke-Sre -Method PUT -Path "$connectionPath/accessPolicies/$WorkIqConnectionName-policy"
    $bindingPath = "/api/v2/connectorV2/mcpservers/$WorkIqConnectionName"
    $null = Invoke-Sre -Method PUT -Path $bindingPath -Body $workiqBinding
    $savedBinding = Invoke-Sre -Method GET -Path $bindingPath
    foreach ($property in $workiqBinding.properties.Keys) {
        $expected = ConvertTo-CanonicalJson $workiqBinding.properties[$property]
        $actual = ConvertTo-CanonicalJson $savedBinding.properties.$property
        if ($property -eq 'connectors') {
            $savedOperations = @($savedBinding.properties.connectors[0].operations)
            $expectedOperation = $workiqBinding.properties.connectors[0].operations[0]
            if (@($savedBinding.properties.connectors).Count -ne 1 -or $savedOperations.Count -ne 1 -or
                $savedBinding.properties.connectors[0].name -ne 'workiqmcp' -or
                $savedBinding.properties.connectors[0].connectionName -ne $WorkIqConnectionName -or
                $savedOperations[0].name -ne 'InvokeWorkIQMCP' -or @($savedOperations[0].agentParameters).Count -ne 0 -or
                (ConvertTo-CanonicalJson $savedOperations[0].userParameters) -cne
                (ConvertTo-CanonicalJson $expectedOperation.userParameters)) {
                throw 'The native gateway did not retain the fully locked read-only Work IQ request.'
            }
        } elseif ($expected -cne $actual) {
            throw "Unexpected Work IQ binding change: $property."
        }
    }
    $runtimeConfiguration = $savedBinding.PSObject.Properties['runtimeMcpConfiguration']
    if ($runtimeConfiguration -and $runtimeConfiguration.Value -and
        $runtimeConfiguration.Value.PSObject.Properties['requireApprovalTools'] -and
        @($runtimeConfiguration.Value.requireApprovalTools).Count -ne 0) {
        throw 'The fixed read-only history tool is not configured for automatic retrieval.'
    }
    $deadline = [datetime]::UtcNow.AddMinutes(3)
    do {
        $runtimeConnections = Invoke-Sre -Method GET -Path '/api/v1/mcp/connections/list'
        $runtimeWorkIq = @($runtimeConnections | Where-Object { $_.name -eq $WorkIqConnectionName })
        if ($runtimeWorkIq.Count -eq 1 -and @($runtimeWorkIq[0].tools).Count -eq 1 -and
            $runtimeWorkIq[0].tools[0].name -eq $workiqTool) { break }
        Start-Sleep -Seconds 10
    } while ([datetime]::UtcNow -lt $deadline)
    if ($runtimeWorkIq.Count -ne 1 -or @($runtimeWorkIq[0].tools).Count -ne 1 -or
        $runtimeWorkIq[0].tools[0].name -ne $workiqTool) {
        throw 'The native Work IQ runtime did not expose exactly the configured history tool.'
    }
}

function Set-InstructionBlock {
    param([string]$Instructions, [string]$Marker, [string]$Guidance)
    $startMarker = "<!-- ${Marker}:start -->"
    $endMarker = "<!-- ${Marker}:end -->"
    $start = $Instructions.IndexOf($startMarker, [StringComparison]::Ordinal)
    $block = "$startMarker`n$Guidance`n$endMarker"
    if ($start -lt 0) { return $Instructions.TrimEnd() + "`n`n$block" }
    $end = $Instructions.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw "The existing $Marker instruction block is incomplete; inspect it before updating." }
    $Instructions.Substring(0, $start) + $block + $Instructions.Substring($end + $endMarker.Length)
}

$handlerPath = '/api/v2/extendedAgent/agents/alert-investigator'
$handler = Invoke-Sre -Method GET -Path $handlerPath
$guidance = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'incident-knowledge-instructions.md') -Raw).Trim()
$instructions = Set-InstructionBlock ([string]$handler.properties.instructions) 'scm-foundry-iq' $guidance
$mcpTools = @(@($handler.properties.mcpTools | Where-Object { $_ }) + @("${name}_knowledge_base_retrieve") |
    Sort-Object -Unique)
if ($workiqTool) {
    $historyGuidance = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'incident-history-instructions.md') -Raw).
        Replace('__WORKIQ_TOOL__', $workiqTool).Trim()
    $instructions = Set-InstructionBlock $instructions 'scm-workiq-history' $historyGuidance
    $mcpTools = @(@($mcpTools) + @($workiqTool) | Sort-Object -Unique)
}
$null = Invoke-Sre -Method PATCH -Path $handlerPath -Body @{
    name = 'alert-investigator'
    type = 'ExtendedAgent'
    properties = @{ instructions = $instructions; mcpTools = $mcpTools }
}
$updatedHandler = Invoke-Sre -Method GET -Path $handlerPath
if ($updatedHandler.properties.instructions -ne $instructions -or
    "${name}_knowledge_base_retrieve" -notin $updatedHandler.properties.mcpTools -or
    ($workiqTool -and $workiqTool -notin $updatedHandler.properties.mcpTools)) {
    throw 'The existing incident handler did not retain its document-lookup instructions and MCP tool.'
}
foreach ($property in $handler.properties.PSObject.Properties) {
    if ($property.Name -in @('instructions', 'mcpTools')) { continue }
    $before = ConvertTo-CanonicalJson $property.Value
    $after = ConvertTo-CanonicalJson $updatedHandler.properties.($property.Name)
    if ($before -cne $after) { throw "Unexpected incident handler change: $($property.Name)." }
}
[pscustomobject]@{
    Agent = $AgentName
    Connector = $name
    Status = $discovered.connectionStatus
    Tool = "${name}_knowledge_base_retrieve"
    Identity = $identities[0].Key
    Endpoint = $configuration.McpEndpoint
    IncidentHandler = 'alert-investigator'
    WorkIqHistoryTool = $workiqTool
    WorkIqRetrievalVerified = $false
}
