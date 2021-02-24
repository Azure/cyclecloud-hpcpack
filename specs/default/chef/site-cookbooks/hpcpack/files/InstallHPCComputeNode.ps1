<#
    The script to install HPC Pack compute node
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

$ErrorActionPreference = "Stop"
Set-StrictMode -Version latest
if($PSVersionTable.PSVersion -lt '3.0' -or ([System.Environment]::OSVersion.Version.Major -eq 6 -and [System.Environment]::OSVersion.Version.Minor -eq 1))
{
    $currentDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    Import-Module ServerManager
    $netfx35 = Get-WindowsFeature -Name Net-Framework-Core -ErrorAction SilentlyContinue
    if(($null -ne $netfx35) -and (-not $netfx35.Installed))
    {
        Add-WindowsFeature -Name NET-Framework-Core
    }
}
else 
{
    $currentDir = $PSScriptRoot
}

Import-Module $currentDir\InstallUtilities.psm1
$logFolder = "C:\Windows\Temp\HPCSetupLogs\HPCComputeNode-" + [System.DateTimeOffset]::UtcNow.ToString("yyyyMMdd-HHmmss")
if(-not (Test-Path $logFolder))
{
    New-Item -Path $logFolder -ItemType Directory -Force
}

Set-LogFile -Path "$logFolder\setup.txt"
if (!(Test-Path -Path $SetupFilePath -PathType Leaf)) 
{
    throw "HPC Pack setup package not found: $SetupFilePath"
}
### Import the certificate
if($PsCmdlet.ParameterSetName -eq "PfxFilePath")
{
    if (!(Test-Path -Path $PfxFilePath -PathType Leaf)) 
    {
        Write-Log "The PFX certificate file doesn't exist: $PfxFilePath" -LogLevel Error
        throw "The PFX certificate file doesn't exist: $PfxFilePath"
    }
    $pfxCert = Import-PfxCertificate -FilePath $PfxFilePath -Password $PfxFilePassword -CertStoreLocation Cert:\LocalMachine\My
    $SSLThumbprint = $pfxCert.Thumbprint
}
elseif($PsCmdlet.ParameterSetName -eq "KeyVaultCertificate")
{
    $pfxCert = Install-KeyVaultCertificate -VaultName $VaultName -CertName $VaultCertName -CertStoreLocation Cert:\LocalMachine\My
    $SSLThumbprint = $pfxCert.Thumbprint
}
else 
{
    $pfxCert = Get-Item Cert:\LocalMachine\My\$SSLThumbprint -ErrorAction SilentlyContinue
    if($null -eq $pfxCert)
    {
        Write-Log "The certificate Cert:\LocalMachine\My\$SSLThumbprint doesn't exist" -LogLevel Error
        throw "The certificate Cert:\LocalMachine\My\$SSLThumbprint doesn't exist"
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
$exitCode = -1
if([System.IO.Path]::GetFileName($SetupFilePath) -eq 'Setup.exe')
{
    # setup.exe file
    $setupArgs = "-unattend -Quiet -ComputeNode:`"$ClusterConnectionString`" -SSLThumbprint:$SSLThumbprint"
    $retry = 0
    while($true)
    {
        Write-Verbose "Installing HPC Pack compute node"
        $p = Start-Process -FilePath $SetupFilePath -ArgumentList $setupArgs -PassThru -Wait
        $exitCode = $p.ExitCode
        if($exitCode -eq 0)
        {
            Write-Verbose "Succeed to Install HPC compute node"
            break
        }
        if($exitCode -eq 3010)
        {
            Write-Verbose "Succeed to Install HPC compute node, a reboot is required."
            break
        }
        if($exitCode -eq 13818)
        {
            throw "Failed to Install HPC compute node (errCode=$exitCode): the certificate doesn't meet the requirements."
        }

        if($retry++ -lt 5)
        {
            Write-Warning "Failed to Install HPC compute node (errCode=$exitCode), retry later..."
            Clear-DnsClientCache
            Start-Sleep -Seconds ($retry * 10)
        }
        else
        {
            throw "Failed to Install HPC compute node (ErrCode=$exitCode)"
        }
    }    
}
else 
{
    # HpcCompute_x64.msi file
    $setupDir = [System.IO.Path]::GetDirectoryName($SetupFilePath)
    $nonDomainJoin = 1
    $computerSystemObj = Get-WmiObject Win32_ComputerSystem
    if($computerSystemObj.PartOfDomain)
    {
        $nonDomainJoin = 0
    }

    if(-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server Compact Edition\v4.0\ENU"))
    {
        $ssceFilePath = Join-Path -Path $setupDir -ChildPath 'SSCERuntime_x64-ENU.exe'
        if(Test-Path $ssceFilePath -PathType Leaf)
        {
            $sqlceLogFile = Join-Path -Path $logFolder -ChildPath "SqlCompactInstallLogX64.log"
            $p = Start-Process -FilePath $ssceFilePath -ArgumentList "/i /passive /l*v `"$sqlceLogFile`"" -Wait -PassThru
            Write-Log "Sql Server Compact installation finished with exit code $($p.ExitCode)."
        }
    }
    $timeStamp = Get-Date -Format "yyyy_MM_dd-hh_mm_ss"
    $mpiFilePath = Join-Path -Path $setupDir -ChildPath 'MsMpiSetup.exe'
    if(Test-Path $mpiFilePath -PathType Leaf)
    {
        $mpiLogFile = Join-Path -Path $logFolder -ChildPath "msmpi-$timeStamp.log"
        Start-Process -FilePath $mpiFilePath -ArgumentList "/unattend /force /minimal /log `"$mpiLogFile`" /verbose" -Wait
    }

    $timeStamp = Get-Date -Format "yyyy_MM_dd-hh_mm_ss"
    $cnLogFile = Join-Path -Path $logFolder -ChildPath "hpccompute-$timeStamp.log"
    $setupArgs = "REBOOT=ReallySuppress CLUSTERCONNSTR=`"$ClusterConnectionString`" SSLTHUMBPRINT=`"$SSLThumbprint`" NONDOMAINJOIN=`"#$nonDomainJoin`""
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$SetupFilePath`" $setupArgs /quiet /norestart /l+v* `"$cnLogFile`"" -Wait -PassThru
    $exitCode = $p.ExitCode
    Write-Log "HPC compute node installation finished with exit code $exitCode."
    if($exitCode -eq 3010)
    {
        Write-Log "A system reboot is required after HPC compute node installation."
    }
}

exit $exitCode