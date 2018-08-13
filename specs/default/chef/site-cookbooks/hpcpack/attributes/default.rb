default['hpcpack']['ad']['dns1'] = "10.0.0.4"
default['hpcpack']['ad']['dns2'] = "8.8.8.8"
default['hpcpack']['hn']['hostname'] = nil

# HPC Pack SOA jobs tend to fail if there are 0 cores when submitted
default['hpcpack']['min_node_count'] = 1

default['hpcpack']['job']['default_runtime']['hr'] = 1
default['hpcpack']['job']['default_runtime']['min'] = 0
default['hpcpack']['job']['default_runtime']['sec'] = 0

default['hpcpack']['job']['add_node_threshold']['hr'] = 1
default['hpcpack']['job']['add_node_threshold']['min'] = 0
default['hpcpack']['job']['add_node_threshold']['sec'] = 0

# for search
default['hpcpack']['hn']['role'] = nil
default['hpcpack']['hn']['recipe'] = "hpcpack::hn"
default['hpcpack']['hn']['clusterUID'] = nil

default['hpcpack']['cert']['filename'] = "hpc-comm.pfx" 
default['hpcpack']['cert']['password'] = ""

default['hpcpack']['install_logviewer'] = false

# Allow users to uninstall specific windows updates (some apps haven't been ported to latest sec. updates)
default['hpcpack']['uninstall_updates'] = []
