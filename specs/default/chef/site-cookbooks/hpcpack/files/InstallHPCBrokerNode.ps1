<#
    The script to install HPC Pack broker node
    Author :  Microsoft HPC Pack team
    Version:  1.0
#>
Param
(
    [parameter(Mandatory = $true)]
    [string] $ClusterConnectionString,

    [parameter(Mandatory = $true)]
    [string] $SetupFilePath,

    [parameter(Mandatory = $true, ParameterSetName='SSLThumbprint')]
    [string] $SSLThumbprint,

    [parameter(Mandatory = $true, ParameterSetName='PfxFilePath')]
    [string] $PfxFilePath,

    [parameter(Mandatory = $true, ParameterSetName='PfxFilePath')]
    [securestring] $PfxFilePassword,

    [parameter(Mandatory = $true, ParameterSetName='KeyVaultCertificate')]
    [string] $VaultName,

    [parameter(Mandatory = $true, ParameterSetName='KeyVaultCertificate')]
    [string] $VaultCertName
)

# Must disable Progress bar
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
Set-StrictMode -Version latest
Import-Module $PSScriptRoot\InstallUtilities.psm1
$logFolder = "C:\Windows\Temp\HPCSetupLogs"
if(-not (Test-Path $logFolder))
{
    New-Item -Path $logFolder -ItemType Directory -Force
}
$logfileName = "installhpcbn-" + [System.DateTimeOffset]::UtcNow.ToString("yyyyMMdd-HHmmss") + ".txt"
Set-LogFile -Path "$logFolder\$logfileName"

$cmdLine = $PSCommandPath
foreach($boundParam in $PSBoundParameters.GetEnumerator())
{
    if($boundParam.Key -notmatch 'Password' -and $boundParam.Key -notmatch 'Credential') {
        $cmdLine += " -$($boundParam.Key) $($boundParam.Value)"
    }
}
Write-Log $cmdLine

if (!(Test-Path -Path $SetupFilePath -PathType Leaf)) 
{
    Write-Log "HPC Pack setup package not found: $SetupFilePath" -LogLevel Error
}

### Import the certificate
if($PsCmdlet.ParameterSetName -eq "PfxFilePath")
{
    if (!(Test-Path -Path $PfxFilePath -PathType Leaf)) 
    {
        Write-Log "The PFX certificate file doesn't exist: $PfxFilePath" -LogLevel Error
    }
    try {
        $pfxCert = Import-PfxCertificate -FilePath $PfxFilePath -Password $PfxFilePassword -CertStoreLocation Cert:\LocalMachine\My
        $SSLThumbprint = $pfxCert.Thumbprint       
    }
    catch {
        Write-Log "Failed to import PfxFile $PfxFilePath : $_" -LogLevel Error
    }
}
elseif($PsCmdlet.ParameterSetName -eq "KeyVaultCertificate")
{
    Write-Log "Install certificate $VaultCertName from key vault $VaultName"
    try {
        $pfxCert = Install-KeyVaultCertificate -VaultName $VaultName -CertName $VaultCertName -CertStoreLocation Cert:\LocalMachine\My
        $SSLThumbprint = $pfxCert.Thumbprint
    }
    catch {
        Write-Log "Failed to install certificate $VaultCertName from key vault $VaultName : $_" -LogLevel Error
    }
}
else 
{
    $pfxCert = Get-Item Cert:\LocalMachine\My\$SSLThumbprint -ErrorAction SilentlyContinue
    if($null -eq $pfxCert)
    {
        Write-Log "The certificate Cert:\LocalMachine\My\$SSLThumbprint doesn't exist" -LogLevel Error
    }    
}

