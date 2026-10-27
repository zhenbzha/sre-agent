#Requires -Version 7.3
BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\internal\JsonComparison.ps1')
}

Describe 'JSON configuration comparison' {
    It 'ignores nested object-key ordering for dictionaries and API objects' {
        $expected = [ordered]@{ name = 'request'; options = [ordered]@{ enabled = $true; tools = @('read', 'show') } }
        $actual = '{"options":{"tools":["read","show"],"enabled":true},"name":"request"}' | ConvertFrom-Json
        ConvertTo-CanonicalJson $actual | Should -BeExactly (ConvertTo-CanonicalJson $expected)
    }

    It 'preserves JSON value shapes for <Json>' -ForEach @(
        @{ Json = 'null' }
        @{ Json = '[]' }
        @{ Json = '[null]' }
        @{ Json = '[[]]' }
        @{ Json = '[[],null,["read"]]' }
        @{ Json = '{"empty":[],"missing":null,"single":["read"]}' }
    ) {
        $value = ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate
        ConvertTo-CanonicalJson $value | Should -BeExactly $Json
    }

    It 'does not equate <Left> and <Right>' -ForEach @(
        @{ Left = '["read","show"]'; Right = '["show","read"]' }
        @{ Left = '["read"]'; Right = '"read"' }
        @{ Left = '[]'; Right = 'null' }
        @{ Left = '{"name":"read"}'; Right = '{"name":"Read"}' }
        @{ Left = '{"name":"read"}'; Right = '{"Name":"read"}' }
        @{ Left = '{"value":1}'; Right = '{"value":"1"}' }
        @{ Left = '{"value":null}'; Right = '{}' }
    ) {
        $leftValue = ConvertFrom-Json -InputObject $Left -AsHashtable -NoEnumerate
        $rightValue = ConvertFrom-Json -InputObject $Right -AsHashtable -NoEnumerate
        ConvertTo-CanonicalJson $leftValue | Should -Not -BeExactly (ConvertTo-CanonicalJson $rightValue)
    }

    It 'ignores only null object properties when explicitly requested for SRE readback' {
        $value = '{"optional":null,"items":[null,[],{"optional":null}]}' | ConvertFrom-Json
        ConvertTo-CanonicalJson $value -IgnoreNullObjectProperties | Should -BeExactly '{"items":[null,[],{}]}'
    }
}
