include_recipe "hpcpack::_get_secrets"

bootstrap_dir = node['cyclecloud']['bootstrap']

cookbook_file "#{bootstrap_dir}\\unzip.ps1" do
  source "unzip.ps1"
  action :create
end

cookbook_file "#{bootstrap_dir}\\LogUtilities.psm1" do
  source "LogUtilities.psm1"
  action :create
end

reboot 'Restart Computer' do
  action :nothing
end


# TEMPORARY: Schedule a converge on boot explicitly (this should be in base coookbooks soon)
# This is required to bring the node back online after restart
taskrun = "#{node[:cyclecloud][:home]}\\bin\\jetpack.cmd converge --mode=install"
powershell_script "Add on-boot re-converge" do
  code "schtasks /Create /TN chef_onboot /SC ONSTART /F /RU 'System' /TR '#{taskrun}'"
  ignore_failure true
end
Chef::Log.info('Modified scheduled task for on-boot converges.')


# Install the dotnet framework if NetFx 4.7.2 or later not installed
# if not installed, directly use NetFx 4.8
jetpack_download "ndp48-web.exe" do
  project "hpcpack"
  not_if { ::File.exists?("#{node['jetpack']['downloads']}/ndp48-web.exe") }
  not_if <<-EOH
    $netfxVer = Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" -ErrorAction SilentlyContinue | Select -Property Release
    $netfxVer -and ($netfxVer.Release -ge 461808)
  EOH
end

powershell_script 'install-netfx-4.8' do
  code <<-EOH
    $ndpLogFile = "#{bootstrap_dir}\\ndp48.log"
    Start-Process -FilePath #{node['jetpack']['downloads']}\\ndp48-web.exe -ArgumentList "/q /norestart /serialdownload /log `"$ndpLogFile`"" -Wait -PassThru
  EOH
  not_if <<-EOH
    $netfxVer = Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" -ErrorAction SilentlyContinue | Select -Property Release
    $netfxVer -and ($netfxVer.Release -ge 461808)
  EOH
  notifies :reboot_now, 'reboot[Restart Computer]', :immediately
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
jetpack_download "nuget.exe" do
  project "hpcpack"
  dest "#{node[:cyclecloud][:home]}/bin/nuget.exe"
  not_if { ::File.exists?("#{node[:cyclecloud][:home]}/bin/nuget.exe") }
end


jetpack_download node['hpcpack']['cert']['filename'] do
  project "hpcpack"
  not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cert']['filename']}") }
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

