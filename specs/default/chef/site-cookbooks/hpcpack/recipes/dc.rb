include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_ps"

bootstrap_dir = node['cyclecloud']['bootstrap']
mod_dir = "#{bootstrap_dir}\\CreateADPDC"
dsc_script = "CreateADPDC.ps1"
modules_dir = "C:\\Program\ Files\\WindowsPowerShell\\Modules"

cookbook_file "#{bootstrap_dir}\\#{dsc_script}.zip" do
   source "#{dsc_script}.zip"
   action :create
end

directory "#{mod_dir}" do
end

powershell_script "unzip-#{dsc_script}" do
    code "#{bootstrap_dir}\\unzip.ps1 #{bootstrap_dir}\\#{dsc_script}.zip #{mod_dir}"
    creates "#{mod_dir}\\#{dsc_script}"
end

powershell_script 'set-dsc-CreateADPDC' do
    code <<-EOH
    $Acl = Get-Acl "#{modules_dir}"
    Set-Acl "#{mod_dir}" $Acl
    $oModPath = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
    [Environment]::SetEnvironmentVariable("PSModulePath", $oModPath + ";" + $pwd, "Machine")
    $env:PSModulePath = $env:PSModulePath + ";" + $pwd
    $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['ad']['admin']['password']}' -AsPlainText -Force
    $mycreds = New-Object System.Management.Automation.PSCredential ("#{node['hpcpack']['ad']['admin']['name']}", $secpasswd)
    
    $cd = @{
        AllNodes = @(
            @{
                NodeName = 'localhost'
                PSDscAllowPlainTextPassword = $true
            }
        )}
     . .\\CreateADPDC.ps1
    CreateADPDC -DomainName "#{node['hpcpack']['ad']['domain']}" -Admincreds $mycreds `
        -RetryCount 4 -RetryIntervalSec 5 -ConfigurationData $cd
    Start-DscConfiguration .\\CreateADPDC -Wait -Force -Verbose
    [Environment]::SetEnvironmentVariable("PSModulePath", $oModPath, "Machine")
    $env:PSModulePath = $oModPath
    EOH
    cwd mod_dir
    not_if "'#{node['hpcpack']['ad']['domain']}' -eq $(Get-ADDomain | WHERE DNSRoot -Like '#{node['hpcpack']['ad']['domain']}').DNSRoot"
    notifies :reboot_now, 'reboot[Restart Computer]', :immediately
  end
