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

if ! node['hpcpack']['cert']['filename'].nil?
  jetpack_download node['hpcpack']['cert']['filename'] do
    project "hpcpack"
    not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{node['hpcpack']['cert']['filename']}") }
  end
end
