#requires -Version 7.0
BeforeAll {
    $script:configure = Join-Path $PSScriptRoot '..\scripts\scm-auto-repair.ps1'
    function az { throw 'Tests must mock Azure CLI calls.' }
}

Describe 'In-place SCM automatic-repair configuration' {
    BeforeEach {
        $scope = '/subscriptions/db4948d5-b90c-47d4-91b5-d8c4c43493d2/resourceGroups/rg-flu-xzlxm7twvdxao'
        $originalSafetyBoundary = @(
            'Workload fault injection and reset belong to the lab operator. Never change'
            'workload resources. GitHub issues and email require explicit opt-in,'
            'a trusted destination, and approval for each external write.'
        ) -join "`n"
        $global:ScmRepairTestState = @{
            commands = [Collections.Generic.List[string]]::new()
            writes = [Collections.Generic.List[string]]::new()
            identity = '268b4cbb-6fd1-4aa9-8094-171be6d43cce'
            etag = '"test-etag"'
            role = $null
            assignment = $null
            scope = $scope
            resources = @{
                '/api/v2/extendedAgent/agents/alert-investigator' = @{
                    name = 'alert-investigator'; type = 'ExtendedAgent'
                    properties = @{
                        instructions = "Investigate using current evidence.`n<!-- scm-foundry-iq:start -->`nOriginal handbook instructions`n<!-- scm-foundry-iq:end -->`n<!-- scm-workiq-history:start -->`nOriginal history instructions`n<!-- scm-workiq-history:end -->"
                        tools = @('ReadFile', 'RunAzCliReadCommands')
                        mcpTools = @('scm-foundry-iq_knowledge_base_retrieve', 'scm-workiq-managed_workiqmcp_InvokeWorkIQMCP')
                        hooks = $null; handoffs = @(); llmModelName = 'preserve-operator-choice'
                    }
                }
                '/api/v2/extendedAgent/incidentFilters/alert-investigation' = @{
                    name = 'alert-investigation'; type = 'IncidentFilter'
                    properties = @{
                        handlingAgent = 'alert-investigator'; incidentPlatform = 'AzMonitor'
                        titleContains = 'flu'; agentMode = 'Review'; etag = '"plan-etag"'
                        mergeEnabled = $false; isEnabled = $true; priorities = @('Sev1', 'Sev2')
                        maxAutomatedInvestigationAttempts = 3; updatedAt = 'before'; configurationWarning = $null
                    }
                }
                '/api/v2/extendedAgent/commonPrompts/onboardinglab-safety' = @{
                    name = 'onboardinglab-safety'; type = 'CommonPrompt'
                    properties = @{ prompt = "Retain the original safety guidance.`n`n$originalSafetyBoundary" }
                }
                '/api/v2/extendedAgent/skills/azure-monitor-rca' = @{
                    name = 'azure-monitor-rca'; type = 'Skill'
                    properties = @{
                        description = 'Read-only investigation'
                        tools = @(); additionalFiles = @()
                        skillContent = 'Remain read-only for workload resources, even when a learner requests remediation. The lab operator owns fault injection and reset. After an authorized mitigation performed by an authorized operator, validate with fresh telemetry.'
                    }
                }
                '/api/v2/agent/settings/global' = @{
                    permissions = @{
                        allow = @('RunAzCliReadCommands')
                        ask = @('RunAzCliWriteCommands', 'CreateFile')
                        deny = @('RunInTerminal')
                    }
                    unrelatedSetting = 'retain-me'
                }
            }
        }
        Mock Write-Host {}
        Mock az {
            $global:LASTEXITCODE = 0
            $state = $global:ScmRepairTestState
            $command = $args -join ' '
            $state.commands.Add($command)
            if ($command -like 'account get-access-token *') { return 'synthetic-test-token' }
            if ($command -like 'resource show *') {
                return (@{
                    location = 'francecentral'
                    identity = @{ userAssignedIdentities = @{ identityResource = @{ principalId = $state.identity } } }
                } | ConvertTo-Json -Depth 8)
            }
            if ($command -like 'role definition list *') {
                if ($state.role) { return '[' + ($state.role | ConvertTo-Json -Depth 10 -Compress) + ']' }
                return '[]'
            }
            if ($command -like 'role definition create *') {
                $index = [Array]::IndexOf($args, '--role-definition')
                $request = Get-Content -LiteralPath $args[$index + 1] -Raw | ConvertFrom-Json -AsHashtable
                $state.role = @{
                    id = "$($state.scope)/providers/Microsoft.Authorization/roleDefinitions/test-role"
                    assignableScopes = $request.AssignableScopes
                    permissions = @(@{
                        actions = $request.Actions; notActions = @(); dataActions = @(); notDataActions = @()
                    })
                }
                return $state.role | ConvertTo-Json -Depth 10
            }
            if ($command -like 'role assignment list *') {
                if ($state.assignment) { return '[' + ($state.assignment | ConvertTo-Json -Compress) + ']' }
                return '[]'
            }
            if ($command -like 'role assignment create *') {
                $index = [Array]::IndexOf($args, '--scope')
                $state.assignment = @{
                    principalId = $state.identity
                    roleDefinitionId = $state.role.id
                    scope = $args[$index + 1]
                }
                return $state.assignment | ConvertTo-Json
            }
            throw "Unexpected CLI call: $command"
        }
        Mock Invoke-WebRequest {
            param($Uri, $Method)
            if ($Method -ne 'Get') { throw 'Only GET is expected.' }
            $path = ([Uri]$Uri).AbsolutePath
            $state = $global:ScmRepairTestState
            if (-not $state.resources.ContainsKey($path)) { throw "Unexpected resource: $path" }
            $resource = $state.resources[$path] | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
            if ($path -eq '/api/v2/extendedAgent/agents/alert-investigator' -and $resource.properties.hooks) {
                foreach ($hook in $resource.properties.hooks.PreToolUse) {
                    $hook['prompt'] = $null
                    $hook['command'] = $null
                    $hook['model'] = $null
                    $hook['maxRejections'] = $null
                    $hook['sources'] = $null
                }
            }
            @{ Content = $resource | ConvertTo-Json -Depth 50; Headers = @{ ETag = @($state.etag) } }
        }
        Mock Invoke-RestMethod {
            param($Uri, $Method, $Body, $Headers)
            $path = ([Uri]$Uri).AbsolutePath
            $state = $global:ScmRepairTestState
            if (-not $state.resources.ContainsKey($path)) { throw "No new resource may be created: $path" }
            $request = $Body | ConvertFrom-Json -AsHashtable
            $state.writes.Add("$Method $path")
            if ($path -eq '/api/v2/agent/settings/global') {
                $Headers['If-Match'] | Should -Be '"test-etag"'
                $state.resources[$path] = $request
            } else {
                foreach ($entry in $request.properties.GetEnumerator()) {
                    $state.resources[$path].properties[$entry.Key] = $entry.Value
                }
            }
        }
    }

    It 'previews without cloud calls' {
        & $script:configure
        $global:ScmRepairTestState.commands.Count | Should -Be 0
        $global:ScmRepairTestState.writes.Count | Should -Be 0
    }

    It 'updates only existing configuration and grants the child-rule role before enabling autonomy' {
        $result = & $script:configure -Action apply -BackupDirectory $TestDrive
        $state = $global:ScmRepairTestState
        $result.Mode | Should -Be 'Autonomous'
        $state.writes[-1] | Should -Be 'PATCH /api/v2/extendedAgent/incidentFilters/alert-investigation'
        $state.assignment.scope | Should -Be "$($state.scope)/providers/Microsoft.Network/networkSecurityGroups/flu-xzlxm7twvdxao-app-nsg/securityRules/PostgreSqlFaultInjection"
        $state.resources['/api/v2/agent/settings/global'].unrelatedSetting | Should -Be 'retain-me'
        $state.resources['/api/v2/agent/settings/global'].permissions.deny | Should -Contain 'RunAzCliWriteCommands'
        $agent = $state.resources['/api/v2/extendedAgent/agents/alert-investigator'].properties
        $agent.llmModelName | Should -Be 'preserve-operator-choice'
        $agent.hooks.PreToolUse[0].failMode | Should -Be 'block'
        $agent.hooks.PreToolUse[0].matcher | Should -Be '*'
        $agent.tools | Should -Contain 'RunAzCliWriteCommands'
        $agent.mcpTools.Count | Should -Be 2
        $state.commands | Where-Object { $_ -like 'deployment *' -or $_ -like 'postgres *' } | Should -BeNullOrEmpty
        $skill = $state.resources['/api/v2/extendedAgent/skills/azure-monitor-rca'].properties
        $skill.skillContent | Should -Match 'this skill does not enable that exception'
        $skill.description | Should -Be 'Read-only investigation'
        $skill.tools.Count | Should -Be 0
        (Get-ChildItem -LiteralPath $result.BackupDirectory -Filter '*-before.json').Count | Should -Be 5
    }

    It 'can reapply its owned guard without replacing other settings or duplicating RBAC' {
        & $script:configure -Action apply -BackupDirectory $TestDrive | Out-Null
        & $script:configure -Action apply -BackupDirectory $TestDrive | Out-Null
        @($global:ScmRepairTestState.commands | Where-Object { $_ -like 'role definition create *' }).Count | Should -Be 1
        @($global:ScmRepairTestState.commands | Where-Object { $_ -like 'role assignment create *' }).Count | Should -Be 1
    }

    It 'preserves operator guidance around the recovery boundary across repeated setup' {
        $safety = $global:ScmRepairTestState.resources['/api/v2/extendedAgent/commonPrompts/onboardinglab-safety'].properties
        $safety.prompt = "Never inspect unrelated subscriptions.`n`n$($safety.prompt)`n`nNever modify resource locks."
        & $script:configure -Action apply -BackupDirectory $TestDrive | Out-Null
        $updated = $safety.prompt
        $updated | Should -BeLike "Never inspect unrelated subscriptions.*"
        $updated | Should -Match 'Retain the original safety guidance\.'
        $updated | Should -BeLike '*Never modify resource locks.'
        $updated | Should -Match "guard's exact NSG repair"
        & $script:configure -Action apply -BackupDirectory $TestDrive | Out-Null
        $safety.prompt | Should -BeExactly $updated
    }

    It 'rejects a <Shape> recovery boundary before any configuration writes' -ForEach @(
        @{ Shape = 'missing' }
        @{ Shape = 'customized' }
        @{ Shape = 'duplicated' }
    ) {
        $safety = $global:ScmRepairTestState.resources['/api/v2/extendedAgent/commonPrompts/onboardinglab-safety'].properties
        switch ($Shape) {
            missing { $safety.prompt = 'Custom safety guidance with no recognized recovery boundary.' }
            customized { $safety.prompt = $safety.prompt.Replace('Never change', 'Never read or change') }
            duplicated { $safety.prompt += "`n`n$($safety.prompt)" }
        }
        { & $script:configure -Action apply -BackupDirectory $TestDrive } | Should -Throw '*safety recovery boundary*'
        $global:ScmRepairTestState.writes.Count | Should -Be 0
    }

    It 'does not write configuration for a different managed identity' {
        $global:ScmRepairTestState.identity = 'different-identity'
        { & $script:configure -Action apply -BackupDirectory $TestDrive } | Should -Throw '*managed identity differs*'
        $global:ScmRepairTestState.writes.Count | Should -Be 0
    }

    It 'fails before writes if settings lack an ETag' {
        $global:ScmRepairTestState.etag = ''
        { & $script:configure -Action apply -BackupDirectory $TestDrive } | Should -Throw '*required ETag*'
        $global:ScmRepairTestState.writes.Count | Should -Be 0
    }

    It 'does not overwrite an unrelated hook' {
        $global:ScmRepairTestState.resources['/api/v2/extendedAgent/agents/alert-investigator'].properties.hooks = @{
            PreToolUse = @(@{ script = 'an existing unrelated guard' })
        }
        { & $script:configure -Action apply -BackupDirectory $TestDrive } | Should -Throw '*unrelated PreToolUse hook*'
        $global:ScmRepairTestState.writes.Count | Should -Be 0
    }
}

AfterAll {
    Remove-Variable -Name ScmRepairTestState -Scope Global -ErrorAction SilentlyContinue
}
