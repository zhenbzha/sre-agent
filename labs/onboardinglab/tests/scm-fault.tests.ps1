#requires -Version 7.0
# Run with Pester 5 or later.
BeforeAll {
    $script:wrapper = Join-Path $PSScriptRoot '..\scripts\scm-fault.ps1'
    function az { throw 'Tests must mock Azure CLI calls.' }
    function azd { throw 'The fixed-target wrapper must not consult the selected azd environment.' }
}

Describe 'Dedicated SCM fault shortcut' {
    BeforeEach {
        $global:ScmFaultTestState = @{
            commands = [System.Collections.Generic.List[string]]::new()
            ruleId = '/subscriptions/db4948d5-b90c-47d4-91b5-d8c4c43493d2/resourceGroups/rg-flu-xzlxm7twvdxao/providers/microsoft.insights/scheduledqueryrules/flu-xzlxm7twvdxao-checkout-failures'
            unresolvedAlert = $false
            deploymentFailed = $false
        }
        Mock Write-Host {}
        Mock az {
            $global:LASTEXITCODE = 0
            $command = $args -join ' '
            $global:ScmFaultTestState.commands.Add($command)
            if ($command -like 'account get-access-token *') { return 'synthetic-test-token' }
            if ($command -like 'deployment group create *') {
                if ($global:ScmFaultTestState.deploymentFailed) { $global:LASTEXITCODE = 1 }
                return
            }
            throw "Unexpected Azure CLI call: $command"
        }
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Method -ne 'Get' -or $Uri -notlike 'https://management.azure.com/subscriptions/db4948d5-b90c-47d4-91b5-d8c4c43493d2/providers/Microsoft.AlertsManagement/alerts?*') {
                throw "Unexpected REST call: $Method $Uri"
            }
            $alerts = @()
            if ($global:ScmFaultTestState.unresolvedAlert) {
                $alerts = @(@{
                    properties = @{
                        essentials = @{
                            alertRule = $global:ScmFaultTestState.ruleId
                            alertState = 'New'
                            monitorCondition = 'Fired'
                        }
                    }
                })
            }
            return @{ value = $alerts }
        }
    }

    It 'forwards <Action> to the existing helper with the fixed demo target from another directory' -TestCases @(
        @{ Action = 'inject'; FaultValue = 'true'; CliCalls = 2; AlertReads = 1 }
        @{ Action = 'reset'; FaultValue = 'false'; CliCalls = 1; AlertReads = 0 }
    ) {
        param($Action, $FaultValue, $CliCalls, $AlertReads)
        Push-Location $TestDrive
        try {
            & $script:wrapper $Action
            (Get-Location).Path | Should -Be $TestDrive
        } finally {
            Pop-Location
        }
        $global:ScmFaultTestState.commands.Count | Should -Be $CliCalls
        $deployments = @($global:ScmFaultTestState.commands | Where-Object { $_ -like 'deployment group create *' })
        $deployments.Count | Should -Be 1
        $command = $deployments[0]
        foreach ($expected in @(
            '--subscription db4948d5-b90c-47d4-91b5-d8c4c43493d2',
            '--resource-group rg-flu-xzlxm7twvdxao',
            '--name onboardinglab-fault',
            'networkSecurityGroupName=flu-xzlxm7twvdxao-app-nsg',
            "injectDatabaseFault=$FaultValue"
        )) {
            $command | Should -Match ([regex]::Escape($expected))
        }
        $template = (Resolve-Path (Join-Path $PSScriptRoot '..\fault.bicep')).Path
        $command | Should -Match ([regex]::Escape("--template-file $template"))
        Should -Invoke Invoke-RestMethod -Times $AlertReads -Exactly
    }

    It 'also accepts the explicit Action parameter' {
        & $script:wrapper -Action reset
        $global:ScmFaultTestState.commands.Count | Should -Be 1
        $global:ScmFaultTestState.commands[0] | Should -Match 'injectDatabaseFault=false'
    }

    It 'rejects unsupported actions before contacting Azure' {
        { & $script:wrapper delete } | Should -Throw '*ValidateSet*'
        $global:ScmFaultTestState.commands.Count | Should -Be 0
    }

    It 'does not allow a different subscription to override the dedicated target' {
        { & $script:wrapper reset -Subscription '11111111-1111-1111-1111-111111111111' } |
            Should -Throw '*parameter*Subscription*'
        $global:ScmFaultTestState.commands.Count | Should -Be 0
    }

    It 'preserves the existing fired-alert guard instead of injecting again' {
        $global:ScmFaultTestState.unresolvedAlert = $true
        { & $script:wrapper inject } | Should -Throw '*prior checkout alert is still fired*'
        $global:ScmFaultTestState.commands.Count | Should -Be 1
        $global:ScmFaultTestState.commands[0] | Should -Match '^account get-access-token '
    }

    It 'propagates a failed reset rather than reporting success' {
        $global:ScmFaultTestState.deploymentFailed = $true
        { & $script:wrapper reset } | Should -Throw '*Database fault rule deployment failed*'
        $global:ScmFaultTestState.commands.Count | Should -Be 1
    }

    AfterAll { Remove-Variable ScmFaultTestState -Scope Global }
}
