#
# Cookbook Name:: hpcpack
# Recipe:: autostart
#

bootstrap_dir = node['cyclecloud']['bootstrap']

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


# Get the autoscale packages
%w{cyclecloud_api-8.0.1-py2.py3-none-any.whl cyclecloud-scalelib-0.1.1.tar.gz hpcpack-autoscaler.zip}.each do |pkg|
    jetpack_download pkg do
        project "hpcpack"
        dest "#{bootstrap_dir}/#{pkg}"
        not_if { ::File.exists?("#{bootstrap_dir}/#{pkg}") }
    end
end

powershell_script 'unzip-autoscaler' do
    code "#{bootstrap_dir}\\unzip.ps1 #{bootstrap_dir}\\hpcpack-autoscaler.zip #{bootstrap_dir}"
    creates "#{bootstrap_dir}\\hpcpack-autoscaler"
end
