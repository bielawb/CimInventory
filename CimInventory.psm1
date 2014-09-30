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
            $properties = @{}
            foreach ($property in $columnNames) {
                $properties.Add($property, $row.$property)
            }
            $Out = New-Object -TypeName PSObject -Property $properties
            if ($Type) {
                $Out.PSTypeNames.Insert(0,$Type)
            }
            $Out
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
        $properties = @{}
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
        New-Object PSObject -Property $properties | 
            Add-Member -TypeName ITPro.Cim.Object -PassThru
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
# MIIQDwYJKoZIhvcNAQcCoIIQADCCD/wCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUGUn/RFNqchjB5lt4o/cfGCDm
# Yo+ggg1UMIIGozCCBYugAwIBAgIQD6hJBhXXAKC+IXb9xextvTANBgkqhkiG9w0B
# AQUFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVk
# IElEIFJvb3QgQ0EwHhcNMTEwMjExMTIwMDAwWhcNMjYwMjEwMTIwMDAwWjBvMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMS4wLAYDVQQDEyVEaWdpQ2VydCBBc3N1cmVkIElEIENvZGUg
# U2lnbmluZyBDQS0xMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnHz5
# oI8KyolLU5o87BkifwzL90hE0D8ibppP+s7fxtMkkf+oUpPncvjxRoaUxasX9Hh/
# y3q+kCYcfFMv5YPnu2oFKMygFxFLGCDzt73y3Mu4hkBFH0/5OZjTO+tvaaRcAS6x
# ZummuNwG3q6NYv5EJ4KpA8P+5iYLk0lx5ThtTv6AXGd3tdVvZmSUa7uISWjY0fR+
# IcHmxR7J4Ja4CZX5S56uzDG9alpCp8QFR31gK9mhXb37VpPvG/xy+d8+Mv3dKiwy
# RtpeY7zQuMtMEDX8UF+sQ0R8/oREULSMKj10DPR6i3JL4Fa1E7Zj6T9OSSPnBhbw
# JasB+ChB5sfUZDtdqwIDAQABo4IDQzCCAz8wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMIIBwwYDVR0gBIIBujCCAbYwggGyBghghkgBhv1sAzCC
# AaQwOgYIKwYBBQUHAgEWLmh0dHA6Ly93d3cuZGlnaWNlcnQuY29tL3NzbC1jcHMt
# cmVwb3NpdG9yeS5odG0wggFkBggrBgEFBQcCAjCCAVYeggFSAEEAbgB5ACAAdQBz
# AGUAIABvAGYAIAB0AGgAaQBzACAAQwBlAHIAdABpAGYAaQBjAGEAdABlACAAYwBv
# AG4AcwB0AGkAdAB1AHQAZQBzACAAYQBjAGMAZQBwAHQAYQBuAGMAZQAgAG8AZgAg
# AHQAaABlACAARABpAGcAaQBDAGUAcgB0ACAAQwBQAC8AQwBQAFMAIABhAG4AZAAg
# AHQAaABlACAAUgBlAGwAeQBpAG4AZwAgAFAAYQByAHQAeQAgAEEAZwByAGUAZQBt
# AGUAbgB0ACAAdwBoAGkAYwBoACAAbABpAG0AaQB0ACAAbABpAGEAYgBpAGwAaQB0
# AHkAIABhAG4AZAAgAGEAcgBlACAAaQBuAGMAbwByAHAAbwByAGEAdABlAGQAIABo
# AGUAcgBlAGkAbgAgAGIAeQAgAHIAZQBmAGUAcgBlAG4AYwBlAC4wEgYDVR0TAQH/
# BAgwBgEB/wIBADB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDAdBgNVHQ4EFgQUe2jOKarAF75JeuHl
# P9an90WPNTIwHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZI
# hvcNAQEFBQADggEBAHtyHWT/iMg6wbfp56nEh7vblJLXkFkz+iuH3qhbgCU/E4+b
# gxt8Q8TmjN85PsMV7LDaOyEleyTBcl24R5GBE0b6nD9qUTjetCXL8KvfxSgBVHkQ
# RiTROA8moWGQTbq9KOY/8cSqm/baNVNPyfI902zcI+2qoE1nCfM6gD08+zZMkOd2
# pN3yOr9WNS+iTGXo4NTa0cfIkWotI083OxmUGNTVnBA81bEcGf+PyGubnviunJmW
# eNHNnFEVW0ImclqNCkojkkDoht4iwpM61Jtopt8pfwa5PA69n8SGnIJHQnEyhgmZ
# cgl5S51xafVB/385d2TxhI2+ix6yfWijpZCxDP8wggapMIIFkaADAgECAhAHfr+T
# 4pq1yMtjqTVb8OKxMA0GCSqGSIb3DQEBBQUAMG8xCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xLjAs
# BgNVBAMTJURpZ2lDZXJ0IEFzc3VyZWQgSUQgQ29kZSBTaWduaW5nIENBLTEwHhcN
# MTQwMzA2MDAwMDAwWhcNMTUwMjI1MTIwMDAwWjB1MQswCQYDVQQGEwJQTDEbMBkG
# A1UECBMSWmFjaG9kbmlvcG9tb3Jza2llMREwDwYDVQQHEwhLb3N6YWxpbjEaMBgG
# A1UEChMRQmFydG9zeiBCaWVsYXdza2kxGjAYBgNVBAMTEUJhcnRvc3ogQmllbGF3
# c2tpMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAl1rDk1d7H8Sh+i0N
# +cLZ9eRf2y+DH32mMmEXjJW0cUK+HR3AiEj/NJO+ZTqul02OBswgTlK2Ky8wWHSt
# DKnR+Rr7dFoP0TuahxuteRPjNaRR3Miaye23tsg17lJ3pA1GpOUgQLumAMZl5LLW
# LNHn0uXzpu79ljwJZ3kcHub5P0Wlzh1x5nBSMoKQm5Ofw/ca9nQ10kYbxI0exrvH
# 6j/+FOR6VaD/kiR5ArfZfnV1w6NwFqRMRDWQUxM3jGiH6R29YlSaHHrfksHq8eeI
# YidDHCXkbvYMrL5dR0Oh0gb8Ei1j2+e6ne+ihzGAB7tkq3qYAmY/gYpkTxSNOtxL
# I3CQhQIDAQABo4IDOTCCAzUwHwYDVR0jBBgwFoAUe2jOKarAF75JeuHlP9an90WP
# NTIwHQYDVR0OBBYEFIjdjIS9WSS8Km7Wg/6yOZJTscg8MA4GA1UdDwEB/wQEAwIH
# gDATBgNVHSUEDDAKBggrBgEFBQcDAzBzBgNVHR8EbDBqMDOgMaAvhi1odHRwOi8v
# Y3JsMy5kaWdpY2VydC5jb20vYXNzdXJlZC1jcy0yMDExYS5jcmwwM6AxoC+GLWh0
# dHA6Ly9jcmw0LmRpZ2ljZXJ0LmNvbS9hc3N1cmVkLWNzLTIwMTFhLmNybDCCAcQG
# A1UdIASCAbswggG3MIIBswYJYIZIAYb9bAMBMIIBpDA6BggrBgEFBQcCARYuaHR0
# cDovL3d3dy5kaWdpY2VydC5jb20vc3NsLWNwcy1yZXBvc2l0b3J5Lmh0bTCCAWQG
# CCsGAQUFBwICMIIBVh6CAVIAQQBuAHkAIAB1AHMAZQAgAG8AZgAgAHQAaABpAHMA
# IABDAGUAcgB0AGkAZgBpAGMAYQB0AGUAIABjAG8AbgBzAHQAaQB0AHUAdABlAHMA
# IABhAGMAYwBlAHAAdABhAG4AYwBlACAAbwBmACAAdABoAGUAIABEAGkAZwBpAEMA
# ZQByAHQAIABDAFAALwBDAFAAUwAgAGEAbgBkACAAdABoAGUAIABSAGUAbAB5AGkA
# bgBnACAAUABhAHIAdAB5ACAAQQBnAHIAZQBlAG0AZQBuAHQAIAB3AGgAaQBjAGgA
# IABsAGkAbQBpAHQAIABsAGkAYQBiAGkAbABpAHQAeQAgAGEAbgBkACAAYQByAGUA
# IABpAG4AYwBvAHIAcABvAHIAYQB0AGUAZAAgAGgAZQByAGUAaQBuACAAYgB5ACAA
# cgBlAGYAZQByAGUAbgBjAGUALjCBggYIKwYBBQUHAQEEdjB0MCQGCCsGAQUFBzAB
# hhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wTAYIKwYBBQUHMAKGQGh0dHA6Ly9j
# YWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRENvZGVTaWduaW5n
# Q0EtMS5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQUFAAOCAQEAACV6Qfw1
# MbyVMWYydqGyFONySATtleUW3zCYlwBj8EKo0V4tD6WMU3JxQAdnHGme7TRXcdR5
# Nmq5quqY80nAEZaqxQyUm1Q33o//ZYcsbsfUICib174h4BRUN8ulYCTm7hkjTspw
# 2JJ4tuk2Tz8fGX1syE5bNAMdW9tNvQaUYMh0UxISL7zsEyHPqlVjG0nmjhGEdlO2
# wdELgYDVrWSv7rUNuVQPdSHBC49jU23/7DTJmQal751+hPInt+yKZeXxLU6vdGv/
# X8/FnWwphPyCoxKBgHJKuYG43pQRtKzsxEBXsJQRF4i2eLCvLyU3ioWTR/yH63bp
# 0agBM1JRSH66ZTGCAiUwggIhAgEBMIGDMG8xCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xLjAsBgNV
# BAMTJURpZ2lDZXJ0IEFzc3VyZWQgSUQgQ29kZSBTaWduaW5nIENBLTECEAd+v5Pi
# mrXIy2OpNVvw4rEwCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKEC
# gAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwG
# CisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFKPXPaDIpcusssXEfqQmkSiTYChr
# MA0GCSqGSIb3DQEBAQUABIIBAEu/dhJwafb6Vaw910ad78zbu9jYV3GjzDRU3lpE
# WTetRhO2da5VQ1Sgh7WIepDdSUtOto7bsJbtIo3KGj1VpdrABHndQKLMi8/lF4gh
# mizXQVcy7pA1tPETLSTECxEFLcPO+LNUSViDZEWPOBHhuQjvYwGZHUitc5XkOJE7
# jZyrGq4TyrP45BlFMfawXTGDN8hn324uJD0Kyhguhvn2lvDaL8TfIwfzzxAcc1TH
# u24QhLBg7BJn+J9xOpMcJP3BlG3hBckxm7SiKnWBCqDk9rnHFmIueXxswYkFs+SG
# ooULZrCs9K5uAPH3RK8ujI9ZgpfxtztucbJP1StFQfPf9WI=
# SIG # End signature block
