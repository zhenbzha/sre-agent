@description('Deployed Search service name.')
param searchName string

@description('Deployed Foundry account name.')
param foundryName string

@description('Deployed Foundry project name.')
param projectName string

@description('Search service region.')
param location string

@description('Original project principal whose pre-migration Search reader assignment must retain its name.')
param legacyProjectPrincipalId string = ''

resource search 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-12-01' existing = {
  parent: foundry
  name: projectName
}

// Pass the runtime identity into a module so it is available when naming the role.
module projectSearchReader 'project-search-role.bicep' = {
  name: 'project-search-reader'
  params: {
    searchName: search.name
    projectResourceId: project.id
    principalId: project.identity.principalId
    legacyPrincipalId: legacyProjectPrincipalId
  }
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-12-01' = {
  parent: project
  name: 'scm-search'
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${searchName}.search.windows.net'
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: search.id
      location: location
    }
  }
}
