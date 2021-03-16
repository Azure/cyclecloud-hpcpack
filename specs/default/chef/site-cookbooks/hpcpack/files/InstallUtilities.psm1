<#
Generic utilities for the HPC Pack installation utilities
NOTE:
    This module requires PowerShell 2.0 or later. 
#>

# Must disable Progress bar
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = 'stop'
Set-StrictMode -Version latest
$Script:LogFile = $null

function Set-LogFile
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $Script:LogFile = $Path
}

function Write-Log
{
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory=$false, Position=1)]
        [ValidateSet("Error", "Warning", "Information", "Detail")]
        [string]$LogLevel = "Information"
    )

    $formattedMessage = '[{0:s}][{1}] {2}' -f ([DateTimeOffset]::Now.ToString('u')), $LogLevel, $Message
    Write-Verbose -Verbose "${formattedMessage}"
    if($Script:LogFile)
    {
        try
        {
            $formattedMessage | Out-File $Script:LogFile -Append
        }
        catch
        {
        }
    }

    if($LogLevel -eq "Error")
    {
        throw $Message
    }
}

function DownloadFile
{
    param(
        [parameter(Mandatory = $true)]
        [string] $SourceUrl,

        [parameter(Mandatory = $true)]
        [string] $DestPath,

        [parameter(Mandatory = $false)]
        [ValidateRange(1, 60)]
        [int] $Retry = 5,

        [parameter(Mandatory = $false)]
        [ValidateRange(1, 60)]
        [int] $RetryInterval = 5
    )

    $Downloader = New-Object System.Net.WebClient
    $fileName = $($SourceUrl -split '/')[-1]
    if(Test-Path -Path $DestPath -PathType Container)
    {
        $DestPath = [IO.Path]::Combine($DestPath, $fileName)
    }

    $downloadRetry = 0
    while($true)
    {
        try
        {
            if(Test-Path -Path $DestPath)
            {
                Remove-Item -Path $DestPath -Force -Confirm:$false -ErrorAction SilentlyContinue
            }

            $Downloader.DownloadFile($SourceUrl, $DestPath)
            break
        }
        catch
        {
            if($downloadRetry -lt $Retry)
            {
                Write-Log "Failed to download from $SourceUrl, retry after $RetryInterval seconds: $_" -LogLevel Warning
                ipconfig /flushdns
                Start-Sleep -Seconds $RetryInterval
                $downloadRetry++
            }
            else
            {
               Write-Log "Failed to download from $SourceUrl : $_" -LogLevel Error
            }
        }
    }
}

function Get-MsiAccessToken
{
    Param
    (
        [parameter(Mandatory = $true)]
        [string] $Resource
    )
    
    $Resource = $Resource.Trim()
    $encodedResource = [uri]::EscapeDataString($Resource)
    $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encodedResource"
    $resp = Invoke-WebRequest -Uri $tokenUri -Method Get -Headers @{Metadata="true"} -UseBasicParsing
    $content =$resp.Content | ConvertFrom-Json
    return $content.access_token
}


function Get-KeyVaultSecretValue
{
    param (
        [parameter(Mandatory = $true)]
        [string] $VaultName,
    
        [parameter(Mandatory = $true)]
        [string] $CertName,
    
        [parameter(Mandatory = $false)]
        [string] $Version = ""
    )

    $access_token = Get-MsiAccessToken -Resource "https://vault.azure.net"
    $secretName = $CertName
    if($Version) {
        $secretName = "$secretName/$Version"
    }
    $getCertUri = "https://${VaultName}.vault.azure.net/secrets/${secretName}?api-version=7.1"
    $resp = Invoke-WebRequest -Uri $getCertUri -Method GET -ContentType "application/json" -Headers @{Authorization ="Bearer $access_token"} -UseBasicParsing
    $content = $resp.Content | ConvertFrom-Json
    return $content.value
}

