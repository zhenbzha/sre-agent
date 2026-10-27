#requires -Version 7.0
# Run with Pester 5 or later.
BeforeAll {
    $script:initializer = Join-Path $PSScriptRoot '..\ticketingapp-source\initialize-database.ps1'
    function az { throw 'Tests must mock Azure CLI calls.' }
    function Invoke-TestInitializer([switch]$MigrateDemoPlants) {
        & $script:initializer -Subscription '11111111-1111-1111-1111-111111111111' `
            -ResourceGroup 'rg-test' -AppName 'app-test' @PSBoundParameters
    }
}

Describe 'Private database initialization readiness and completion' {
    BeforeEach {
        $global:ScmInitTestState = @{
            deploymentReads = 0; healthReads = 0; execCalls = 0
            deploymentFailed = $false; deploymentStuck = $false; healthStuck = $false
            changedDeployment = $false; completionMissing = $false
            migration = $false; unconfirmedMigration = $false; execCommand = ''
        }
        Mock Start-Sleep {}
        Mock Write-Host {}
        Mock az {
            $global:LASTEXITCODE = 0
            $command = $args -join ' '
            if ($command -like 'webapp show *') {
                return '{"tags":{"workload":"onboardinglab","workloadOption":"app-service-postgresql"},"enabledHostNames":["app-test.scm.azurewebsites.net"],"defaultHostName":"app-test.azurewebsites.net"}'
            }
            if ($command -like 'account get-access-token *') { return 'synthetic-test-token' }
            if ($command -like 'webapp list-instances *') { return '[{"name":"instance-1"}]' }
            if ($command -like 'webapp exec *') {
                if ($global:ScmInitTestState.deploymentReads -lt 3 -or $global:ScmInitTestState.healthReads -lt 2) {
                    throw 'Initialization was submitted before readiness.'
                }
                $global:ScmInitTestState.execCalls++
                $global:ScmInitTestState.execCommand = $command
                return
            }
            throw "Unexpected Azure CLI call: $command"
        }
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -notmatch '/api/deployments/') { throw 'Unexpected REST call.' }
            $global:ScmInitTestState.deploymentReads++
            $status = if ($global:ScmInitTestState.deploymentFailed) { 3 }
                elseif ($global:ScmInitTestState.deploymentStuck -or $global:ScmInitTestState.deploymentReads -lt 3) { 1 } else { 4 }
            $id = if ($global:ScmInitTestState.changedDeployment -and $global:ScmInitTestState.deploymentReads -gt 3) { 'another-deployment' } else { 'deployment-1' }
            return @{ id = $id; status = $status; complete = ($status -in @(3, 4)) }
        }
        Mock Invoke-WebRequest {
            param($Uri)
            if ($Uri -like '*/healthz') {
                $global:ScmInitTestState.healthReads++
                if ($global:ScmInitTestState.healthStuck -or $global:ScmInitTestState.healthReads -lt 2) { return @{ StatusCode = 503; Content = 'Starting' } }
                return @{ StatusCode = 200; Content = '{"status":"healthy"}' }
            }
            if ($Uri -like '*.exit') {
                if ($global:ScmInitTestState.completionMissing) { return @{ StatusCode = 404; Content = '' } }
                return @{ StatusCode = 200; Content = [Text.Encoding]::UTF8.GetBytes('0') }
            }
            if ($Uri -like '*.log') {
                $content = if ($global:ScmInitTestState.migration) {
                    if ($global:ScmInitTestState.unconfirmedMigration) { '{"migrated":false}' }
                    else { '{"migrated":true,"updated":41}' }
                } else { '{"initialized":true,"inserted":3}' }
                return @{ StatusCode = 200; Content = $content }
            }
            throw 'Unexpected web request.'
        }
    }

    It 'waits for deployment and health, then submits exactly once and verifies completion' {
        $result = Invoke-TestInitializer
        $result.initialized | Should -BeTrue
        $result.inserted | Should -Be 3
        $global:ScmInitTestState.execCalls | Should -Be 1
        Should -Invoke Start-Sleep -Times 3 -Exactly
    }

    It 'does not initialize after a failed deployment' {
        $global:ScmInitTestState.deploymentFailed = $true
        { Invoke-TestInitializer } | Should -Throw '*deployment*failed*'
        $global:ScmInitTestState.execCalls | Should -Be 0
    }

    It 'runs the explicitly requested migration once and verifies its real completion' {
        $global:ScmInitTestState.migration = $true
        $result = Invoke-TestInitializer -MigrateDemoPlants
        $result.migrated | Should -BeTrue
        $result.updated | Should -Be 41
        $global:ScmInitTestState.execCalls | Should -Be 1
        $global:ScmInitTestState.execCommand | Should -Match 'node initialize.js --migrate-demo-plants'
    }

    It 'rejects an unconfirmed migration rather than reporting initialization as success' {
        $global:ScmInitTestState.migration = $true
        $global:ScmInitTestState.unconfirmedMigration = $true
        { Invoke-TestInitializer -MigrateDemoPlants } | Should -Throw '*migration was not confirmed*'
        $global:ScmInitTestState.execCalls | Should -Be 1
    }

    It 'does not permit a migration and a request lookup in the same invocation' {
        { & $script:initializer -Subscription '11111111-1111-1111-1111-111111111111' `
            -ResourceGroup 'rg-test' -AppName 'app-test' -RequestId 50 -MigrateDemoPlants } |
            Should -Throw '*Parameter set*'
        $global:ScmInitTestState.execCalls | Should -Be 0
    }

    It 'bounds deployment waiting without submitting a database operation' {
        $global:ScmInitTestState.deploymentStuck = $true
        { Invoke-TestInitializer } | Should -Throw '*not complete after the bounded wait*'
        $global:ScmInitTestState.execCalls | Should -Be 0
        Should -Invoke Start-Sleep -Times 60 -Exactly
    }

    It 'bounds startup waiting independently of database availability' {
        $global:ScmInitTestState.healthStuck = $true
        { Invoke-TestInitializer } | Should -Throw '*startup did not become healthy*'
        $global:ScmInitTestState.execCalls | Should -Be 0
    }

    It 'refuses initialization if a different deployment supersedes the observed build' {
        $global:ScmInitTestState.changedDeployment = $true
        { Invoke-TestInitializer } | Should -Throw '*Deployment changed*'
        $global:ScmInitTestState.execCalls | Should -Be 0
    }

    It 'does not resubmit an accepted operation whose completion is unknown' {
        $global:ScmInitTestState.completionMissing = $true
        { Invoke-TestInitializer } | Should -Throw '*completion is unknown*'
        $global:ScmInitTestState.execCalls | Should -Be 1
    }
    AfterAll { Remove-Variable ScmInitTestState -Scope Global }
}
