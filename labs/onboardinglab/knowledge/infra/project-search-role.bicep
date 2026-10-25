@description('Search service that the project can read.')
param searchName string

@description('Resource ID of the Foundry project.')
param projectResourceId string

@description('Current Foundry project managed-identity principal ID.')
param principalId string

@description('Original principal whose pre-migration assignment must retain its name. Leave empty for new environments.')
param legacyPrincipalId string = ''

resource search 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchName
}

var readerRole = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '1407120a-92aa-4202-b7e9-c0e197c71c8f'
)

// Reuse the old name only for its original principal; a recreated identity gets a new GUID.
resource projectSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: principalId == legacyPrincipalId
    ? guid(search.id, projectResourceId, readerRole)
    : guid(search.id, principalId, readerRole)
  scope: search
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRole
  }
}
