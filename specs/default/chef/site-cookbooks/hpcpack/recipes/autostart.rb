#
# Cookbook Name:: hpcpack
# Recipe:: autostart
#
include_recipe "hpcpack::_update_path"

config_dir = "#{node['cyclecloud']['home']}\\config"
bootstrap_dir = node['cyclecloud']['bootstrap']
install_dir = "#{bootstrap_dir}/hpcpack-autoscaler-installer"
install_pkg = "#{node['hpcpack']['autoscaler']['package']}"

# Default : c:\cycle\hpcpack-autoscaler
autoscaler_bin_dir="#{node[:cyclecloud][:home]}/../hpcpack-autoscaler/bin" 

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
    not_if { ::File.exists?("#{autoscaler_bin_dir}/azhpcpack.ps1") }
end

autostart_disabled = node['cyclecloud']['cluster']['autoscale']['start_enabled'] == false ? '--disable-autostart' : ''
powershell_script 'initconfig' do
    code <<-EOH
    echo "(Re-)Generating config (initially generated by install.ps1...)"
    & #{autoscaler_bin_dir}\\azhpcpack.ps1 initconfig --cluster-name #{node['cyclecloud']['cluster']['name']} `
        --username #{node['cyclecloud']['config']['username']} `
        --password #{node['cyclecloud']['config']['password']} `
        --url #{node['cyclecloud']['config']['web_server']} #{autostart_disabled} `
        --idle-timeout #{node['cyclecloud']['cluster']['autoscale']['idle_time_after_jobs']} `
        --boot-timeout #{node['cyclecloud']['cluster']['autoscale']['provisioning_timeout']} `
        --vm_retention_days #{node['cyclecloud']['cluster']['autoscale']['vm_retention_days']} `
        --log-config #{config_dir}\\autoscale_logging.conf  | Set-Content -Encoding ASCII #{config_dir}\\autoscale.json
    EOH
    not_if { ::File.exists?("#{config_dir}/autoscale.json") }
end

windows_task 'cyclecloud-hpc-autoscaler' do
    task_name "Cyclecloud-HPC-Autoscaler"
    command   "powershell.exe -file #{autoscaler_bin_dir}\\azhpcpack.ps1 autoscale"
    user      "#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}"
    password  node['hpcpack']['ad']['admin']['password']
    frequency :minute
    frequency_modifier 1
    only_if { node['cyclecloud']['cluster']['autoscale']['start_enabled'] }
end
