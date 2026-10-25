@description('Name of the existing SCM azd environment.')
param environmentName string

@description('Region for Search and Foundry resources.')
param location string

@description('Tenant-local object ID of the document publisher.')
param operatorPrincipalId string

@description('Object ID of the existing SRE retrieval identity.')
param srePrincipalId string

@description('Original project principal whose pre-migration Search reader assignment must retain its name.')
param legacyProjectPrincipalId string = ''

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().name, environmentName, 'knowledge')
var searchName = 'srch-scm-${suffix}'
var foundryName = 'ai-scm-${suffix}'
var projectName = 'scm-operations'
var tags = {
  'azd-env-name': environmentName
  workload: 'onboardinglab-knowledge'
  purpose: 'synthetic-scm-demo'
}

module search 'br/public:avm/res/search/search-service:0.13.0' = {
  name: 'search'
  params: {
    name: searchName
    location: location
    sku: 'basic'
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'free'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    managedIdentities: {
      systemAssigned: true
    }
    roleAssignments: [
      {
        principalId: operatorPrincipalId
        principalType: 'User'
        roleDefinitionIdOrName: 'Search Service Contributor'
      }
      {
        principalId: operatorPrincipalId
        principalType: 'User'
        roleDefinitionIdOrName: 'Search Index Data Contributor'
      }
      {
        principalId: srePrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Index Data Reader'
      }
    ]
    tags: tags
  }
}

module foundry 'br/public:avm/ptn/ai-ml/ai-foundry:0.7.0' = {
  name: 'foundry'
  params: {
    baseName: 'scmknowledge'
    location: location
    includeAssociatedResources: false
    aiFoundryConfiguration: {
      accountName: foundryName
      disableLocalAuth: true
      allowProjectManagement: true
      createCapabilityHosts: false
      project: {
        name: projectName
        displayName: 'SCM Operations Knowledge'
        desc: 'Synthetic SCM operations handbook for read-only SRE troubleshooting.'
      }
      roleAssignments: [
        {
          principalId: search.outputs.systemAssignedMIPrincipalId!
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Cognitive Services User'
        }
        {
          principalId: operatorPrincipalId
          principalType: 'User'
          roleDefinitionIdOrName: 'Cognitive Services OpenAI User'
        }
        {
          principalId: operatorPrincipalId
          principalType: 'User'
          roleDefinitionIdOrName: 'eadc314b-1a2d-4efa-be10-5d325db5065e'
        }
      ]
    }
    aiModelDeployments: [
      {
        name: 'text-embedding-3-small'
        model: {
          format: 'OpenAI'
          name: 'text-embedding-3-small'
          version: '1'
        }
        sku: {
          name: 'DataZoneStandard'
          capacity: 10
        }
      }
      {
        name: 'gpt-5.4-mini'
        model: {
          format: 'OpenAI'
          name: 'gpt-5.4-mini'
          version: '2026-03-17'
        }
        sku: {
          name: 'DataZoneStandard'
          capacity: 10
        }
      }
    ]
    tags: tags
  }
}

// Read the project's generated identity only after both AVM deployments finish.
module projectConnection 'project-connection.bicep' = {
  name: 'project-connection'
  params: {
    searchName: search.outputs.name
    foundryName: foundry.outputs.aiServicesName
    projectName: foundry.outputs.aiProjectName
    location: location
    legacyProjectPrincipalId: legacyProjectPrincipalId
  }
}

output searchName string = search.outputs.name
output searchEndpoint string = 'https://${searchName}.search.windows.net'
output foundryName string = foundry.outputs.aiServicesName
output projectName string = foundry.outputs.aiProjectName
output foundryEndpoint string = 'https://${foundryName}.openai.azure.com'
