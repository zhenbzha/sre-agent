function Get-KnowledgeConfiguration {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)

    foreach ($key in @('AZURE_SEARCH_NAME', 'AZURE_FOUNDRY_NAME', 'KNOWLEDGE_SOURCE_NAME', 'KNOWLEDGE_BASE_NAME', 'KNOWLEDGE_MCP_ENDPOINT')) {
        if ([string]::IsNullOrWhiteSpace($Environment[$key])) { throw "Missing azd output $key." }
    }
    $searchName = $Environment['AZURE_SEARCH_NAME']
    if ($searchName -cnotmatch '\A[a-z0-9]{2}(?:[a-z0-9-]{0,57}[a-z0-9])?\z' -or $searchName.Contains('--')) {
        throw 'Invalid AZURE_SEARCH_NAME. Expected a 2-60 character Search resource name, not a URL.'
    }
    $foundryName = $Environment['AZURE_FOUNDRY_NAME']
    if ($foundryName -cnotmatch '\A[a-zA-Z0-9][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]\z') {
        throw 'Invalid AZURE_FOUNDRY_NAME. Expected a 2-64 character Foundry resource name, not a URL.'
    }
    if ($Environment['KNOWLEDGE_SOURCE_NAME'] -cne 'scm-operations-handbook' -or
        $Environment['KNOWLEDGE_BASE_NAME'] -cne 'scm-operations') {
        throw 'This component manages only the SCM handbook source and SCM operations knowledge base.'
    }

    $endpoint = "https://$searchName.search.windows.net"
    $apiVersion = '2026-08-01-preview'
    $mcpEndpoint = "$endpoint/knowledgebases/scm-operations/mcp?api-version=$apiVersion"
    if ($Environment['KNOWLEDGE_MCP_ENDPOINT'] -cne $mcpEndpoint) {
        throw 'KNOWLEDGE_MCP_ENDPOINT does not match the configured Search service and SCM knowledge base.'
    }
    [pscustomobject]@{
        SearchEndpoint = $endpoint
        ModelEndpoint = "https://$foundryName.openai.azure.com"
        SourceName = 'scm-operations-handbook'
        BaseName = 'scm-operations'
        ApiVersion = $apiVersion
        McpEndpoint = $mcpEndpoint
    }
}
