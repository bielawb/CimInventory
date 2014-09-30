param (
    $PathDatabase = "$PSScriptRoot\database.sdf",
    $PathWQLQueries = "$PSScriptRoot\Queries.txt",
    $PathMap = "$PSScriptRoot\Map.txt",
    $PathComputerNames = "$PSScriptRoot\ComputerNames.txt"
)

$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    # Disconnect SQL
    $command.Dispose()
    $connection.Close()
    $connection.Dispose()
}

#region Connecting to SQL

if (-not (Test-Path $PathDatabase)) {
    try {
        $engine = New-Object Data.SqlServerCe.SqlCeEngine
        $engine.LocalConnectionString = "Data Source = $PathDatabase"
        $engine.CreateDatabase()
    } catch {
        throw "Could not created database! $_"
    }
}

$connection = New-Object Data.SqlServerCe.SqlCeConnection
$connection.ConnectionString = "Data Source = $PathDatabase"
    
$connection.Open()

$command = New-Object Data.SqlServerCe.SqlCeCommand
$command.Connection = $connection

#endregion

#region Support functions

function Get-SqlData {

<#
    .Synopsis
        Helper function.

    .Description
        This function reads data from Sql using
        -- pre-defined object of type SqlCeCommand
        -- provided query
        -- creates object of selected pseudo-type        
#>

param (
    # Query that will be used to retrieve objects.
    [string]$Query,

    # Command object that will be used.
    [Data.SqlServerCe.SqlCeCommand]$Command = $Script:command,

    # Pseudo-type configured on retrieved objects.
    [string]$Type
)

    $Command.CommandText = $Query
    try {
        $adapter = New-Object System.Data.SqlServerCe.SqlCeDataAdapter $Command
        $table = New-Object System.Data.DataTable
        $adapter.Fill($table) | Out-Null

        $columnNames = $table.Columns | Select-Object -ExpandProperty ColumnName
        foreach ($row in $table.Rows) {
            $properties = [ordered]@{}
            if ($Type) {
                $properties.PSTypeName = $Type
            }

            foreach ($property in $columnNames) {
                $properties.Add($property, $row.$property)
            }
            New-Object -TypeName PSObject -Property $properties
        }
    } catch {
        Write-Error "Issue with connecting to database: $_"
    } finally {
        if ($adapter) {
            $adapter.Dispose()
        }
    }
}


function Invoke-SqlCommand {

<#
    .Synopsis
        Helper function.

    .Description
        This function runs Sql command using
        -- pre-defined object of type SqlCeCommand
        -- provided query
        -- does not return any objects

#>

param (
    # Query to run.
    [string]$TSQL,

    # Object of type SqlCeCommand that will be used to execute query.
    [Data.SqlServerCe.SqlCeCommand]$Command = $Script:command
)

    $Command.CommandText = $TSQL    
    try {
        $Command.ExecuteNonQuery() | Out-Null
    } catch {
        Write-Error "Issue with running query: $TSQL`n$_"
    }
}

#endregion

#region Creating 'Computers' table

if (-not (Get-SqlData -Query "SELECT Table_Name FROM information_schema.tables WHERE Table_Name = 'Computers'")) {
    try {
        Invoke-SqlCommand -TSQL @"
            CREATE TABLE Computers (
                Computer_Id int IDENTITY(1,1) PRIMARY KEY,
                Name nvarchar(30) UNIQUE
            );          
"@             
    } catch  {
        throw "Could not create table 'Computers'!`n $_"
    }
}

#endregion

#region Exported functions

