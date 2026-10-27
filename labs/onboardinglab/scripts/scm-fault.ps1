[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('inject', 'reset')]
    [string] $Action
)

$ErrorActionPreference = 'Stop'
$faultParameters = @{
    Subscription = 'db4948d5-b90c-47d4-91b5-d8c4c43493d2'
    ResourceGroup = 'rg-flu-xzlxm7twvdxao'
    WorkloadOption = 'app-service-postgresql'
    NetworkSecurityGroupName = 'flu-xzlxm7twvdxao-app-nsg'
    NamePrefix = 'flu-xzlxm7twvdxao'
}

& (Join-Path $PSScriptRoot 'fault.ps1') -Action $Action @faultParameters
