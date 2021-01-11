include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_common"
include_recipe "hpcpack::_join-ad-domain" if node['hpcpack']['headNodeAsDC'] == false
include_recipe "hpcpack::_install-ad-domain" if node['hpcpack']['headNodeAsDC']

bootstrap_dir = node['cyclecloud']['bootstrap']

cookbook_file "#{bootstrap_dir}\\InstallHPCHeadNode.ps1" do
  source "InstallHPCHeadNode.ps1"
  action :create
end

powershell_script "Install-NuGet" do
    code <<-EOH
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    EOH
    only_if <<-EOH
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      !(Get-PackageProvider NuGet -ListAvailable)
    EOH
end

powershell_script 'Install-HpcSingleHeadNode' do
    code <<-EOH
    $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['ad']['admin']['password']}' -AsPlainText -Force
    $domainCred = New-Object System.Management.Automation.PSCredential ("#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}", $secpasswd)
    $seccertpasswd = ConvertTo-SecureString '#{node['hpcpack']['cert']['password']}' -AsPlainText -Force
    #{bootstrap_dir}\\InstallHPCHeadNode.ps1 -ClusterName $env:ComputerName -SetupFilePath "C:\\HPCPack2019\\Setup.exe" -PfxFilePath "#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}" -PfxFilePassword $seccertpasswd -SetupCredential $domainCred
    EOH
    user "#{node['hpcpack']['ad']['admin']['name']}"
    password "#{node['hpcpack']['ad']['admin']['password']}"
    not_if 'Get-Service "HpcManagement"  -ErrorAction SilentlyContinue'
end

include_recipe "hpcpack::autostart" if node['cyclecloud']['cluster']['autoscale']['start_enabled']
