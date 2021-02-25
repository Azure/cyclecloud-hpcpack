#
# Cookbook Name:: hpcpack
# Recipe:: autostart
#

config_dir = "#{node[:cyclecloud][:home]}\\config"
bootstrap_dir = node['cyclecloud']['bootstrap']
install_dir = "#{bootstrap_dir}/hpcpack-autoscaler-installer"
install_pkg = "cyclecloud-hpcpack-pkg-1.2.0.zip"

# Default : c:\cycle\hpcpack-autoscaler
autoscaler_dir="#{node[:cyclecloud][:home]}\\..\\hpcpack-autoscaler" 

cookbook_file "#{config_dir}\\autoscale_logging.conf" do
  source "autoscale_logging.conf"
  action :create
end

directory install_dir do
    action :create
end

powershell_script 'Prepare-CertPemFile' do
    code <<-EOH
    $pfxFile = "#{node['hpcpack']['cert']['filename']}"
    $pfxFilePath = "#{node['jetpack']['downloads']}\\$pfxFile"
    if($pfxFile -and (Test-Path -Path $pfxFilePath)) {
        openssl pkcs12 -in "#{node['jetpack']['downloads']}\\$pfxFile" -out "#{config_dir}\\hpc-comm.pem" -nodes -password pass:'#{node['hpcpack']['cert']['password']}'
    }
    else {
        $sslThumbprint = (Get-ItemProperty -Name SSLThumbprint -Path "HKLM:\\SOFTWARE\\Microsoft\\HPC").SSLThumbprint
        $pfxFile = [System.Guid]::NewGuid().ToString() + '.pfx'
        $pfxFile = "#{config_dir}\\$pfxFile"
        $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['ad']['admin']['password']}' -AsPlainText -Force
        Export-PfxCertificate -Cert Cert:\\LocalMachine\\My\\$sslThumbprint -FilePath $pfxFile -Password $secpasswd
        openssl pkcs12 -in "$pfxFile" -out "#{config_dir}\\hpc-comm.pem" -nodes -password pass:'#{node['hpcpack']['ad']['admin']['password']}'
        Remove-Item -Path $pfxFile -Force -ErrorAction SilentlyContinue
    }
    $acl = New-Object -TypeName System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($True, $False)
    foreach ($id in @("BUILTIN\\Administrators", "NT AUTHORITY\\SYSTEM")) {
        $aclRule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @($id, 'FullControl', 'Allow')
        $acl.AddAccessRule($aclRule)
    }
    Set-Acl -Path "#{config_dir}\\hpc-comm.pem" -AclObject $acl
    EOH
    creates "#{config_dir}\\hpc-comm.pem"
    not_if { ::File.exists?("#{config_dir}/hpc-comm.pem") }
end

# Get the autoscale packages
jetpack_download install_pkg do
    project "hpcpack"
    not_if { ::File.exists?("#{node['jetpack']['downloads']}\\#{install_pkg}") }
end

powershell_script 'unzip-autoscaler' do
    code "#{bootstrap_dir}\\unzip.ps1 #{node['jetpack']['downloads']}\\#{install_pkg} #{install_dir}"
    creates "#{install_dir}\\install.ps1"
end

# TODO: Do we need a guard here?   
#(Currently relies on install.ps1 to be safely re-runnable (idempotent or upgradable))
powershell_script 'install-autoscaler' do
    code "& #{install_dir}\\install.ps1"
end

windows_task 'cyclecloud-hpc-autoscaler' do
    task_name "Cyclecloud-HPC-Autoscaler"
    command   "powershell.exe -file C:\\cycle\\jetpack\\bin\\azcc_autoscale.ps1"
    user      "#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}"
    password  node['hpcpack']['ad']['admin']['password']
    frequency :minute
    frequency_modifier 1
    only_if { node['cyclecloud']['cluster']['autoscale']['start_enabled'] }
end
