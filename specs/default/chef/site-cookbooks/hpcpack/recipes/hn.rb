include_recipe "hpcpack::_get_secrets"
include_recipe "hpcpack::_common"
include_recipe "hpcpack::_join-ad-domain" if node['hpcpack']['headNodeAsDC'] == false
include_recipe "hpcpack::_new-ad-domain" if node['hpcpack']['headNodeAsDC']

bootstrap_dir = node['cyclecloud']['bootstrap']

cookbook_file "#{bootstrap_dir}\\InstallHPCHeadNode.ps1" do
  source "InstallHPCHeadNode.ps1"
  action :create
end

powershell_script "Ensure TLS 1.2 for nuget" do
  code <<-EOH
  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\.NetFramework\\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
  if(Test-Path 'HKLM:\\SOFTWARE\\Wow6432Node\\Microsoft\\.NetFramework\\v4.0.30319')
  {
    Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Wow6432Node\\Microsoft\\.NetFramework\\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
  }
  EOH
  not_if <<-EOH
    $strongCrypo = Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\.NetFramework\\v4.0.30319" -ErrorAction SilentlyContinue | Select -Property SchUseStrongCrypto
    $strongCrypo -and ($strongCrypo.SchUseStrongCrypto -eq 1)
  EOH
end

# Get the nuget binary as well
# first try jetpack download, then resort to web download (nuget is not part of the HPC Pack project release)
jetpack_download "try_fetch_nuget_from_locker" do
  project "hpcpack"
  dest "#{node[:cyclecloud][:home]}/bin/nuget.exe"
  ignore_failure true
  not_if { ::File.exists?("#{node[:cyclecloud][:home]}/bin/nuget.exe") }
end
ruby_block "try_fetch_nuget_from_web" do
  block do
    require 'open-uri'
    download = open('https://aka.ms/nugetclidl')
    IO.copy_stream(download, "#{node[:cyclecloud][:home]}/bin/nuget.exe")
  end
  not_if { ::File.exists?("#{node[:cyclecloud][:home]}/bin/nuget.exe") }
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
    $vaultName = "#{node['hpcpack']['keyvault']['vault_name']}"
    $vaultCertName = "#{node['hpcpack']['keyvault']['cert']['cert_name']}"
    if($vaultName -and $vaultCertName) {
      #{bootstrap_dir}\\InstallHPCHeadNode.ps1 -ClusterName $env:ComputerName -VaultName $vaultName -VaultCertName $vaultCertName -SetupCredential $domainCred
    }
    else {
      $seccertpasswd = ConvertTo-SecureString '#{node['hpcpack']['cert']['password']}' -AsPlainText -Force
      #{bootstrap_dir}\\InstallHPCHeadNode.ps1 -ClusterName $env:ComputerName -PfxFilePath "#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}" -PfxFilePassword $seccertpasswd -SetupCredential $domainCred
    }
    EOH
    user "#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}"
    password "#{node['hpcpack']['ad']['admin']['password']}"
    elevated true
    not_if 'Get-Service "HpcManagement"  -ErrorAction SilentlyContinue'
end

include_recipe "hpcpack::autostart" if node['cyclecloud']['cluster']['autoscale']['start_enabled']
