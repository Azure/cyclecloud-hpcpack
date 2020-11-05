include_recipe "hpcpack::_get_secrets"

bootstrap_dir = node['cyclecloud']['bootstrap']

cookbook_file "#{bootstrap_dir}\\unzip.ps1" do
  source "unzip.ps1"
  action :create
end

reboot 'Restart Computer' do
  action :nothing
end


# TEMPORARY: Schedule a converge on boot explicitly (this should be in base coookbooks soon)
# This is required to bring the node back online after restart
taskrun = "#{node[:cyclecloud][:home]}\\bin\\jetpack converge --mode=install"
powershell_script "Add on-boot re-converge" do
  code "schtasks /Create /TN chef_onboot /SC ONSTART /F /RU 'System' /TR '#{taskrun}'"
  ignore_failure true
end
Chef::Log.info('Modified scheduled task for on-boot converges.')

powershell_script "Ensure TLS 1.2 for nuget" do
  code <<-EOH
  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Wow6432Node\\Microsoft\\.NetFramework\\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\.NetFramework\\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
  EOH
end

# TODO: Do we need this if we don't install DSC?   It seems to take >2min to install
# powershell_script "Install NuGet" do
#   code <<-EOH
#   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#   Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
#   EOH
#   only_if <<-EOH
#     [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#     !(Get-PackageProvider NuGet -ListAvailable)
#   EOH
# end
#
# powershell_script "enable wsman" do
#   code 'winrm quickconfig -quiet'
#   not_if 'Test-WSMan -ComputerName localhost'
# end


# Get the nuget binary as well
jetpack_download "nuget.exe" do
  project "hpcpack"
  dest "#{node[:cyclecloud][:home]}/bin/nuget.exe"
  not_if { ::File.exists?("#{node[:cyclecloud][:home]}/bin/nuget.exe") }
end


jetpack_download node['hpcpack']['cert']['filename'] do
  project "hpcpack"
  not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cert']['filename']}") }
end

log "Installing hpc comm cert with pass :  [#{node['hpcpack']['cert']['password']}]..." do level :warn end
powershell_script 'install hpc comm cert' do
  code <<-EOH
  $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['cert']['password']}' -AsPlainText -Force
  Get-ChildItem -Path #{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']} | Import-PfxCertificate -CertStoreLocation Cert:\\localmachine\\My -Exportable -Password $secpasswd
  EOH
end

# install the certificate in Root CA
powershell_script 'install-hpc-cert' do
  code <<-EOH
  $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
  $cert.Import('#{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']}','#{node['hpcpack']['cert']['password']}','DefaultKeySet,MachineKeySet,PersistKeySet')

  $store = new-object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreName]::Root, "localmachine")
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]'ReadWrite')
  $store.Add($cert)
  $store.Close()
  EOH
end


if node['hpcpack']['install_logviewer']
  jetpack_download "LogViewer1.2.2.4.zip" do
    project "hpcpack"
  end

  powershell_script 'unzip-LogViewer' do
    code "#{bootstrap_dir}\\unzip.ps1 #{node['jetpack']['downloads']}\\LogViewer1.2.2.4.zip #{bootstrap_dir}"
    creates "#{bootstrap_dir}\\LogViewer1.2.2.4"
  end
end

