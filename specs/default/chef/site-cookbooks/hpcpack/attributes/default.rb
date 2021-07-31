default['hpcpack']['ad']['dnsServer'] = nil
default['hpcpack']['hn']['hostname'] = nil

# HPC Pack Autoscaling configuration
default['hpcpack']['autoscaler']['package'] = "cyclecloud-hpcpack-pkg-2.0.0.zip"

# HPC Pack Configuration options
default['hpcpack']['config']['HeartbeatInterval'] = 30
default['hpcpack']['config']['InactivityCount'] = 10

# If "keyvault" and "password_key" are set, look up key in KeyVault
# (Requires a managed service identity to be associated with the nodes to allow vault access)
default['hpcpack']['keyvault']['vault_name'] = nil
default['hpcpack']['keyvault']['admin']['name_key'] = nil
default['hpcpack']['keyvault']['admin']['password_key'] = nil
default['hpcpack']['keyvault']['cert']['password_key'] = nil
default['hpcpack']['keyvault']['cert']['cert_name'] = nil

default['hpcpack']['ad']['admin']['name'] = nil
default['hpcpack']['ad']['admin']['password'] = nil
default['hpcpack']['cert']['filename'] = nil
default['hpcpack']['cert']['password'] = nil

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

# Allow users to uninstall specific windows updates (some apps haven't been ported to latest sec. updates)
default['hpcpack']['uninstall_updates'] = []
