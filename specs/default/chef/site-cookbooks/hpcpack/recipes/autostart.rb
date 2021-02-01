#
# Cookbook Name:: hpcpack
# Recipe:: autostart
#

bootstrap_dir = node['cyclecloud']['bootstrap']
install_dir = "#{bootstrap_dir}/hpcpack-autoscaler-installer"
install_pkg = "cyclecloud-hpcpack-pkg-1.2.0.zip"
cert_pem = "hpc-comm.pem"

# Default : c:\cycle\hpcpack-autoscaler
autoscaler_dir="#{node[:cyclecloud][:home]}\\..\\hpcpack-autoscaler" 

# template "#{bootstrap_dir}\\autoscale-logging-wrapper.ps1" do
#     source "autoscale-logging-wrapper.ps1.erb"
# end

# template "#{bootstrap_dir}\\autoscale.ps1" do
#     source "autoscale.ps1.erb"
#     action :create
#     notifies :run, 'powershell_script[initDB-autoscale]', :immediately
#     variables(
#         :estimated_cores_per_node => 4,  # HACK: Until we have autoscale-by-node, estimate min_node_count
#         :min_node_count => node['hpcpack']['min_node_count'],
#         :timespan_hr => node['hpcpack']['job']['default_runtime']['hr'],
#         :timespan_min => node['hpcpack']['job']['default_runtime']['min'],
#         :timespan_sec => node['hpcpack']['job']['default_runtime']['sec'],
#         :threshold_hr => node['hpcpack']['job']['add_node_threshold']['hr'],
#         :threshold_min => node['hpcpack']['job']['add_node_threshold']['min'],
#         :threshold_sec => node['hpcpack']['job']['add_node_threshold']['sec'],
#         :wait_before_jobs_s => node['cyclecloud']['cluster']['autoscale']['idle_time_before_jobs'],
#         :wait_after_jobs_s => node['cyclecloud']['cluster']['autoscale']['idle_time_after_jobs']
#         )
# end

# powershell_script 'initDB-autoscale' do
#     code "#{bootstrap_dir}\\autoscale.ps1 -initialize >> #{bootstrap_dir}\\autoscale.log"
#     action :nothing
# end

# windows_task 'hpc-autoscale' do
#     task_name "HPCAutoscale"
#     command   "powershell.exe -file #{bootstrap_dir}\\autoscale-logging-wrapper.ps1"
#     user      "#{node['hpcpack']['ad']['domain']}\\#{node['hpcpack']['ad']['admin']['name']}"
#     password  node['hpcpack']['ad']['admin']['password']
#     frequency :minute
#     #only_if { node['cyclecloud']['cluster']['autoscale']['start_enabled'] }
# end

directory install_dir do
    action :create
end


jetpack_download cert_pem do
    project "hpcpack"
    not_if { ::File.exists?("#{node['jetpack']['downloads']}/#{cert_pem}") }
end

powershell_script 'unzip-LogViewer' do
    code "Copy-Item -Path #{node['jetpack']['downloads']}\\#{cert_pem} -Destination #{bootstrap_dir}\\#{cert_pem}"
    creates "#{bootstrap_dir}\\#{cert_pem}"
    not_if { ::File.exists?("#{bootstrap_dir}/#{cert_pem}") }
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
