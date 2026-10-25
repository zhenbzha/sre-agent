targetScope = 'subscription'

@description('Existing azd environment name used to identify this knowledge component.')
@minLength(1)
param environmentName string

@description('Region for the knowledge resources. The SCM demonstration uses francecentral.')
param location string

@description('Existing SCM resource group. This template does not create or own the group.')
@minLength(1)
param resourceGroupName string

@description('Tenant-local object ID of the operator who indexes the synthetic handbook.')
param operatorPrincipalId string

@description('Object ID of the existing SRE managed identity that can retrieve knowledge.')
param srePrincipalId string

@description('Original project principal for an existing pre-migration Search reader assignment. Leave empty for new environments.')
param legacyProjectPrincipalId string = ''

resource demoGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: resourceGroupName
}

module knowledge 'resources.bicep' = {
  name: 'scm-knowledge'
  scope: demoGroup
  params: {
    environmentName: environmentName
    location: location
    operatorPrincipalId: operatorPrincipalId
    srePrincipalId: srePrincipalId
    legacyProjectPrincipalId: legacyProjectPrincipalId
  }
}

output AZURE_RESOURCE_GROUP string = demoGroup.name
output AZURE_LOCATION string = location
output AZURE_SEARCH_NAME string = knowledge.outputs.searchName
output AZURE_SEARCH_ENDPOINT string = knowledge.outputs.searchEndpoint
output AZURE_FOUNDRY_NAME string = knowledge.outputs.foundryName
output AZURE_FOUNDRY_PROJECT string = knowledge.outputs.projectName
output AZURE_FOUNDRY_ENDPOINT string = knowledge.outputs.foundryEndpoint
output KNOWLEDGE_BASE_NAME string = 'scm-operations'
output KNOWLEDGE_SOURCE_NAME string = 'scm-operations-handbook'
output KNOWLEDGE_MCP_ENDPOINT string = '${knowledge.outputs.searchEndpoint}/knowledgebases/scm-operations/mcp?api-version=2026-08-01-preview'
