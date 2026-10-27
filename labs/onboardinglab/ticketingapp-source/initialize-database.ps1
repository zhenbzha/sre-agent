#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Initialize')]
param(
    [Parameter(Mandatory)][guid]$Subscription,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.()-]+$')][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]+$')][string]$AppName,
    [Parameter(Mandatory, ParameterSetName = 'Read')]
    [ValidatePattern('^[1-9][0-9]{0,18}$')][string]$RequestId,
    [Parameter(Mandatory, ParameterSetName = 'Migrate')]
    [switch]$MigrateDemoPlants
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$app = az webapp show --subscription $Subscription --resource-group $ResourceGroup --name $AppName -o json | ConvertFrom-Json
if ($app.tags.workload -ne 'onboardinglab' -or $app.tags.workloadOption -ne 'app-service-postgresql') {
    throw 'Database operations require the explicitly selected onboarding PostgreSQL workload.'
}
$scm = @($app.enabledHostNames | Where-Object { $_ -match '\.scm\.' })
if ($scm.Count -ne 1) { throw 'Could not identify the application SCM endpoint.' }
$token = az account get-access-token --subscription $Subscription --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token" }
$scmUrl = "https://$($scm[0])"
# azd can stop waiting before a long Oryx build completes. Pin and observe that deployment.
$deployment = Invoke-RestMethod "$scmUrl/api/deployments/latest" -Headers $headers -TimeoutSec 30
if ($deployment.id -notmatch '^[A-Za-z0-9-]+$') { throw 'No current deployment could be identified.' }
$deploymentId = $deployment.id
$ready = $false
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    if ($deployment.status -eq 3) { throw "Application deployment $deploymentId failed. Inspect its Kudu logs." }
    if ($deployment.complete -eq $true -and $deployment.status -eq 4) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 10
    $deployment = Invoke-RestMethod "$scmUrl/api/deployments/$deploymentId" -Headers $headers -TimeoutSec 30
}
if (-not $ready) { throw "Application deployment $deploymentId is not complete after the bounded wait. Initialization was not submitted." }
$ready = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    try {
        $health = Invoke-WebRequest "https://$($app.defaultHostName)/healthz" -SkipHttpErrorCheck -TimeoutSec 10
        if ($health.StatusCode -eq 200 -and ($health.Content | ConvertFrom-Json).status -eq 'healthy') {
            $ready = $true
            break
        }
        Write-Host "Waiting for application health (HTTP $($health.StatusCode))."
    } catch [System.Net.Http.HttpRequestException] {
        Write-Host 'Waiting for application health (connection unavailable).'
    } catch [System.Threading.Tasks.TaskCanceledException] {
        Write-Host 'Waiting for application health (request timed out).'
    }
    Start-Sleep -Seconds 5
}
if (-not $ready) { throw 'Application startup did not become healthy within the bounded wait. Initialization was not submitted.' }
$latest = Invoke-RestMethod "$scmUrl/api/deployments/latest" -Headers $headers -TimeoutSec 30
if ($latest.id -ne $deploymentId) { throw 'Deployment changed while waiting; inspect it before initializing.' }
$instances = @(az webapp list-instances --subscription $Subscription --resource-group $ResourceGroup --name $AppName -o json | ConvertFrom-Json)
if (-not $instances.Count) { throw 'No running application instance is available.' }
$run = "material-db-$([guid]::NewGuid().ToString('N'))"
$argument = if ($RequestId) { " --request $RequestId" }
    elseif ($MigrateDemoPlants) { ' --migrate-demo-plants' } else { '' }
# Execute in the app container, not Kudu: only the app has the private DB path and identity.
$command = 'cd /home/site/wwwroot && node initialize.js{0} > /home/LogFiles/{1}.log 2>&1; result=$?; printf "%s" "$result" > /home/LogFiles/{1}.exit' -f $argument, $run
az webapp exec --subscription $Subscription --resource-group $ResourceGroup --name $AppName `
    --instance $instances[0].name --mode execute --shell /bin/sh --shell-command $command -o none
# Accepted is not completed. Read the uniquely named exit status through authenticated SCM.
for ($attempt = 0; $attempt -lt 24; $attempt++) {
    $status = Invoke-WebRequest "https://$($scm[0])/api/vfs/LogFiles/$run.exit" `
        -Headers $headers -SkipHttpErrorCheck -TimeoutSec 10
    if ($status.StatusCode -eq 200) {
        $log = Invoke-WebRequest "https://$($scm[0])/api/vfs/LogFiles/$run.log" -Headers $headers -TimeoutSec 10
        $exitCode = if ($status.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($status.Content) } else { $status.Content }
        $output = if ($log.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($log.Content) } else { $log.Content }
        if ($exitCode.Trim() -ne '0') { throw "Database operation failed: $output" }
        $result = $output | ConvertFrom-Json
        if ($RequestId) {
            if ($result.request_id -ne $RequestId) { throw 'Database read-back returned the wrong request.' }
        } elseif ($MigrateDemoPlants) {
            if ($result.migrated -ne $true -or $null -eq $result.updated -or $result.updated -lt 0) {
                throw 'Demo plant migration was not confirmed.'
            }
        } elseif ($result.initialized -ne $true) { throw 'Database initialization was not confirmed.' }
        $result
        return
    }
    if ($status.StatusCode -ne 404) { throw "SCM completion read failed (HTTP $($status.StatusCode))." }
    Start-Sleep -Seconds 5
}
throw "Database operation completion is unknown. Inspect /home/LogFiles/$run.* before retrying."