if($pfxCert.Subject -eq $pfxCert.Issuer)
{
    if(-not (Test-Path Cert:\LocalMachine\Root\$SSLThumbprint))
    {
        Write-Log "Installing self-signed HPC communication certificate to Cert:\LocalMachine\Root\$SSLThumbprint"
        $cerFileName = "$env:Temp\HpcPackComm.cer"
        Export-Certificate -Cert "Cert:\LocalMachine\My\$SSLThumbprint" -FilePath $cerFileName | Out-Null
        Import-Certificate -FilePath $cerFileName -CertStoreLocation Cert:\LocalMachine\Root  | Out-Null
        Remove-Item $cerFileName -Force -ErrorAction SilentlyContinue
    }
}

# Uninstall the old HPC Pack installation
$hpcRegKey = Get-Item HKLM:\SOFTWARE\Microsoft\HPC -ErrorAction SilentlyContinue
if($hpcRegKey -and ("ClusterConnectionString" -in $hpcRegKey.Property))
{
    $curClusConnStr = ($hpcRegKey | Get-ItemProperty | Select-Object -Property ClusterConnectionString).ClusterConnectionString
    if($curClusConnStr -ne $ClusterConnectionString)
    {
        # Check whether old HPC components installed, uninstall them if installed
        $UninstallStrings = @(Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" | Get-ItemProperty -Name UninstallString -ErrorAction SilentlyContinue | %{$_.UninstallString})
        $hpcv5ExcelGuid = "F22EA2E8-08F0-4675-B10F-60C939D336D6"
        $hpcv5ServerGuid = "02985CCE-D7D5-40FF-9C81-6334523210F9"
        $hpcv5ClientGuid = "186B7E1A-6C30-46AB-AB83-4AE925377838"
        $hpcv6ServerGuid = "A001F5CA-5D6A-4BDA-9885-36E7A8EBABCC"
        $hpcv6ClientGuid = "C10E3B39-4D82-48D4-AB7C-BDF16FEEAD6D"
        $oldHpcComponentExists = $false
        foreach($pcode in @($hpcv5ExcelGuid, $hpcv5ServerGuid, $hpcv6ServerGuid, $hpcv5ClientGuid, $hpcv6ClientGuid))
        {
            if($UninstallStrings | Where-Object{$_ -match $pcode})
            {
                $oldHpcComponentExists = $true
                Write-Log "Old HPC component {$pcode} found, uninstalling it..."
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/quiet /passive /x {$pcode}" -NoNewWindow -Wait
            }
        }
        
        if($oldHpcComponentExists -and (Test-Path "C:\HPCPack2016"))
        {
            Write-Log "Removing the old HPC setup package C:\HPCPack2016 ..."
            Remove-item C:\HPCPack2016 -Force -Recurse -ErrorAction SilentlyContinue
        }        
    }
}

$setupArgs = "-unattend -Quiet -BrokerNode:`"$ClusterConnectionString`" -SSLThumbprint:$SSLThumbprint"
$retry = 0
while($true)
{
    Write-Log "Installing HPC Pack broker node"
    $p = Start-Process -FilePath $SetupFilePath -ArgumentList $setupArgs -PassThru -Wait
    $exitCode = $p.ExitCode
    if($exitCode -eq 0)
    {
        Write-Log "Succeed to Install HPC broker node"
        break
    }
    if($exitCode -eq 3010)
    {
        Write-Log "Succeed to Install HPC broker node, a reboot is required."
        break
    }
    if($exitCode -eq 13818)
    {
        Write-Log "Failed to Install HPC broker node (errCode=$exitCode): the certificate doesn't meet the requirements." -LogLevel Error
    }

    if($retry++ -lt 5)
    {
        Write-Warning "Failed to Install HPC broker node (errCode=$exitCode), retry later..." -LogLevel Warning
        Clear-DnsClientCache
        Start-Sleep -Seconds ($retry * 10)
    }
    else
    {
        Write-Log "Failed to Install HPC broker node (ErrCode=$exitCode)" -LogLevel Error
    }
}
Write-Log "End running $($MyInvocation.MyCommand.Definition)"
exit $exitCode