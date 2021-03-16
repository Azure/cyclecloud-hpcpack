

if node[:hpcpack][:hn][:hostname].nil?
    cluster_UID = node[:hpcpack][:hn][:clusterUID]
    if cluster_UID.nil?
      cluster_UID = node[:cyclecloud][:cluster][:id]
    end
  
    node_role = node[:hpcpack][:hn][:role]
    if !node_role.nil?
      log "Searching for the HPC Headnode in cluster: #{cluster_UID}, role: #{node_role}" do level :info end
      server_node = cluster.search(:clusterUID => cluster_UID, :role => node_role, :singular => "HPC Headnode not found")
    else
      node_recipe = node[:hpcpack][:hn][:recipe]
      if !node_recipe.nil?
        log "Searching for the HPC Headnode in cluster: #{cluster_UID}, recipe: #{node_recipe}" do level :info end
        server_node = cluster.search(:clusterUID => cluster_UID, :recipe => node_recipe, :singular => "HPC Headnode not found")
      else
        log "Must specify node[:hpcpack][:hn][:role] or node[:hpcpack][:hn][:recipe] for search." do level :error end
      end
    end
    node.default[:hpcpack][:hn][:hostname] = server_node[:hostname]
    node.default[:hpcpack][:hn][:ip_address] = server_node[:ipaddress]
    node.default[:hpcpack][:hn][:fqdn] = server_node[:fqdn]
    log "Head node #{server_node[:hostname]} found: IP=#{server_node[:ipaddress]}, FQDN=#{server_node[:fqdn]}" do level :info end
end

if node[:hpcpack][:headNodeAsDC]
  log "Head node (IP=#{node.default[:hpcpack][:hn][:ip_address]}) acts as domain controller" do level :info end
  node.default[:hpcpack][:ad][:dnsServer] = node.default[:hpcpack][:hn][:ip_address]
end