function Get-CimData {
<#
    .Synopsis
        Get data from remote computer using WMI.

    .Description
        Uses Get-CimInstance to read WMI data from remote box.
        Supports both WSMan and DCOM protocol.
        Optionally you can try to connect only to computers that respond to Test-Connection.
        Queries are read from a file.
        Mapping lets you configure what WMI properties will map to in custom object that will be created.

    .Example
        Get-CimData -ComputerName localhost
        Reads data from WMI on local computer.

    .Example
        'Alpha', 'Beta', 'Gamma' | Get-CimData
        Reads WMI data from computers: Alpha, Beta i Gamma.

#>

[OutputType('ITPro.Cim.Object')]
[CmdletBinding()]
param (

    # Computer that commad will read WMI information from.
    [Parameter(
        ValueFromPipeline = $true,
        Mandatory = $true,
        HelpMessage = 'Please give name of computer to process'
    )]
    [Alias('CN','Node','Computer','Name','Server')]
    [string]$ComputerName,

    # Option credentials to use to connect to remote computers.
    [Management.Automation.PSCredential]
    [Management.Automation.Credential()]
    $Credential = [Management.Automation.PSCredential]::Empty,

    # Path to file with WQL querries.
    [ValidateScript({
        Test-Path -Path $_
    })]
    [string]$WQLPath = $Script:PathWQLQueries, 

    # Map converting name of WMI properties to properties of generated custom object.
    [hashtable]$PropertyMap,

    # Enables checking for network connection before running WMI queries.
    [switch]$TestNetwork,

    # Protocol that will be used to read WMI data.
    [Microsoft.Management.Infrastructure.CimCmdlets.ProtocolType]$Protocol = 'Default'
)

begin {
    try {
        $queriesData = Import-Csv -Delimiter / -Path $WQLPath -ErrorAction Stop
    } catch {
        throw "Problem with reading WQL querries configuration: $_"
    }

    if ($PropertyMap) {
        $map = $PropertyMap
    } else {
        $map = ConvertFrom-StringData (Get-Content $Script:PathMap | Out-String)
    }
    $cimSessionOption = New-CimSessionOption -Protocol $Protocol
}

process {
    if ($TestNetwork) {
        if (-not (Test-Connection -Quiet -Count 1 -ComputerName $ComputerName)) {
            return
        }
    }
    try {
        $properties = [ordered]@{
            PSTypeName = 'ITPro.Cim.Object'
        }

        $computerData = @{
            ComputerName = $ComputerName
            SessionOption = $cimSessionOption
        }

        if ($Credential -ne [Management.Automation.PSCredential]::Empty) {
            $computerData.Credential = $Credential
        }

        $cimCommonParam = @{
            CimSession = New-CimSession @computerData
            ErrorAction = 'Stop'
        }

        foreach ($item in $queriesData) {
            $propertyList = $item.Property.Split('\') 
            $cimItemParam = @{ 
                Property = $propertyList
                ClassName = $item.Class
            }

            if ($item.Filter) {
                $cimItemParam.Filter = $item.Filter
            }

            $nodeData = @(Get-CimInstance @cimCommonParam @cimItemParam)[0]
            foreach ($property in $propertyList) {
                if (-not ($name = $map[$property])) {
                    $name = $property
                }
                $properties[$name] = $nodeData.$property
            }
        }

        $properties.Modified = Get-Date
        if (-not $properties.Name) {
            $properties.Name = $ComputerName
        }
        New-Object PSObject -Property $properties
    } catch {
        Write-Error "Issue with reading information from $ComputerName`: $_"
    } 
}
} 


function Import-CimData {

<#
    .Synopsis
        Reads data from database and creates custom object from it.
    
    .Description
        Function reads data from database.
        It gives you ability to:
        -- Limit properties
        -- Filter objects (using TSQL syntax)
    
    .Example
        Import-CimData
        Reads data about all computers stored in database.

    .Example
        Import-CimData -Properties Name, UserName, HDSize
        Reads data about all computers stored in database but retrieves only information about Name, UserName and HDSize.

    .Example
        Import-CimData -Filter "UserName LIKE '%ba%'
        Retrieves information about all computers where UserName matches 'ba'
#>

[OutputType('ITPro.Cim.Object')]
[CmdletBinding()]
param (
    # Filter used to limit the results.
    [string]$Filter,

    # Properties retrieved from database.
    [string[]]$Properties
)
    if ($Properties) {
        $propertiesString = $Properties -join ', '
    } else {
        $propertiesString = '*'
    }

    if ($Filter) {
        $filterString = "WHERE $Filter"
    } else {
        $filterString = ''
    }
    
    $query = "SELECT $propertiesString FROM Computers $filterString"
    try {
        Get-SqlData -Query $query -Type ITPro.Cim.Object
    } catch {
        Write-Error "Issue with reading data from database: $_"
    }
}


function Export-CimData {

<#
    .Synopsis
        Function that saves data from WMI to SQL table.
    
    .Description
        Function saves data from WMI to database. If database does not contain necessary columns, they will be added.

        Type column will use depends on input data:
        -- datetime (SQL) for datetime (NET)
        -- bigint (SQL) for *int*
        -- nvarchar(100) (SQL) for any other data

    .Example
        Get-CimData -ComputerName Test | Export-CimData
        Reads data from computer Test and saves them to database.

#>

[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = 'Medium'
)]
param (
    [Parameter(ValueFromPipeline = $true)]
    [Alias('IO')]
    [PSTypeName('ITPro.Cim.Object')]
    [PSObject]$InputObject
)

begin {

    $query = @{
        Query = @"
    SELECT Column_Name 
    FROM information_schema.columns 
    WHERE table_name='Computers'
"@
    }

    $addColumn = 'ALTER Table Computers Add Column {0} {1}'        
}

process {
    try {
        $columns = Get-SqlData @query | 
            Select-Object -ExpandProperty COLUMN_NAME
    } catch {
        Write-Error "Issue with retrieving columns list: $_"
    }

    if ( Get-SqlData -Query "SELECT Name FROM Computers WHERE Name='$($InputObject.Name)'" ) {
        if ($psCmdlet.ShouldProcess("$($InputObject.Name)", 'Replace data in table: Computers')) {
            try {
                Invoke-SqlCommand -TSQL "DELETE FROM Computers WHERE Name='$($InputObject.Name)'" 
            } catch {
                Write-Error "Issue with removing record: $($InputObject.Name)"
            }
        } else {
            return
        }
    } 

    $InputObject.Psobject.Properties | 
        Where-Object { @('Property','NoteProperty') -contains $_.MemberType } | 
        Foreach-Object -Begin {
            $names = $values = @()
        } -Process {
            $names += $_.Name

            if ($columns -notcontains $_.Name) {
                Write-Verbose "Column $($_.Name) is not in database, we need to add it first..."
                $type = switch -Regex ($_.TypeNameOfValue) {
                    int { 'bigint' }
                    datetime { 'datetime' }
                    default { 'nvarchar(100)' }
                }
                try {
                    Invoke-SqlCommand -TSQL ($addColumn -f $_.Name, $type)
                } catch {
                    Write-Error "Issue with adding column: $($_.Name)`n$_"    
                } 
            }
            $values += "'$($_.Value)'"
        } -End {
            try {
                Invoke-SqlCommand -TSQL @"
                    INSERT INTO Computers
                    ( $($names -join ', ') )
                    VALUES
                    ( $($values -join ', ') )
"@
            } catch {
                Write-Error "Issue with adding record $($InputObject.Name) to Computers table: $_"
            }
        }
}
}

