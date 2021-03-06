include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_ps"
include_recipe "hpcpack::_join-ad-domain"

bootstrap_dir = node['cyclecloud']['bootstrap']
mod_dir = "#{bootstrap_dir}\\installHpcSingleHeadNode"
hpcpack2012_dir = "#{bootstrap_dir}\\hpcpack2012"
dsc_script = "InstallHpcSingleHeadNode.ps1"
modules_dir = "C:\\Program\ Files\\WindowsPowerShell\\Modules"

directory mod_dir
directory hpcpack2012_dir


[
   'xPSDesiredStateConfiguration'
].each do |feature|
   powershell_script "Uninstall #{feature} headnode" do
       code "Uninstall-Module -Name #{feature} -Force"
       only_if "(Get-Module #{feature} -ListAvailable)"
   end
end

cookbook_file "#{bootstrap_dir}\\#{dsc_script}.zip" do
   source "#{dsc_script}.zip"
   action :create
end

cookbook_file "#{hpcpack2012_dir}\\HPCHNPrepare.ps1" do
   source "hpcpack2012/HPCHNPrepare.ps1"
   action :create
end

cookbook_file "#{hpcpack2012_dir}\\PrepareHN.ps1" do
   source "hpcpack2012/PrepareHN.ps1"
   action :create
end

powershell_script 'unzip-InstallHpcSingleHeadNode' do
    code "#{bootstrap_dir}\\unzip.ps1 #{bootstrap_dir}\\#{dsc_script}.zip #{mod_dir}"
    creates "#{mod_dir}\\#{dsc_script}"
end


powershell_script 'set-dsc-InstallHpcSingleHeadNode' do
    code <<-EOH
    $Acl = Get-Acl "#{modules_dir}"
    Set-Acl "#{mod_dir}" $Acl
    $oModPath = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
    [Environment]::SetEnvironmentVariable("PSModulePath", $oModPath + ";" + $pwd, "Machine")
    $env:PSModulePath = $env:PSModulePath + ";" + $pwd
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $cert.Import("#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}","#{node['hpcpack']['cert']['password']}","DefaultKeySet")
    $secpasswd = ConvertTo-SecureString "#{node['hpcpack']['ad']['admin']['password']}" -AsPlainText -Force
    $mycreds = New-Object System.Management.Automation.PSCredential ('#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}', $secpasswd)
    $cd = @{
        AllNodes = @(
            @{
                NodeName = 'localhost'
                PSDscAllowPlainTextPassword = $true
                PSDscAllowDomainUser = $true
            }
        )}

    . .\\InstallHpcSingleHeadNode.ps1
    InstallHpcSingleHeadNode -SetupUserCredential $mycreds `
         -SSLThumbprint $cert.Thumbprint -ConfigurationData $cd
    Start-DscConfiguration .\\InstallHpcSingleHeadNode -Wait -Force -Verbose
    [Environment]::SetEnvironmentVariable("PSModulePath", $oModPath, "Machine")
    $env:PSModulePath = $oModPath
    EOH
    cwd mod_dir
    not_if 'Get-Service "HpcManagement"  -ErrorAction SilentlyContinue'
end

powershell_script 'HPCPack2012-PrepareHN' do
    code <<-EOH
    # Could use node['fqdn'], but might not work with multiple interfaces?
    $fqdn = '#{node['hostname']}.#{node['hpcpack']['ad']['domain']}'
    $base64Password = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('#{node['hpcpack']['ad']['admin']['password']}'))
    powershell.exe -ExecutionPolicy Unrestricted -File "#{hpcpack2012_dir}\\PrepareHN.ps1" -DomainFQDN $fqdn -PublicDnsName $fqdn -AdminUserName "#{node['hpcpack']['ad']['admin']['name']}" -AdminBase64Password "$base64Password" > "#{hpcpack2012_dir}\\PrepareHN.log"
    EOH
    cwd hpcpack2012_dir
    only_if 'Add-PsSnapin Microsoft.HPC; (Get-Command Get-HpcNode).Version.Major -lt 5'
end


include_recipe "hpcpack::autostart" if node['cyclecloud']['cluster']['autoscale']['start_enabled']

powershell_script 'Set HPC Pack Configuration' do
    code <<-EOH
    Add-PsSnapin Microsoft.HPC

    Set-HpcClusterProperty -HeartbeatInterval #{node['hpcpack']['config']['HeartbeatInterval']} -InactivityCount #{node['hpcpack']['config']['InactivityCount']}

    EOH
end

