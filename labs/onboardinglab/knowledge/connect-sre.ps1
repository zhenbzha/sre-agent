#Requires -Version 7.3
[CmdletBinding()]
param(
    [string]$EnvironmentName = 'sre-agent-scm',
    [string]$AgentName = 'onboardinglab-agent'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'knowledge-common.ps1')

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

$handlerPath = '/api/v2/extendedAgent/agents/alert-investigator'
$handler = Invoke-Sre -Method GET -Path $handlerPath
$guidance = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'incident-knowledge-instructions.md') -Raw).Trim()
$startMarker = '<!-- scm-foundry-iq:start -->'
$endMarker = '<!-- scm-foundry-iq:end -->'
$block = "$startMarker`n$guidance`n$endMarker"
$instructions = [string]$handler.properties.instructions
$start = $instructions.IndexOf($startMarker, [StringComparison]::Ordinal)
if ($start -ge 0) {
    $end = $instructions.IndexOf($endMarker, $start, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw 'The existing Foundry IQ instruction block is incomplete; inspect it before updating.' }
    $instructions = $instructions.Substring(0, $start) + $block + $instructions.Substring($end + $endMarker.Length)
} else {
    $instructions = $instructions.TrimEnd() + "`n`n$block"
}
$mcpTools = @(@($handler.properties.mcpTools | Where-Object { $_ }) + @("${name}_knowledge_base_retrieve") |
    Sort-Object -Unique)
$null = Invoke-Sre -Method PATCH -Path $handlerPath -Body @{
    name = 'alert-investigator'
    type = 'ExtendedAgent'
    properties = @{ instructions = $instructions; mcpTools = $mcpTools }
}
$updatedHandler = Invoke-Sre -Method GET -Path $handlerPath
if ($updatedHandler.properties.instructions -ne $instructions -or
    "${name}_knowledge_base_retrieve" -notin $updatedHandler.properties.mcpTools) {
    throw 'The existing incident handler did not retain its document-lookup instructions and MCP tool.'
}
foreach ($property in $handler.properties.PSObject.Properties) {
    if ($property.Name -in @('instructions', 'mcpTools')) { continue }
    $before = $property.Value | ConvertTo-Json -Depth 30 -Compress
    $after = $updatedHandler.properties.($property.Name) | ConvertTo-Json -Depth 30 -Compress
    if ($before -ne $after) { throw "Unexpected incident handler change: $($property.Name)." }
}
[pscustomobject]@{
    Agent = $AgentName
    Connector = $name
    Status = $discovered.connectionStatus
    Tool = "${name}_knowledge_base_retrieve"
    Identity = $identities[0].Key
    Endpoint = $configuration.McpEndpoint
    IncidentHandler = 'alert-investigator'
}
