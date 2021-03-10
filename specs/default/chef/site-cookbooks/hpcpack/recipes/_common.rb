include_recipe "hpcpack::_get_secrets"

bootstrap_dir = node['cyclecloud']['bootstrap']

cookbook_file "#{bootstrap_dir}\\unzip.ps1" do
  source "unzip.ps1"
  action :create
end

cookbook_file "#{bootstrap_dir}\\InstallUtilities.psm1" do
  source "InstallUtilities.psm1"
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

# HPC Pack 2016 requires NetFx 4.6, HPC Pack 2019 requires NetFx 4.7.2
# if not installed, directly use NetFx 4.8
jetpack_download "ndp48-web.exe" do
  project "hpcpack"
  not_if { ::File.exists?("#{node['jetpack']['downloads']}/ndp48-web.exe") }
  not_if <<-EOH
    $targetNetFxVer = 461808
    $hpcVersion = "#{node['hpcpack']['version']}"
    if ($hpcVersion -eq '2016')
    {
      $targetNetFxVer = 393295
    }
    $netfxVer = Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" -ErrorAction SilentlyContinue | Select -Property Release
    $netfxVer -and ($netfxVer.Release -ge $targetNetFxVer)
  EOH
end

powershell_script 'install-netfx-4.8' do
  code <<-EOH
    $ndpLogFile = "#{bootstrap_dir}\\ndp48.log"
    Start-Process -FilePath #{node['jetpack']['downloads']}\\ndp48-web.exe -ArgumentList "/q /norestart /serialdownload /log `"$ndpLogFile`"" -Wait -PassThru
  EOH
  not_if <<-EOH
    $targetNetFxVer = 461808
    $hpcVersion = "#{node['hpcpack']['version']}"
    if ($hpcVersion -eq '2016')
    {
      $targetNetFxVer = 393295
    }
    $netfxVer = Get-ItemProperty "HKLM:\\SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" -ErrorAction SilentlyContinue | Select -Property Release
    $netfxVer -and ($netfxVer.Release -ge $targetNetFxVer)
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

if ! node['hpcpack']['cert']['filename'].nil?
  jetpack_download node['hpcpack']['cert']['filename'] do
    project "hpcpack"
    not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cert']['filename']}") }
  end
end
