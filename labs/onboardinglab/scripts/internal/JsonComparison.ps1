function ConvertTo-CanonicalJson {
    param(
        [AllowNull()][object] $Value,
        [switch] $IgnoreNullObjectProperties
    )

    function ConvertTo-OrderedJsonValue {
        param([AllowNull()][object] $Item)

        # The [pscustomobject] alias also matches wrapped arrays and dictionaries.
        if ($Item -is [System.Management.Automation.PSCustomObject]) {
            $properties = [ordered]@{}
            foreach ($property in $Item.PSObject.Properties) {
                $properties[$property.Name] = $property.Value
            }
            return ConvertTo-OrderedJsonValue $properties
        }
        if ($Item -is [System.Collections.IDictionary]) {
            $properties = [ordered]@{}
            foreach ($key in @($Item.Keys | Sort-Object -CaseSensitive)) {
                if ($IgnoreNullObjectProperties -and $null -eq $Item[$key]) { continue }
                $properties[$key] = ConvertTo-OrderedJsonValue $Item[$key]
            }
            return $properties
        }
        if ($Item -is [array]) {
            $items = [object[]]::new($Item.Length)
            for ($index = 0; $index -lt $Item.Length; $index++) {
                $items[$index] = ConvertTo-OrderedJsonValue $Item[$index]
            }
            return ,$items
        }
        return $Item
    }

    ConvertTo-Json -InputObject (ConvertTo-OrderedJsonValue $Value) -Depth 70 -Compress
}