function Install-KeyVaultCertificate
{
    Param
    (
        [parameter(Mandatory = $true)]
        [string] $VaultName,
    
        [parameter(Mandatory = $true)]
        [string] $CertName,
    
        [parameter(Mandatory = $false)]
        [string] $Version = "",

        [Parameter(Mandatory=$false)]        
        [string] $CertStoreLocation = "Cert:\LocalMachine\My",

        [parameter(Mandatory = $false)]
        [switch] $Exportable
    )
   
    $certBase64String = Get-KeyVaultSecretValue -VaultName $VaultName -CertName $CertName -Version $Version
    $certBytes = [Convert]::FromBase64String($certBase64String)
    $keyFlags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
    if($Exportable)
    {
        $keyFlags = $keyFlags -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @($certBytes,"",$keyFlags)
    $certStore = Get-Item $CertStoreLocation
    try {
        $certStore.Open('ReadWrite')
        $certStore.Add($cert)
    }
    finally {
        $certStore.Close()
    }

    return $cert
}

<#
    Implementation of some functions for Windows Server 2008 R2
    Note: the functions are not fully impelemented, only for HPC Pack installation
#>
if($null -eq (Get-Command -Name Invoke-WebRequest -ErrorAction SilentlyContinue))
{
    function Invoke-WebRequest
    {
        param(
            [Parameter(Mandatory=$true)]      
            [uri] $Uri,
            
            [Parameter(Mandatory=$false)]        
            [string] $Method = "Get",

            [Parameter(Mandatory=$false)]        
            [string] $ContentType = "",

            [Parameter(Mandatory=$false)]        
            [hashtable] $Headers,

            [Parameter(Mandatory=$false)]        
            [switch] $UseBasicParsing            
        )

        $request = [System.Net.WebRequest]::Create($Uri)
        $request.Method = $Method
        if($ContentType)
        {
            $request.ContentType = $ContentType
        }
        if ($PSBoundParameters.ContainsKey('Headers'))
        {
            $Headers.GetEnumerator() | ForEach-Object { $request.Headers.Add($_.Key, $_.Value)}
        }

        $response = $request.GetResponse()
        $contentReader = New-Object -TypeName System.IO.StreamReader -ArgumentList $response.GetResponseStream()
        $content = $contentReader.ReadToEnd()
        $StatusCode = [int]$response.StatusCode
        $contentReader.Dispose()
        return New-Object psobject -Property @{
                    StatusCode=$StatusCode
                    Content=$content
                }
    }
}

if($null -eq (Get-Command -Name ConvertTo-Json -ErrorAction SilentlyContinue))
{
    Add-Type -assembly system.web.extensions
    function ConvertTo-Json
    {
        param(
            [Parameter(Mandatory=$true, Position = 0, ValueFromPipeline=$true)]
            [object] $InputObject,
            
            [Parameter(Mandatory=$false)]        
            [Int] $Depth
        )

        $jsSerializer = New-Object system.web.script.serialization.javascriptSerializer
        return $jsSerializer.Serialize($InputObject)
    }
}

if($null -eq (Get-Command -Name ConvertFrom-Json -ErrorAction SilentlyContinue))
{
    Add-Type -assembly system.web.extensions
    function ConvertFrom-Json
    {
        param(
            [Parameter(Mandatory=$true, Position = 0, ValueFromPipeline=$true)]
            [string] $InputObject,
            
            [Parameter(Mandatory=$false)]        
            [Int] $Depth
        )
        
        $jsSerializer = New-Object system.web.script.serialization.javascriptSerializer

        return ,$jsSerializer.DeserializeObject($InputObject)
    }
}

if($null -eq (Get-Command -Name Import-PfxCertificate -ErrorAction SilentlyContinue))
{
    function Import-PfxCertificate
    {
        param(
            [Parameter(Mandatory=$true)]        
            [string] $FilePath,

            [Parameter(Mandatory=$true)]        
            [securestring] $Password,

            [Parameter(Mandatory=$true)]        
            [string] $CertStoreLocation,

            [Parameter(Mandatory=$false)]        
            [switch] $Exportable 
        )
        
        $keyFlags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
        if($Exportable)
        {
            $keyFlags = $keyFlags -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
        }
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $PfxFilePath,$Password,$keyFlags
        $certStore = Get-Item $CertStoreLocation
        try {
            $certStore.Open('ReadWrite')
            $certStore.Add($cert)
        }
        finally {
            $certStore.Close()
        }

        return $cert
    }    
}

if($null -eq (Get-Command -Name Export-Certificate -ErrorAction SilentlyContinue))
{
    function Export-Certificate
    {
        param(
            [Parameter(Mandatory=$true, Position = 0, ValueFromPipeline=$true)]
            [object] $Cert,
            
            [Parameter(Mandatory=$true)]        
            [string] $FilePath
        )
        
        if($cert -is [string]) {
            $cert = Get-Item $Cert
        }
        $certBytes = $Cert.Export('Cert')
        [System.IO.File]::WriteAllBytes($FilePath, $certBytes)
        Get-Item -Path $FilePath
    }
}

if($null -eq (Get-Command -Name Import-Certificate -ErrorAction SilentlyContinue))
{
    function Import-Certificate
    {
        param(
            [Parameter(Mandatory=$true, Position = 0, ValueFromPipeline=$true)]
            [string] $FilePath,
            
            [Parameter(Mandatory=$true)]        
            [string] $CertStoreLocation
        )
        
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $FilePath
        $certStore = Get-Item $CertStoreLocation
        try {
            $certStore.Open('ReadWrite')
            $certStore.Add($cert)
        }
        finally {
            $certStore.Close()
        }

        return $cert
    }
}

if($null -eq (Get-Command -Name Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue))
{
    function Get-DnsClientGlobalSetting
    {
        $suffixes = @()
        $props = Get-Item HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters | Get-ItemProperty | Select-Object -Property SearchList
        if($props.SearchList)
        {
            $suffixes = $props.SearchList -split ','
        }

        return New-Object psobject -Property @{
            SuffixSearchList = $suffixes
        }
    }
}

if($null -eq (Get-Command -Name Set-DnsClientGlobalSetting -ErrorAction SilentlyContinue))
{
    function Set-DnsClientGlobalSetting
    {
        param(
            [Parameter(Mandatory=$true)]
            [string[]] $SuffixSearchList
        )
        
        $netConfig = [wmiclass]'win32_Networkadapterconfiguration'
        [void]$netConfig.SetDNSSuffixSearchOrder($SuffixSearchList)
    }
}

Export-ModuleMember -Function *