#endregion

#region Aliases

New-Alias -Name gcd -Value Get-CimData
New-Alias -Name ipcd -Value Import-CimData
New-Alias -Name epcd -Value Export-CimData

#endregion

Export-ModuleMember -Function * -Alias *
# SIG # Begin signature block
# MIIatwYJKoZIhvcNAQcCoIIaqDCCGqQCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU45WX0rQrhw9XhXOwXUUOx77k
# zlagghXtMIID7jCCA1egAwIBAgIQfpPr+3zGTlnqS5p31Ab8OzANBgkqhkiG9w0B
# AQUFADCBizELMAkGA1UEBhMCWkExFTATBgNVBAgTDFdlc3Rlcm4gQ2FwZTEUMBIG
# A1UEBxMLRHVyYmFudmlsbGUxDzANBgNVBAoTBlRoYXd0ZTEdMBsGA1UECxMUVGhh
# d3RlIENlcnRpZmljYXRpb24xHzAdBgNVBAMTFlRoYXd0ZSBUaW1lc3RhbXBpbmcg
# Q0EwHhcNMTIxMjIxMDAwMDAwWhcNMjAxMjMwMjM1OTU5WjBeMQswCQYDVQQGEwJV
# UzEdMBsGA1UEChMUU3ltYW50ZWMgQ29ycG9yYXRpb24xMDAuBgNVBAMTJ1N5bWFu
# dGVjIFRpbWUgU3RhbXBpbmcgU2VydmljZXMgQ0EgLSBHMjCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBALGss0lUS5ccEgrYJXmRIlcqb9y4JsRDc2vCvy5Q
# WvsUwnaOQwElQ7Sh4kX06Ld7w3TMIte0lAAC903tv7S3RCRrzV9FO9FEzkMScxeC
# i2m0K8uZHqxyGyZNcR+xMd37UWECU6aq9UksBXhFpS+JzueZ5/6M4lc/PcaS3Er4
# ezPkeQr78HWIQZz/xQNRmarXbJ+TaYdlKYOFwmAUxMjJOxTawIHwHw103pIiq8r3
# +3R8J+b3Sht/p8OeLa6K6qbmqicWfWH3mHERvOJQoUvlXfrlDqcsn6plINPYlujI
# fKVOSET/GeJEB5IL12iEgF1qeGRFzWBGflTBE3zFefHJwXECAwEAAaOB+jCB9zAd
# BgNVHQ4EFgQUX5r1blzMzHSa1N197z/b7EyALt0wMgYIKwYBBQUHAQEEJjAkMCIG
# CCsGAQUFBzABhhZodHRwOi8vb2NzcC50aGF3dGUuY29tMBIGA1UdEwEB/wQIMAYB
# Af8CAQAwPwYDVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NybC50aGF3dGUuY29tL1Ro
# YXd0ZVRpbWVzdGFtcGluZ0NBLmNybDATBgNVHSUEDDAKBggrBgEFBQcDCDAOBgNV
# HQ8BAf8EBAMCAQYwKAYDVR0RBCEwH6QdMBsxGTAXBgNVBAMTEFRpbWVTdGFtcC0y
# MDQ4LTEwDQYJKoZIhvcNAQEFBQADgYEAAwmbj3nvf1kwqu9otfrjCR27T4IGXTdf
# plKfFo3qHJIJRG71betYfDDo+WmNI3MLEm9Hqa45EfgqsZuwGsOO61mWAK3ODE2y
# 0DGmCFwqevzieh1XTKhlGOl5QGIllm7HxzdqgyEIjkHq3dlXPx13SYcqFgZepjhq
# IhKjURmDfrYwggSjMIIDi6ADAgECAhAOz/Q4yP6/NW4E2GqYGxpQMA0GCSqGSIb3
# DQEBBQUAMF4xCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jwb3Jh
# dGlvbjEwMC4GA1UEAxMnU3ltYW50ZWMgVGltZSBTdGFtcGluZyBTZXJ2aWNlcyBD
# QSAtIEcyMB4XDTEyMTAxODAwMDAwMFoXDTIwMTIyOTIzNTk1OVowYjELMAkGA1UE
# BhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0aW9uMTQwMgYDVQQDEytT
# eW1hbnRlYyBUaW1lIFN0YW1waW5nIFNlcnZpY2VzIFNpZ25lciAtIEc0MIIBIjAN
# BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAomMLOUS4uyOnREm7Dv+h8GEKU5Ow
# mNutLA9KxW7/hjxTVQ8VzgQ/K/2plpbZvmF5C1vJTIZ25eBDSyKV7sIrQ8Gf2Gi0
# jkBP7oU4uRHFI/JkWPAVMm9OV6GuiKQC1yoezUvh3WPVF4kyW7BemVqonShQDhfu
# ltthO0VRHc8SVguSR/yrrvZmPUescHLnkudfzRC5xINklBm9JYDh6NIipdC6Anqh
# d5NbZcPuF3S8QYYq3AhMjJKMkS2ed0QfaNaodHfbDlsyi1aLM73ZY8hJnTrFxeoz
# C9Lxoxv0i77Zs1eLO94Ep3oisiSuLsdwxb5OgyYI+wu9qU+ZCOEQKHKqzQIDAQAB
# o4IBVzCCAVMwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwcwYIKwYBBQUHAQEEZzBlMCoGCCsGAQUFBzABhh5odHRw
# Oi8vdHMtb2NzcC53cy5zeW1hbnRlYy5jb20wNwYIKwYBBQUHMAKGK2h0dHA6Ly90
# cy1haWEud3Muc3ltYW50ZWMuY29tL3Rzcy1jYS1nMi5jZXIwPAYDVR0fBDUwMzAx
# oC+gLYYraHR0cDovL3RzLWNybC53cy5zeW1hbnRlYy5jb20vdHNzLWNhLWcyLmNy
# bDAoBgNVHREEITAfpB0wGzEZMBcGA1UEAxMQVGltZVN0YW1wLTIwNDgtMjAdBgNV
# HQ4EFgQURsZpow5KFB7VTNpSYxc/Xja8DeYwHwYDVR0jBBgwFoAUX5r1blzMzHSa
# 1N197z/b7EyALt0wDQYJKoZIhvcNAQEFBQADggEBAHg7tJEqAEzwj2IwN3ijhCcH
# bxiy3iXcoNSUA6qGTiWfmkADHN3O43nLIWgG2rYytG2/9CwmYzPkSWRtDebDZw73
# BaQ1bHyJFsbpst+y6d0gxnEPzZV03LZc3r03H0N45ni1zSgEIKOq8UvEiCmRDoDR
# EfzdXHZuT14ORUZBbg2w6jiasTraCXEQ/Bx5tIB7rGn0/Zy2DBYr8X9bCT2bW+IW
# yhOBbQAuOA2oKY8s4bL0WqkBrxWcLC9JG9siu8P+eJRRw4axgohd8D20UaF5Mysu
# e7ncIAkTcetqGVvP6KUwVyyJST+5z3/Jvz4iaGNTmr1pdKzFHTx/kuDDvBzYBHUw
# ggajMIIFi6ADAgECAhAPqEkGFdcAoL4hdv3F7G29MA0GCSqGSIb3DQEBBQUAMGUx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9v
# dCBDQTAeFw0xMTAyMTExMjAwMDBaFw0yNjAyMTAxMjAwMDBaMG8xCzAJBgNVBAYT
# AlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2Vy
# dC5jb20xLjAsBgNVBAMTJURpZ2lDZXJ0IEFzc3VyZWQgSUQgQ29kZSBTaWduaW5n
# IENBLTEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCcfPmgjwrKiUtT
# mjzsGSJ/DMv3SETQPyJumk/6zt/G0ySR/6hSk+dy+PFGhpTFqxf0eH/Ler6QJhx8
# Uy/lg+e7agUozKAXEUsYIPO3vfLcy7iGQEUfT/k5mNM7629ppFwBLrFm6aa43Abe
# ro1i/kQngqkDw/7mJguTSXHlOG1O/oBcZ3e11W9mZJRru4hJaNjR9H4hwebFHsng
# lrgJlflLnq7MMb1qWkKnxAVHfWAr2aFdvftWk+8b/HL53z4y/d0qLDJG2l5jvNC4
# y0wQNfxQX6xDRHz+hERQtIwqPXQM9HqLckvgVrUTtmPpP05JI+cGFvAlqwH4KEHm
# x9RkO12rAgMBAAGjggNDMIIDPzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYI
# KwYBBQUHAwMwggHDBgNVHSAEggG6MIIBtjCCAbIGCGCGSAGG/WwDMIIBpDA6Bggr
# BgEFBQcCARYuaHR0cDovL3d3dy5kaWdpY2VydC5jb20vc3NsLWNwcy1yZXBvc2l0
# b3J5Lmh0bTCCAWQGCCsGAQUFBwICMIIBVh6CAVIAQQBuAHkAIAB1AHMAZQAgAG8A
# ZgAgAHQAaABpAHMAIABDAGUAcgB0AGkAZgBpAGMAYQB0AGUAIABjAG8AbgBzAHQA
# aQB0AHUAdABlAHMAIABhAGMAYwBlAHAAdABhAG4AYwBlACAAbwBmACAAdABoAGUA
# IABEAGkAZwBpAEMAZQByAHQAIABDAFAALwBDAFAAUwAgAGEAbgBkACAAdABoAGUA
# IABSAGUAbAB5AGkAbgBnACAAUABhAHIAdAB5ACAAQQBnAHIAZQBlAG0AZQBuAHQA
# IAB3AGgAaQBjAGgAIABsAGkAbQBpAHQAIABsAGkAYQBiAGkAbABpAHQAeQAgAGEA
# bgBkACAAYQByAGUAIABpAG4AYwBvAHIAcABvAHIAYQB0AGUAZAAgAGgAZQByAGUA
# aQBuACAAYgB5ACAAcgBlAGYAZQByAGUAbgBjAGUALjASBgNVHRMBAf8ECDAGAQH/
# AgEAMHkGCCsGAQUFBwEBBG0wazAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGln
# aWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3J0MIGBBgNVHR8EejB4MDqgOKA2
# hjRodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290
# Q0EuY3JsMDqgOKA2hjRodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRB
# c3N1cmVkSURSb290Q0EuY3JsMB0GA1UdDgQWBBR7aM4pqsAXvkl64eU/1qf3RY81
# MjAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzANBgkqhkiG9w0BAQUF
# AAOCAQEAe3IdZP+IyDrBt+nnqcSHu9uUkteQWTP6K4feqFuAJT8Tj5uDG3xDxOaM
# 3zk+wxXssNo7ISV7JMFyXbhHkYETRvqcP2pRON60Jcvwq9/FKAFUeRBGJNE4Dyah
# YZBNur0o5j/xxKqb9to1U0/J8j3TbNwj7aqgTWcJ8zqAPTz7NkyQ53ak3fI6v1Y1
# L6JMZejg1NrRx8iRai0jTzc7GZQY1NWcEDzVsRwZ/4/Ia5ue+K6cmZZ40c2cURVb
# QiZyWo0KSiOSQOiG3iLCkzrUm2im3yl/Brk8Dr2fxIacgkdCcTKGCZlyCXlLnXFp
# 9UH/fzl3ZPGEjb6LHrJ9aKOlkLEM/zCCBqkwggWRoAMCAQICEAd+v5PimrXIy2Op
# NVvw4rEwDQYJKoZIhvcNAQEFBQAwbzELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERp
# Z2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEuMCwGA1UEAxMl
# RGlnaUNlcnQgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EtMTAeFw0xNDAzMDYw
# MDAwMDBaFw0xNTAyMjUxMjAwMDBaMHUxCzAJBgNVBAYTAlBMMRswGQYDVQQIExJa
# YWNob2RuaW9wb21vcnNraWUxETAPBgNVBAcTCEtvc3phbGluMRowGAYDVQQKExFC
# YXJ0b3N6IEJpZWxhd3NraTEaMBgGA1UEAxMRQmFydG9zeiBCaWVsYXdza2kwggEi
# MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCXWsOTV3sfxKH6LQ35wtn15F/b
# L4MffaYyYReMlbRxQr4dHcCISP80k75lOq6XTY4GzCBOUrYrLzBYdK0MqdH5Gvt0
# Wg/RO5qHG615E+M1pFHcyJrJ7be2yDXuUnekDUak5SBAu6YAxmXkstYs0efS5fOm
# 7v2WPAlneRwe5vk/RaXOHXHmcFIygpCbk5/D9xr2dDXSRhvEjR7Gu8fqP/4U5HpV
# oP+SJHkCt9l+dXXDo3AWpExENZBTEzeMaIfpHb1iVJocet+Swerx54hiJ0McJeRu
# 9gysvl1HQ6HSBvwSLWPb57qd76KHMYAHu2SrepgCZj+BimRPFI063EsjcJCFAgMB
# AAGjggM5MIIDNTAfBgNVHSMEGDAWgBR7aM4pqsAXvkl64eU/1qf3RY81MjAdBgNV
# HQ4EFgQUiN2MhL1ZJLwqbtaD/rI5klOxyDwwDgYDVR0PAQH/BAQDAgeAMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMHMGA1UdHwRsMGowM6AxoC+GLWh0dHA6Ly9jcmwzLmRp
# Z2ljZXJ0LmNvbS9hc3N1cmVkLWNzLTIwMTFhLmNybDAzoDGgL4YtaHR0cDovL2Ny
# bDQuZGlnaWNlcnQuY29tL2Fzc3VyZWQtY3MtMjAxMWEuY3JsMIIBxAYDVR0gBIIB
# uzCCAbcwggGzBglghkgBhv1sAwEwggGkMDoGCCsGAQUFBwIBFi5odHRwOi8vd3d3
# LmRpZ2ljZXJ0LmNvbS9zc2wtY3BzLXJlcG9zaXRvcnkuaHRtMIIBZAYIKwYBBQUH
# AgIwggFWHoIBUgBBAG4AeQAgAHUAcwBlACAAbwBmACAAdABoAGkAcwAgAEMAZQBy
# AHQAaQBmAGkAYwBhAHQAZQAgAGMAbwBuAHMAdABpAHQAdQB0AGUAcwAgAGEAYwBj
# AGUAcAB0AGEAbgBjAGUAIABvAGYAIAB0AGgAZQAgAEQAaQBnAGkAQwBlAHIAdAAg
# AEMAUAAvAEMAUABTACAAYQBuAGQAIAB0AGgAZQAgAFIAZQBsAHkAaQBuAGcAIABQ
# AGEAcgB0AHkAIABBAGcAcgBlAGUAbQBlAG4AdAAgAHcAaABpAGMAaAAgAGwAaQBt
# AGkAdAAgAGwAaQBhAGIAaQBsAGkAdAB5ACAAYQBuAGQAIABhAHIAZQAgAGkAbgBj
# AG8AcgBwAG8AcgBhAHQAZQBkACAAaABlAHIAZQBpAG4AIABiAHkAIAByAGUAZgBl
# AHIAZQBuAGMAZQAuMIGCBggrBgEFBQcBAQR2MHQwJAYIKwYBBQUHMAGGGGh0dHA6
# Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBMBggrBgEFBQcwAoZAaHR0cDovL2NhY2VydHMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEQ29kZVNpZ25pbmdDQS0xLmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBBQUAA4IBAQAAJXpB/DUxvJUxZjJ2
# obIU43JIBO2V5RbfMJiXAGPwQqjRXi0PpYxTcnFAB2ccaZ7tNFdx1Hk2armq6pjz
# ScARlqrFDJSbVDfej/9lhyxux9QgKJvXviHgFFQ3y6VgJObuGSNOynDYkni26TZP
# Px8ZfWzITls0Ax1b2029BpRgyHRTEhIvvOwTIc+qVWMbSeaOEYR2U7bB0QuBgNWt
# ZK/utQ25VA91IcELj2NTbf/sNMmZBqXvnX6E8ie37Ipl5fEtTq90a/9fz8WdbCmE
# /IKjEoGAckq5gbjelBG0rOzEQFewlBEXiLZ4sK8vJTeKhZNH/IfrdunRqAEzUlFI
# frplMYIENDCCBDACAQEwgYMwbzELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lD
# ZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEuMCwGA1UEAxMlRGln
# aUNlcnQgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EtMQIQB36/k+KatcjLY6k1
# W/DisTAJBgUrDgMCGgUAoHgwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkq
# hkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGC
# NwIBFTAjBgkqhkiG9w0BCQQxFgQUUZU4VEVjBUdCm7YoHCvRF7/lJLUwDQYJKoZI
# hvcNAQEBBQAEggEAdTGfYB3LOicFDFmApwTMZFugY6Vb0T1+5IYpGE/+eGtudkKD
# EQ8IUNGMKS9bVib2Ta0dMj6iavtJjIqcW4MRyonrWbYOCn5yQba9uTsDoS4FU6Sd
# Ng1sKQyl2vv18HHXhNc2XFszBdSxd2JqWZg5uWCbCDoa8EOX8Ld5do2WssHvpaTp
# tI+fMLJAY+s6Wwb+iSnXKEH0FPe5Ny8mb6ghqkYLebC2aLdHnu8JkfBocYX6IyPG
# m4HwdqDd+2bPt223BfVDzkTgFU9oO3X2e/kcDwxqlNTSkbcVKOurXsDzTLJDDuGn
# pRqtWSAzeh9woZyl/gy8FEfdmo2dZUchyalJraGCAgswggIHBgkqhkiG9w0BCQYx
# ggH4MIIB9AIBATByMF4xCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRTeW1hbnRlYyBD
# b3Jwb3JhdGlvbjEwMC4GA1UEAxMnU3ltYW50ZWMgVGltZSBTdGFtcGluZyBTZXJ2
# aWNlcyBDQSAtIEcyAhAOz/Q4yP6/NW4E2GqYGxpQMAkGBSsOAwIaBQCgXTAYBgkq
# hkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0xNDA5MzAxNDM5
# MjhaMCMGCSqGSIb3DQEJBDEWBBQ06GhZDTgUBdQGjh7vhHhNG5FgczANBgkqhkiG
# 9w0BAQEFAASCAQA5ObTrFTe8DKAFaMFWSaOH5xUci3U3KMDkYKYrucWHfilzUI5G
# ytS1GwGwkjstwAN/Aug2p54nRQj7bfoSy6u7uNIO4Nd9HFO6jPB3iVKI/fLdnqzp
# mVcQjLC0IW1u3oloF+fyzTI4xDwn9j/PTTnZijbrxIVWzXed4DCSQzVyvq7R54PQ
# ets6AZfNp+KRN/VQ5MzTRP6rO1UIZgRAVBtUpAT12J993FpZXCCCdNZUudzCeche
# N671zZ7MD67rik0QPVwYRqvf9m8vdiimpepolEs/QR4LIoM2kqkHpHddGm6RfPN7
# rrcbZE/7bSzCCmX3SWcku34gz44DitN4pDr5
# SIG # End signature block
