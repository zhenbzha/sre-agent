#Requires -Version 7.3
[CmdletBinding()]
param(
    [string]$EnvironmentName = 'sre-agent-scm'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'knowledge-common.ps1')

$environmentJson = azd -C $PSScriptRoot env get-values --environment $EnvironmentName --output json
$environment = $environmentJson | ConvertFrom-Json -AsHashtable
foreach ($key in @('AZURE_SUBSCRIPTION_ID', 'AZURE_SEARCH_NAME', 'AZURE_FOUNDRY_NAME', 'KNOWLEDGE_SOURCE_NAME', 'KNOWLEDGE_BASE_NAME')) {
    if ([string]::IsNullOrWhiteSpace($environment[$key])) {
        throw "Missing azd output $key. Provision this knowledge component first."
    }
}

$configuration = Get-KnowledgeConfiguration $environment
$endpoint = $configuration.SearchEndpoint
$modelEndpoint = $configuration.ModelEndpoint
$sourceName = $configuration.SourceName
$baseName = $configuration.BaseName
$apiVersion = $configuration.ApiVersion
$pdf = Get-Item (Join-Path $PSScriptRoot 'documents\SCM-Operations-Handbook.pdf')
$hash = (Get-FileHash $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$token = az account get-access-token --subscription $environment.AZURE_SUBSCRIPTION_ID `
    --resource https://search.azure.com/ --query accessToken --output tsv
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Azure CLI returned no Search access token.' }
$credential = ConvertTo-SecureString $token -AsPlainText -Force
Remove-Variable token

function Invoke-Search {
    param(
        [ValidateSet('GET', 'PUT', 'POST')][string]$Method,
        [string]$Path,
        [object]$Body,
        [switch]$AllowNotFound,
        [switch]$CreateOnly
    )
    $uri = [uri]::new([uri]"$endpoint/", $Path)
    if ($uri.Scheme -ne 'https' -or $uri.Authority -ne ([uri]$endpoint).Authority -or $uri.UserInfo) {
        throw 'Refusing to send a Search credential to a different endpoint.'
    }
    $parameters = @{
        Uri = $uri
        Method = $Method
        Authentication = 'Bearer'
        Token = $credential
        TimeoutSec = 180
        MaximumRedirection = 0
        SkipHttpErrorCheck = $true
    }
    if ($CreateOnly) { $parameters.Headers = @{ 'If-None-Match' = '*' } }
    if ($Body -is [System.Net.Http.HttpContent]) {
        $parameters.Body = $Body
    } elseif ($null -ne $Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 30 -Compress
        $parameters.ContentType = 'application/json'
    }
    # Only reads retry role propagation. Never replay an uncertain file upload.
    for ($attempt = 1; $attempt -le 7; $attempt++) {
        $response = Invoke-WebRequest @parameters
        if ($response.StatusCode -eq 403 -and $Method -eq 'GET' -and $attempt -lt 7) {
            Write-Warning "Search returned 403; waiting for role propagation ($attempt/7)."
            Start-Sleep -Seconds 20
            continue
        }
        if ($response.StatusCode -eq 404 -and $AllowNotFound) { return $null }
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300 -or $response.StatusCode -eq 206) {
            throw "Search $Method $Path failed (HTTP $($response.StatusCode)): $($response.Content)"
        }
        if ($response.Content) { return ($response.Content | ConvertFrom-Json -AsHashtable) }
        return $null
    }
}

function Get-HandbookFiles {
    $path = "/knowledgesources('$sourceName')/files?api-version=$apiVersion"
    $results = [System.Collections.Generic.List[object]]::new()
    do {
        $page = Invoke-Search -Method GET -Path $path
        foreach ($file in $page.value) {
            $results.Add($file)
        }
        $path = $page['@odata.nextLink']
    } while ($path)
    $unexpected = @($results | Where-Object { $_.fileName -cne $pdf.Name })
    if ($unexpected.Count) {
        $details = ($unexpected | ForEach-Object { "$($_.fileName) ($($_.fileId))" }) -join ', '
        throw "Unexpected files in the handbook source: $details. Reconcile them before publishing; no files were deleted."
    }
    return $results.ToArray()
}

function Get-HandbookHash {
    param([System.Collections.IDictionary]$File)
    $metadata = $File['metadata']
    if ($null -eq $metadata) { return $null }
    return $metadata['sha256']
}

$sourcePath = "/knowledgesources/$sourceName`?api-version=$apiVersion"
$source = Invoke-Search -Method GET -Path $sourcePath -AllowNotFound
if ($null -eq $source) {
    $source = Invoke-Search -Method PUT -Path $sourcePath -CreateOnly -Body @{
        name = $sourceName
        description = 'SCM-OPS-001 synthetic operations handbook; examples are not current incident evidence.'
        kind = 'file'
        fileParameters = @{
            ingestionParameters = @{
                contentExtractionMode = 'minimal'
                embeddingModel = @{
                    kind = 'azureOpenAI'
                    azureOpenAIParameters = @{
                        resourceUri = $modelEndpoint
                        deploymentId = 'text-embedding-3-small'
                        modelName = 'text-embedding-3-small'
                    }
                }
            }
        }
    }
} elseif ($source.kind -ne 'file' -or $source.description -notlike 'SCM-OPS-001 *' -or
    $source.fileParameters.ingestionParameters.embeddingModel.azureOpenAIParameters.resourceUri.TrimEnd('/') -ne $modelEndpoint) {
    throw 'The existing knowledge source does not match this component; no content was uploaded.'
}

$files = @(Get-HandbookFiles)
if ($files.Count -gt 1) { throw 'Duplicate handbook filenames already exist. Reconcile the file IDs before publishing.' }
if ($files.Count -eq 1 -and (Get-HandbookHash $files[0]) -eq $hash -and -not $files[0]['errorMessage']) {
    $file = $files[0]
    Write-Host "Handbook content unchanged; retaining file $($file.fileId)."
} else {
    $multipart = [System.Net.Http.MultipartFormDataContent]::new()
    try {
        $metadata = @{
            fileName = $pdf.Name
            metadata = @{ sha256 = $hash; documentId = 'SCM-OPS-001'; version = '1.0'; classification = 'synthetic-demo' }
        } | ConvertTo-Json -Depth 5 -Compress
        $multipart.Add([System.Net.Http.StringContent]::new($metadata, [Text.Encoding]::UTF8, 'application/json'), 'metadata')
        $content = [System.Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($pdf.FullName))
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $multipart.Add($content, 'content', $pdf.Name)
        $method = 'POST'
        $path = "/knowledgesources('$sourceName')/files?api-version=$apiVersion"
        if ($files.Count -eq 1) {
            $method = 'PUT'
            $fileId = [uri]::EscapeDataString($files[0].fileId)
            $path = "/knowledgesources('$sourceName')/files('$fileId')?api-version=$apiVersion"
        }
        $file = Invoke-Search -Method $method -Path $path -Body $multipart
    } finally {
        $multipart.Dispose()
    }
    if ($file['errorMessage']) { throw "Handbook ingestion failed: $($file['errorMessage'])" }
    Write-Host "Indexed handbook file $($file.fileId)."
}

$files = @(Get-HandbookFiles)
if ($files.Count -ne 1 -or (Get-HandbookHash $files[0]) -ne $hash -or $files[0]['errorMessage']) {
    throw 'Server-side file metadata does not confirm exactly one successfully ingested copy of this PDF.'
}

$basePath = "/knowledgebases/$baseName`?api-version=$apiVersion"
$existingBase = Invoke-Search -Method GET -Path $basePath -AllowNotFound
if ($existingBase -and $existingBase.description -notlike 'SCM-OPS-001 *') {
    throw 'The existing knowledge base is not owned by this component; refusing to overwrite it.'
}
$null = Invoke-Search -Method PUT -Path $basePath -Body @{
    name = $baseName
    description = 'SCM-OPS-001 synthetic handbook: service behavior, troubleshooting, support handoff and recovery verification.'
    knowledgeSources = @(@{ name = $sourceName })
    models = @(@{
        kind = 'azureOpenAI'
        azureOpenAIParameters = @{
            resourceUri = $modelEndpoint
            deploymentId = 'gpt-5.4-mini'
            modelName = 'gpt-5.4-mini'
        }
    })
    outputMode = 'extractiveData'
    retrievalReasoningEffort = @{ kind = 'low' }
    retrieveDefaults = @{ maxRuntimeInSeconds = 45; maxOutputDocuments = 8; maxOutputSizeInTokens = 12000 }
}

$retrieval = Invoke-Search -Method POST -Path "/knowledgebases/$baseName/retrieve?api-version=$apiVersion" -Body @{
    messages = @(@{
        role = 'user'
        content = @(@{ type = 'text'; text = 'What evidence is required before closing a recovered SCM incident, and what must be handed to the next support shift?' })
    })
    includeActivity = $true
}
$grounding = $retrieval.response | ConvertTo-Json -Depth 30
if ($grounding -notmatch 'SCM-RV-04' -or $grounding -notmatch 'SCM-HO-03') {
    throw 'Retrieval did not return the handbook recovery and handoff sections. Inspect the source and generated index.'
}
if (@($retrieval.activity | Where-Object { $_.type -eq 'modelQueryPlanning' }).Count -eq 0) {
    throw 'Retrieval returned no query-planning activity; the planned Foundry model path was not verified.'
}
[pscustomobject]@{
    SearchEndpoint = $endpoint
    KnowledgeBase = $baseName
    FileId = $files[0].fileId
    Sha256 = $hash
    McpEndpoint = $configuration.McpEndpoint
    RetrievalVerified = $true
}
