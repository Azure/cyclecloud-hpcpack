include_recipe "hpcpack::_get_secrets"

bootstrap_dir = node['cyclecloud']['bootstrap']

cookbook_file "#{bootstrap_dir}\\unzip.ps1" do
  source "unzip.ps1"
  action :create
end

reboot 'Restart Computer' do
    action :nothing
end

# KB3134758 should be superceded by WMF 5.1 which is pre-installed
# jetpack_download "Win8.1AndW2K12R2-KB3134758-x64.msu" do
#   project "hpcpack"
#   not_if { ::File.exists?("#{node['jetpack']['downloads']}/Win8.1AndW2K12R2-KB3134758-x64.msu") }
# end

# msu_package 'Install WMF Update KB3134758' do
#   source "#{node['jetpack']['downloads']}/Win8.1AndW2K12R2-KB3134758-x64.msu"
#   action :install
# end

powershell_script "Install NuGet" do
    code "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force"
    only_if "!(Get-PackageProvider NuGet -ListAvailable)"
end

powershell_script "enable wsman" do
    code 'winrm quickconfig -quiet'
    not_if 'Test-WSMan -ComputerName localhost'
end

jetpack_download node['hpcpack']['cert']['filename'] do
  project "hpcpack"
  not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cert']['filename']}") }
end

powershell_script 'install hpc comm cert' do
    code <<-EOH
    $secpasswd = ConvertTo-SecureString '#{node['hpcpack']['cert']['password']}' -AsPlainText -Force
    Get-ChildItem -Path #{node['jetpack']['downloads']}\\#{node['hpcpack']['cert']['filename']} | Import-PfxCertificate -CertStoreLocation Cert:\\localmachine\\My -Exportable -Password $secpasswd
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

# Allow users to uninstall specific windows updates (some apps haven't been ported to latest sec. updates)
# - Most updates require a reboot, and domain join may fail if we delay, so uninstall all
#   and then reboot immediately
if not node['hpcpack']['uninstall_updates'].nil?
  reboot_required = false
  ruby_block "set_reboot_required" do
    block do
      reboot_required = true
    end
    action :nothing
  end

  node['hpcpack']['uninstall_updates'].each do |kb|
    kb_number = kb.downcase
    kb_number.slice!('kb')
    powershell_script "uninstall windows update: #{kb}" do
      code <<-EOH
      wusa.exe /uninstall /kb:#{kb_number} /norestart /quiet
      EOH
      only_if "dism.exe /online /get-packages | findstr /I #{kb}"
      notifies :run, 'ruby_block[set_reboot_required]', :immediately    
    end
  end

  # Notify the reboot resource after loop
  ruby_block "reboot_after_updates" do
    block do
      Chef::Log.warn("Rebooting after uninstalling #{node['hpcpack']['uninstall_updates'].inspect}...")
    end
    action :run
    only_if { reboot_required == true }
    notifies :reboot_now, 'reboot[Restart Computer]', :immediately
  end
end
