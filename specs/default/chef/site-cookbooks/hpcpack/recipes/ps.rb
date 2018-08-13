bootstrap_dir = node['cyclecloud']['bootstrap']

cookbook_file "#{bootstrap_dir}\\unzip.ps1" do
    source "unzip.ps1"
    action :create
  end

reboot 'Restart Computer' do
    action :nothing
end

jetpack_download "Win8.1AndW2K12R2-KB3134758-x64.msu" do
    project "hpcpack"
end

# Requires reboot - do a version case here.
#execute "install PSv5" do
#    command "wusa.exe #{node[:jetpack][:downloads]}\\Win8.1AndW2K12R2-KB3134758-x64.msu /quiet && type nul > #{node['cyclecloud']['bootstrap']}\\ps_upgraded.txt"
#    returns [0, 1641, 1618, 2359302]
#end

msu_package 'Install WMF Update KB3134758' do
    source "#{node[:jetpack][:downloads]}\\Win8.1AndW2K12R2-KB3134758-x64.msu"
    action :install
  end

powershell_script "Install NuGet" do
    code "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force"
    only_if "!(Get-PackageProvider NuGet -ListAvailable)"
end

powershell_script "enable wsman" do
    code 'winrm quickconfig -quiet'
    not_if 'Test-WSMan -ComputerName localhost'
end

jetpack_download node[:hpcpack][:cert][:filename] do
    project "hpcpack"
end

powershell_script 'install hpc comm cert' do
    code <<-EOH
    $secpasswd = ConvertTo-SecureString '#{node[:hpcpack][:cert][:password]}' -AsPlainText -Force
    Get-ChildItem -Path #{node[:jetpack][:downloads]}\\#{node[:hpcpack][:cert][:filename]} | Import-PfxCertificate -CertStoreLocation Cert:\\localmachine\\My -Exportable -Password $secpasswd
    EOH
end

if node['hpcpack']['install_logviewer']
  jetpack_download "LogViewer1.2.2.4.zip" do
    project "hpcpack"
  end

  powershell_script 'unzip-LogViewer' do
    code "#{bootstrap_dir}\\unzip.ps1 #{node[:jetpack][:downloads]}\\LogViewer1.2.2.4.zip #{bootstrap_dir}"
    creates "#{bootstrap_dir}\\LogViewer1.2.2.4"
  end
end

# Allow users to uninstall specific windows updates (some apps haven't been ported to latest sec. updates)
# - Most updates require a reboot, but we're going to reboot to join domain later, so delay
if not node['hpcpack']['uninstall_updates'].nil?
  node['hpcpack']['uninstall_updates'].each do |kb|
    kb_number = kb.downcase
    kb_number.slice!('kb')
    powershell_script "uninstall windows update: #{kb}" do
      code <<-EOH
      wusa.exe /uninstall /kb:#{kb_number} /norestart /quiet
      EOH
      only_if "dism.exe /online /get-packages | findstr /I #{kb}"
      notifies :reboot_now, 'reboot[Restart Computer]', :delayed
    end
  end
end




