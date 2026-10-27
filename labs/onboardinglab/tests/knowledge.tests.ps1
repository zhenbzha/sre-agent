#Requires -Version 7.3
# Run with Pester 5 or later. All cloud calls are mocked.
Describe 'Foundry IQ publishing and connector' {
    BeforeAll {
        $global:ScmKnowledgeTest = @{}
        $global:ScmKnowledgeTest.knowledgeRoot = Join-Path $PSScriptRoot '..\knowledge'
        $global:ScmKnowledgeTest.handbookName = 'SCM-Operations-Handbook.pdf'
        $global:ScmKnowledgeTest.handbookHash = (Get-FileHash (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'documents\SCM-Operations-Handbook.pdf')).Hash.ToLowerInvariant()
        function az { throw 'Tests must mock Azure CLI calls.' }
        function azd { throw 'Tests must mock azd calls.' }
        function Copy-TestObject($Value) {
            ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 40) -AsHashtable
        }
        function New-TestResponse($Body) {
            @{ StatusCode = 200; Content = ConvertTo-Json -InputObject $Body -Depth 40 }
        }
    }

    AfterAll { Remove-Variable ScmKnowledgeTest -Scope Global }

    BeforeEach {
        $global:ScmKnowledgeTest.environment = @{
            AZURE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
            AZURE_RESOURCE_GROUP = 'rg-test'
            AZURE_SEARCH_NAME = 'srch-test'
            AZURE_FOUNDRY_NAME = 'ai-test'
            SRE_PRINCIPAL_ID = '22222222-2222-2222-2222-222222222222'
            KNOWLEDGE_SOURCE_NAME = 'scm-operations-handbook'
            KNOWLEDGE_BASE_NAME = 'scm-operations'
            KNOWLEDGE_MCP_ENDPOINT = 'https://srch-test.search.windows.net/knowledgebases/scm-operations/mcp?api-version=2026-08-01-preview'
        }
        $global:ScmKnowledgeTest.identityId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test-sre-id'
        $global:ScmKnowledgeTest.requests = [System.Collections.Generic.List[object]]::new()
        Mock azd { ConvertTo-Json -InputObject $global:ScmKnowledgeTest.environment }
        Mock az {
            $global:LASTEXITCODE = 0
            if (($args -join ' ') -like 'account get-access-token *') { return 'synthetic-test-token' }
            if (($args -join ' ') -like 'rest --method GET *') {
                return ConvertTo-Json -Depth 10 -InputObject @{
                    identity = @{
                        userAssignedIdentities = @{
                            $global:ScmKnowledgeTest.identityId = @{ principalId = $global:ScmKnowledgeTest.environment.SRE_PRINCIPAL_ID }
                        }
                    }
                    properties = @{ agentEndpoint = 'https://test.region.azuresre.ai' }
                }
            }
            throw "Unexpected Azure CLI call: $($args -join ' ')"
        }
        Mock Invoke-WebRequest { throw 'Unexpected Search request.' }
        Mock Invoke-RestMethod { throw 'Unexpected SRE request.' }
        Mock Write-Host {}
        Mock Start-Sleep { throw 'Tests must not wait for a cloud operation.' }
    }

    Context 'Knowledge endpoint validation before credentials or network access' {
        It 'rejects malformed <Key> value <Value>' -ForEach @(
            @{ Key = 'AZURE_SEARCH_NAME'; Value = 'example.invalid/' }
            @{ Key = 'AZURE_SEARCH_NAME'; Value = 'user@example.invalid' }
            @{ Key = 'AZURE_SEARCH_NAME'; Value = 'srch-test:8443' }
            @{ Key = 'AZURE_SEARCH_NAME'; Value = 'srch-test?query=x' }
            @{ Key = 'AZURE_SEARCH_NAME'; Value = 'srch-test#fragment' }
            @{ Key = 'AZURE_SEARCH_NAME'; Value = 'srch--test' }
            @{ Key = 'AZURE_SEARCH_NAME'; Value = 'srch-test-' }
            @{ Key = 'AZURE_SEARCH_NAME'; Value = ('s' * 61) }
            @{ Key = 'AZURE_SEARCH_NAME'; Value = "srch-test`n" }
            @{ Key = 'AZURE_FOUNDRY_NAME'; Value = 'example.invalid/' }
            @{ Key = 'AZURE_FOUNDRY_NAME'; Value = 'user@example.invalid' }
            @{ Key = 'AZURE_FOUNDRY_NAME'; Value = 'ai-test:8443' }
            @{ Key = 'AZURE_FOUNDRY_NAME'; Value = 'ai-test?query=x' }
            @{ Key = 'AZURE_FOUNDRY_NAME'; Value = ('a' * 65) }
            @{ Key = 'KNOWLEDGE_BASE_NAME'; Value = 'another-base' }
            @{ Key = 'KNOWLEDGE_SOURCE_NAME'; Value = 'another-source' }
        ) {
            $global:ScmKnowledgeTest.environment[$Key] = $Value
            $expectedError = if ($Key -like 'AZURE_*') { "*Invalid $Key*" } else { '*component manages only*' }
            foreach ($scriptName in @('publish-knowledge.ps1', 'connect-sre.ps1')) {
                { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot $scriptName) } | Should -Throw $expectedError
            }
            Should -Invoke az -Times 0 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'rejects an inconsistent MCP URL <Url>' -ForEach @(
            @{ Url = 'https://example.invalid/mcp' }
            @{ Url = 'https://another-search.search.windows.net/knowledgebases/scm-operations/mcp?api-version=2026-08-01-preview' }
            @{ Url = 'https://srch-test.search.windows.net:8443/knowledgebases/scm-operations/mcp?api-version=2026-08-01-preview' }
            @{ Url = 'https://user@srch-test.search.windows.net/knowledgebases/scm-operations/mcp?api-version=2026-08-01-preview' }
            @{ Url = 'http://srch-test.search.windows.net/knowledgebases/scm-operations/mcp?api-version=2026-08-01-preview' }
            @{ Url = 'https://srch-test.search.windows.net/knowledgebases/another-base/mcp?api-version=2026-08-01-preview' }
            @{ Url = 'https://srch-test.search.windows.net/knowledgebases/scm-operations/mcp?api-version=2026-08-01-preview&extra=true' }
        ) {
            $global:ScmKnowledgeTest.environment.KNOWLEDGE_MCP_ENDPOINT = $Url
            foreach ($scriptName in @('publish-knowledge.ps1', 'connect-sre.ps1')) {
                { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot $scriptName) } | Should -Throw '*KNOWLEDGE_MCP_ENDPOINT*'
            }
            Should -Invoke az -Times 0 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }

    Context 'Single-handbook publication and metadata reconciliation' {
        BeforeEach {
            $global:ScmKnowledgeTest.files = @(@{
                fileId = 'file-original'
                fileName = $global:ScmKnowledgeTest.handbookName
                metadata = @{ sha256 = $global:ScmKnowledgeTest.handbookHash }
            })
            $global:ScmKnowledgeTest.nextFiles = @()
            $global:ScmKnowledgeTest.nextLink = $null
            $global:ScmKnowledgeTest.failUpload = $false
            $global:ScmKnowledgeTest.afterUploadExtra = $false
            $global:ScmKnowledgeTest.source = @{
                kind = 'file'
                description = 'SCM-OPS-001 synthetic operations handbook'
                fileParameters = @{
                    ingestionParameters = @{
                        embeddingModel = @{ azureOpenAIParameters = @{ resourceUri = 'https://ai-test.openai.azure.com' } }
                    }
                }
            }
            Mock Invoke-WebRequest {
                param($Uri, $Method, $Body, $MaximumRedirection, $Headers)
                $path = ([uri]$Uri).AbsolutePath
                $global:ScmKnowledgeTest.requests.Add(@{ Uri = [string]$Uri; Path = $path; Method = $Method; Redirects = $MaximumRedirection; Headers = $Headers })
                if ($path -like '*/files*') {
                    if ($Method -eq 'GET') {
                        if (([uri]$Uri).Query -like '*page=2*') { return New-TestResponse @{ value = @($global:ScmKnowledgeTest.nextFiles) } }
                        return New-TestResponse @{ value = @($global:ScmKnowledgeTest.files); '@odata.nextLink' = $global:ScmKnowledgeTest.nextLink }
                    }
                    if ($global:ScmKnowledgeTest.failUpload) { throw 'Simulated uncertain upload outcome.' }
                    $parts = @($Body)
                    $metadataPart = @($parts | Where-Object { $_.Headers.ContentDisposition.Name.Trim('"') -eq 'metadata' })[0]
                    $metadata = $metadataPart.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
                    $fileId = if ($Method -eq 'PUT') { 'file-original' } else { 'file-new' }
                    $global:ScmKnowledgeTest.files = @(@{ fileId = $fileId; fileName = $metadata.fileName; metadata = $metadata.metadata })
                    if ($global:ScmKnowledgeTest.afterUploadExtra) {
                        $global:ScmKnowledgeTest.files += @{ fileId = 'file-presenter'; fileName = 'Metso-SCM-Demo-Guide.pdf' }
                    }
                    return New-TestResponse $global:ScmKnowledgeTest.files[0]
                }
                if ($path -eq '/knowledgesources/scm-operations-handbook') {
                    if ($Method -eq 'GET') { return New-TestResponse $global:ScmKnowledgeTest.source }
                    $global:ScmKnowledgeTest.source = $Body | ConvertFrom-Json -AsHashtable
                    return New-TestResponse $global:ScmKnowledgeTest.source
                }
                if ($path -eq '/knowledgebases/scm-operations') {
                    if ($Method -eq 'GET') { return New-TestResponse @{ description = 'SCM-OPS-001 synthetic handbook' } }
                    return New-TestResponse ($Body | ConvertFrom-Json -AsHashtable)
                }
                if ($path -eq '/knowledgebases/scm-operations/retrieve') {
                    return New-TestResponse @{
                        response = @(@{ text = 'SCM-RV-04 SCM-HO-03' })
                        activity = @(@{ type = 'modelQueryPlanning' })
                    }
                }
                throw "Unexpected Search route: $Method $path"
            }
        }

        It 'retains the matching file and verifies actual retrieval without re-uploading' {
            $result = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1')
            $result.FileId | Should -BeExactly 'file-original'
            $result.Sha256 | Should -BeExactly $global:ScmKnowledgeTest.handbookHash
            $result.RetrievalVerified | Should -BeTrue
            @($global:ScmKnowledgeTest.requests | Where-Object { $_.Path -like '*/files*' -and $_.Method -ne 'GET' }).Count | Should -Be 0
            @($global:ScmKnowledgeTest.requests | Where-Object { $_.Path -like '*/retrieve' -and $_.Method -eq 'POST' }).Count | Should -Be 1
            @($global:ScmKnowledgeTest.requests | Where-Object Redirects -ne 0).Count | Should -Be 0
        }

        It 'updates the same file ID when metadata is <Shape>, without a duplicate POST' -ForEach @(
            @{ Shape = 'absent' }, @{ Shape = 'null' }, @{ Shape = 'empty' }, @{ Shape = 'changed' }
        ) {
            switch ($Shape) {
                absent { $global:ScmKnowledgeTest.files[0].Remove('metadata') }
                null { $global:ScmKnowledgeTest.files[0].metadata = $null }
                empty { $global:ScmKnowledgeTest.files[0].metadata = @{} }
                changed { $global:ScmKnowledgeTest.files[0].metadata.sha256 = 'different-hash' }
            }
            $result = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1')
            $result.FileId | Should -BeExactly 'file-original'
            $result.Sha256 | Should -BeExactly $global:ScmKnowledgeTest.handbookHash
            $uploads = @($global:ScmKnowledgeTest.requests | Where-Object { $_.Path -like '*/files*' -and $_.Method -ne 'GET' })
            $uploads.Count | Should -Be 1
            $uploads[0].Method.ToString().ToUpperInvariant() | Should -BeExactly 'PUT'
            $uploads[0].Path | Should -BeExactly "/knowledgesources('scm-operations-handbook')/files('file-original')"
        }

        It 'uploads exactly once when no file exists' {
            $global:ScmKnowledgeTest.files = @()
            $result = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1')
            $result.FileId | Should -BeExactly 'file-new'
            @($global:ScmKnowledgeTest.requests | Where-Object { $_.Path -like '*/files*' -and $_.Method -eq 'POST' }).Count | Should -Be 1
        }

        It 'rejects extra files on the first page without any writes' {
            $global:ScmKnowledgeTest.files += @{ fileId = 'file-presenter'; fileName = 'Metso-SCM-Demo-Guide.pdf' }
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1') } |
                Should -Throw '*Unexpected files*Metso-SCM-Demo-Guide.pdf*file-presenter*'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -ne GET).Count | Should -Be 0
        }

        It 'inspects every page and rejects an unexpected file on a later page' {
            $global:ScmKnowledgeTest.nextLink = 'https://srch-test.search.windows.net/knowledgesources/scm-operations-handbook/files?api-version=2026-08-01-preview&page=2'
            $global:ScmKnowledgeTest.nextFiles = @(@{ fileId = 'file-other'; fileName = 'another-document.pdf' })
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1') } | Should -Throw '*Unexpected files*file-other*'
            @($global:ScmKnowledgeTest.requests | Where-Object { $_.Uri -like '*page=2*' }).Count | Should -Be 1
            @($global:ScmKnowledgeTest.requests | Where-Object Method -ne GET).Count | Should -Be 0
        }

        It 'rejects duplicate handbook filenames instead of silently choosing one' {
            $global:ScmKnowledgeTest.files += @{ fileId = 'file-duplicate'; fileName = $global:ScmKnowledgeTest.handbookName }
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1') } | Should -Throw '*Duplicate handbook*'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -ne GET).Count | Should -Be 0
        }

        It 'does not publish a knowledge base if inventory changes during upload' {
            $global:ScmKnowledgeTest.files = @()
            $global:ScmKnowledgeTest.afterUploadExtra = $true
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1') } | Should -Throw '*Unexpected files*file-presenter*'
            @($global:ScmKnowledgeTest.requests | Where-Object { $_.Path -like '/knowledgebases/*' }).Count | Should -Be 0
        }

        It 'never replays an upload with an unknown outcome' {
            $global:ScmKnowledgeTest.files = @()
            $global:ScmKnowledgeTest.failUpload = $true
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1') } | Should -Throw '*uncertain upload*'
            @($global:ScmKnowledgeTest.requests | Where-Object { $_.Path -like '*/files*' -and $_.Method -eq 'POST' }).Count | Should -Be 1
        }

        It 'rejects an unsafe pagination URL <Url> before sending credentials' -ForEach @(
            @{ Url = 'https://example.invalid/files' }
            @{ Url = 'https://srch-test.search.windows.net:8443/files' }
            @{ Url = 'https://user@srch-test.search.windows.net/files' }
            @{ Url = 'http://srch-test.search.windows.net/files' }
        ) {
            $global:ScmKnowledgeTest.nextLink = $Url
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'publish-knowledge.ps1') } | Should -Throw '*different endpoint*'
            $global:ScmKnowledgeTest.requests.Count | Should -Be 2
        }
    }

    Context 'Existing SRE connector and investigator preservation' {
        BeforeEach {
            $global:ScmKnowledgeTest.storedConnector = $null
            $global:ScmKnowledgeTest.workiqAccount = 'demo@example.invalid'
            $global:ScmKnowledgeTest.workiqStatus = 'Connected'
            $global:ScmKnowledgeTest.workiqBinding = $null
            $global:ScmKnowledgeTest.corruptWorkiqRequest = $false
            $global:ScmKnowledgeTest.workiqReadbackChange = ''
            $global:ScmKnowledgeTest.handler = @{
                name = 'alert-investigator'
                type = 'ExtendedAgent'
                properties = @{
                    instructions = 'Keep original safety guidance.'
                    mcpTools = @('existing_read_tool')
                    mode = 'Review'
                    tools = @('QueryAppInsightsUsingAppId')
                    hooks = @('evidence-checklist')
                }
            }
            $global:ScmKnowledgeTest.originalHandler = Copy-TestObject $global:ScmKnowledgeTest.handler
            Mock Invoke-RestMethod {
                param($Uri, $Method, $Body, $MaximumRedirection)
                $path = ([uri]$Uri).AbsolutePath
                $data = if ($null -ne $Body) { $Body | ConvertFrom-Json -AsHashtable } else { $null }
                $global:ScmKnowledgeTest.requests.Add(@{ Path = $path; Method = $Method; Body = $data; Redirects = $MaximumRedirection })
                $result = if ($path -eq '/api/v2/connectorV2/connections/scm-workiq-managed') {
                    @{ properties = @{
                        connectorName = 'workiqmcp'
                        overallStatus = $global:ScmKnowledgeTest.workiqStatus
                        authenticatedUser = @{ name = $global:ScmKnowledgeTest.workiqAccount }
                    } }
                } elseif ($path -eq '/api/v2/connectorV2/mcpservers') {
                    @{ value = @($global:ScmKnowledgeTest.workiqBinding | Where-Object { $_ }) }
                } elseif ($path -like '*/accessPolicies/scm-workiq-managed-policy' -and $Method -eq 'PUT') {
                    @{ name = 'scm-workiq-managed-policy' }
                } elseif ($path -eq '/api/v2/connectorV2/mcpservers/scm-workiq-managed') {
                    if ($Method -eq 'PUT') {
                        $global:ScmKnowledgeTest.workiqBinding = Copy-TestObject $data
                        $global:ScmKnowledgeTest.workiqBinding.name = 'scm-workiq-managed'
                    }
                    $response = Copy-TestObject $global:ScmKnowledgeTest.workiqBinding
                    if (@($response.runtimeMcpConfiguration.requireApprovalTools).Count -eq 0) {
                        $response.Remove('runtimeMcpConfiguration')
                    }
                    if ($global:ScmKnowledgeTest.corruptWorkiqRequest) {
                        $response.properties.connectors[0].operations[0].userParameters[0].value.params.name = 'ask'
                    }
                    $operation = $response.properties.connectors[0].operations[0]
                    $request = $operation.userParameters[0].value
                    switch ($global:ScmKnowledgeTest.workiqReadbackChange) {
                        reordered {
                            $operation.userParameters = @([ordered]@{
                                value = [ordered]@{
                                    params = [ordered]@{ arguments = $request.params.arguments; name = $request.params.name }
                                    method = $request.method; id = $request.id; jsonrpc = $request.jsonrpc
                                }
                                name = 'queryRequest'
                            })
                        }
                        changedCase { $request.params.name = 'Retrieve' }
                        objectInsteadOfArray { $operation.userParameters = $operation.userParameters[0] }
                        addedParameter { $operation.userParameters += @{ name = 'other'; value = 'unexpected' } }
                        addedAgentParameter { $operation.agentParameters = @(@{ name = 'queryRequest' }) }
                    }
                    $response
                } elseif ($path -eq '/api/v1/mcp/connections/list') {
                    @(@{ name = 'scm-workiq-managed'; tools = @(@{ name = 'scm-workiq-managed_workiqmcp_InvokeWorkIQMCP' }) })
                } elseif ($path -like '*/connectors/listSecrets') {
                    @{ value = @($global:ScmKnowledgeTest.storedConnector | Where-Object { $_ }) }
                } elseif ($path -like '*/testconnection') {
                    @{ success = $true; tools = @(@{ name = 'knowledge_base_retrieve' }) }
                } elseif ($path -like '*/scm-foundry-iq/tools') {
                    @{ connectionStatus = 'Connected'; tools = @(@{ name = 'knowledge_base_retrieve' }) }
                } elseif ($path -like '*/connectors/scm-foundry-iq' -and $Method -eq 'PUT') {
                    $global:ScmKnowledgeTest.storedConnector = Copy-TestObject $data
                    $global:ScmKnowledgeTest.storedConnector
                } elseif ($path -like '*/agents/alert-investigator') {
                    if ($Method -eq 'PATCH') {
                        foreach ($key in $data.properties.Keys) { $global:ScmKnowledgeTest.handler.properties[$key] = $data.properties[$key] }
                    }
                    $global:ScmKnowledgeTest.handler
                } else {
                    throw "Unexpected SRE route: $Method $path"
                }
                ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $result -Depth 40)
            }
        }

        It 'uses only the derived Search endpoint and original identity, and is repeatable' {
            $first = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1')
            $second = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1')
            $first.Status | Should -BeExactly 'Connected'
            $second.Endpoint | Should -BeExactly $global:ScmKnowledgeTest.environment.KNOWLEDGE_MCP_ENDPOINT
            $global:ScmKnowledgeTest.storedConnector.properties.identity | Should -BeExactly $global:ScmKnowledgeTest.identityId
            $settings = $global:ScmKnowledgeTest.storedConnector.properties.extendedProperties
            $settings.endpoint | Should -BeExactly $global:ScmKnowledgeTest.environment.KNOWLEDGE_MCP_ENDPOINT
            $settings.authType | Should -BeExactly 'AzureARM'
            $settings.armScope | Should -BeExactly 'https://search.azure.com/.default'
            $settings.selectedTools | Should -Be @('knowledge_base_retrieve')
            $global:ScmKnowledgeTest.handler.properties.mcpTools | Should -Contain 'existing_read_tool'
            @($global:ScmKnowledgeTest.handler.properties.mcpTools | Where-Object { $_ -eq 'scm-foundry-iq_knowledge_base_retrieve' }).Count | Should -Be 1
            ([regex]::Matches($global:ScmKnowledgeTest.handler.properties.instructions, '<!-- scm-foundry-iq:start -->')).Count | Should -Be 1
            $global:ScmKnowledgeTest.handler.properties.instructions | Should -BeLike 'Keep original safety guidance.*'
            foreach ($key in @('mode', 'tools', 'hooks')) {
                ($global:ScmKnowledgeTest.handler.properties[$key] | ConvertTo-Json) |
                    Should -BeExactly ($global:ScmKnowledgeTest.originalHandler.properties[$key] | ConvertTo-Json)
            }
            $patches = @($global:ScmKnowledgeTest.requests | Where-Object Method -eq PATCH)
            foreach ($patch in $patches) { @($patch.Body.properties.Keys | Sort-Object) | Should -Be @('instructions', 'mcpTools') }
            @($global:ScmKnowledgeTest.requests | Where-Object Redirects -ne 0).Count | Should -Be 0
        }

        It 'refuses to overwrite an unrelated connector' {
            $global:ScmKnowledgeTest.storedConnector = @{
                name = 'scm-foundry-iq'
                properties = @{ dataConnectorType = 'Mcp'; extendedProperties = @{ endpoint = 'https://another.search.windows.net/mcp' } }
            }
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') } | Should -Throw '*unrelated connector*'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -ne GET).Count | Should -Be 0
        }

        It 'adds only fixed email retrieval and preserves investigator safeguards across repeated setup' {
            $arguments = @{ WorkIqConnectionName = 'scm-workiq-managed'; WorkIqAccount = 'demo@example.invalid' }
            $first = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') @arguments
            $second = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') @arguments
            $first.WorkIqHistoryTool | Should -BeExactly 'scm-workiq-managed_workiqmcp_InvokeWorkIQMCP'
            $second.WorkIqRetrievalVerified | Should -BeFalse
            $binding = $global:ScmKnowledgeTest.workiqBinding
            $operation = $binding.properties.connectors[0].operations[0]
            $operation.name | Should -BeExactly 'InvokeWorkIQMCP'
            @($operation.agentParameters).Count | Should -Be 0
            @($operation.userParameters).Count | Should -Be 1
            $operation.userParameters[0].name | Should -BeExactly 'queryRequest'
            $request = $operation.userParameters[0].value
            $request.method | Should -BeExactly 'tools/call'
            $request.params.name | Should -BeExactly 'retrieve'
            $request.params.arguments.strategy | Should -BeExactly 'grounding'
            @($request.params.arguments.capabilities).Count | Should -Be 1
            $request.params.arguments.capabilities[0].name | Should -BeExactly 'Email'
            $request.params.arguments.query | Should -Not -Match 'SCM-INC-017|5432|NSG|PostgreSqlFaultInjection'
            @($binding.runtimeMcpConfiguration.requireApprovalTools).Count | Should -Be 0
            $instructions = $global:ScmKnowledgeTest.handler.properties.instructions
            ([regex]::Matches($instructions, '<!-- scm-workiq-history:start -->')).Count | Should -Be 1
            $instructions | Should -Match 'automatically invoke'
            $instructions | Should -Match 'operator-controlled'
            $instructions | Should -Match 'at most one identical retry'
            $instructions | Should -Match 'wait at least 30 seconds'
            $instructions | Should -Match 'Do not retry authorization or policy denials'
            $instructions | Should -Match 'Do not invoke\s+mutation tools'
            $instructions | Should -Match 'overrides\s+earlier workflow steps'
            $instructions | Should -Not -Match '__WORKIQ_TOOL__'
            @($global:ScmKnowledgeTest.handler.properties.mcpTools | Where-Object { $_ -like '*workiq*' }).Count | Should -Be 1
            foreach ($key in @('mode', 'tools', 'hooks')) {
                ($global:ScmKnowledgeTest.handler.properties[$key] | ConvertTo-Json) |
                    Should -BeExactly ($global:ScmKnowledgeTest.originalHandler.properties[$key] | ConvertTo-Json)
            }
        }

        It 'rejects incorrect Work IQ identity or incomplete authorization before any writes' -ForEach @(
            @{ Account = 'other@example.invalid'; Status = 'Connected' }
            @{ Account = 'demo@example.invalid'; Status = 'Error' }
        ) {
            $global:ScmKnowledgeTest.workiqAccount = $Account
            $global:ScmKnowledgeTest.workiqStatus = $Status
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') `
                -WorkIqConnectionName scm-workiq-managed -WorkIqAccount demo@example.invalid } |
                Should -Throw '*explicitly approved account*'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -ne GET).Count | Should -Be 0
        }

        It 'fails closed on missing Work IQ account display without treating it as failed consent' -ForEach @(
            @{ Account = '' }
            @{ Account = $null }
        ) {
            $global:ScmKnowledgeTest.workiqAccount = $Account
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') `
                -WorkIqConnectionName scm-workiq-managed -WorkIqAccount demo@example.invalid } |
                Should -Throw '*authenticated-account display is empty*'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -ne GET).Count | Should -Be 0
        }

        It 'refuses another managed Work IQ binding without overwriting it' {
            $global:ScmKnowledgeTest.workiqBinding = @{
                name = 'someone-elses-binding'
                properties = @{ connectors = @(@{ name = 'workiqmcp' }) }
            }
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') `
                -WorkIqConnectionName scm-workiq-managed -WorkIqAccount demo@example.invalid } |
                Should -Throw '*unrelated managed connector binding*'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -ne GET).Count | Should -Be 0
        }

        It 'does not attach a gateway request whose locked read-only operation changed' {
            $global:ScmKnowledgeTest.corruptWorkiqRequest = $true
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') `
                -WorkIqConnectionName scm-workiq-managed -WorkIqAccount demo@example.invalid } |
                Should -Throw '*fully locked read-only*'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -eq PATCH).Count | Should -Be 0
        }

        It 'accepts reordered object keys in the locked Work IQ request readback' {
            $global:ScmKnowledgeTest.workiqReadbackChange = 'reordered'
            $result = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') `
                -WorkIqConnectionName scm-workiq-managed -WorkIqAccount demo@example.invalid
            $result.WorkIqHistoryTool | Should -BeExactly 'scm-workiq-managed_workiqmcp_InvokeWorkIQMCP'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -eq PATCH).Count | Should -Be 1
        }

        It 'rejects a locked request with <Change>' -ForEach @(
            @{ Change = 'changedCase' }
            @{ Change = 'objectInsteadOfArray' }
            @{ Change = 'addedParameter' }
            @{ Change = 'addedAgentParameter' }
        ) {
            $global:ScmKnowledgeTest.workiqReadbackChange = $Change
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') `
                -WorkIqConnectionName scm-workiq-managed -WorkIqAccount demo@example.invalid } |
                Should -Throw '*fully locked read-only*'
            @($global:ScmKnowledgeTest.requests | Where-Object Method -eq PATCH).Count | Should -Be 0
        }

        It 'preserves existing native binding policies and disabled API-key authentication' {
            $arguments = @{ WorkIqConnectionName = 'scm-workiq-managed'; WorkIqAccount = 'demo@example.invalid' }
            $null = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') @arguments
            $global:ScmKnowledgeTest.workiqBinding.properties.policies = @(@{ name = 'existing-policy'; value = 'retain' })
            $global:ScmKnowledgeTest.workiqBinding.properties.disableApiKeyAuth = $true
            $null = & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') @arguments
            $global:ScmKnowledgeTest.workiqBinding.properties.policies[0].name | Should -BeExactly 'existing-policy'
            $global:ScmKnowledgeTest.workiqBinding.properties.policies[0].value | Should -BeExactly 'retain'
            $global:ScmKnowledgeTest.workiqBinding.properties.disableApiKeyAuth | Should -BeTrue
        }

        It 'requires both Work IQ connection and explicitly approved account' {
            { & (Join-Path $global:ScmKnowledgeTest.knowledgeRoot 'connect-sre.ps1') -WorkIqConnectionName scm-workiq-managed } |
                Should -Throw '*Supply both*'
            Should -Invoke az -Times 0 -Exactly
        }
    }
}
