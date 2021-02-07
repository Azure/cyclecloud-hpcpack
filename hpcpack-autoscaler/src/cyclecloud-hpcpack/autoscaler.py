import os
import json
import math
import sys
from typing import Any, Dict, List, Optional
from datetime import datetime
from subprocess import check_output, CalledProcessError
import hpc.autoscale.hpclogging as logging
from hpc.autoscale.node.node import Node
from hpc.autoscale.node.nodemanager import NodeManager, new_node_manager
from hpc.autoscale.results import DefaultContextHandler, register_result_handler, BootupResult, ShutdownResult
from hpc.autoscale.util import partition
from .hpcpackdriver import HpcRestClient, GrowDecision
from .commonutil import ci_equals, ci_in, ci_notin, ci_interset, ci_lookup, make_dict, make_dict_single
from .hpcnodehistory import HpcNodeHistory

CONFIG_DEFAULTS = {
    "logging": {
        "config_file": "C:\\cycle\\jetpack\\config\\autoscaler_logging.conf",
    },
    "statefile": "C:\\cycle\\jetpack\\config\\hpcpack_autoscaler_state.json",
    "min_counts": {
        # Min. Instance Counts by NodeGroup name
        # HPC Pack SOA requires a minimum of 1 core or job submission fails
        "default": 1
    },
    "autoscale": {
        "start_enabled": True,
        "idle_time_after_jobs": 300,
        "provisioning_timeout": 1500,
        "max_deallocated_nodes": 300,
    },
    'hpcpack': {
        "pem": "C:\\cycle\\jetpack\\system\\bootstrap\\hpc-comm.pem",
        "hn_hostname": "localhost",
    },
    'cyclecloud': {
        "cluster_name": None,
        "url": None, # "https://cyclecloud_url" or "https://ReturnProxy_ip:37140" when using ReturnProxy
        "username": None,
        "password": None,
        "verify_certificates": False,
    },
}

def autoscale_hpcpack(
    config: Dict[str, Any],
    ctx_handler: DefaultContextHandler = None,
    hpcpack_rest_client: Optional[HpcRestClient] = None,
    dry_run: bool = False,
) -> None:

    if not hpcpack_rest_client:
        hpcpack_rest_client = new_rest_client(config)

    if ctx_handler:
        ctx_handler.set_context("[Sync-Status]")
    autoscale_config = config.get("autoscale") or {}
    # Load history info
    idle_timeout_seconds:int = autoscale_config.get("idle_time_after_jobs") or 900    
    provisioning_timeout_seconds = autoscale_config.get("provisioning_timeout") or 1500
    node_history = HpcNodeHistory(statefile="C:\\cycle\\hpcpack-autoscaler\\state.txt", provisioning_timeout=provisioning_timeout_seconds, idle_timeout=idle_timeout_seconds)

    logging.info("Synchronizing the nodes between Cycle cloud and HPC Pack")
    # Initialize data of History info, cc nodes, HPC Pack nodes, HPC grow decisions
    # Get node list from Cycle Cloud
    node_mgr: NodeManager = new_node_manager(config['cyclecloud'])
    cc_nodes:List[Node] = node_mgr.get_nodes()
    cc_active_node_ids = [n.delayed_node_id.node_id for n in cc_nodes]
    # We only need CC nodes with host name when syncing nodes between CC and HPCPack
    cc_nodes_with_hostname = [n for n in cc_nodes if n.hostname]
    cc_hostnames = [n.hostname for n in cc_nodes_with_hostname]
    # Get compute node list and grow decision from HPC Pack
    hpc_node_groups = hpcpack_rest_client.list_node_groups()
    grow_decisions = hpcpack_rest_client.get_grow_decision()
    logging.info("grow decision: {}".format(grow_decisions))
    hpc_cn_nodes = hpcpack_rest_client.list_computenodes()
    hpc_cn_nodes = [n for n in hpc_cn_nodes if n.active]

    # This function will link node history items, cc nodes and hpc nodes
    node_history.synchronize(cc_nodes, hpc_cn_nodes)

    cc_nodearrays = set([b.nodearray for b in node_mgr.get_buckets()])
    logging.info("Current node arrays in cyclecloud: {}".format(cc_nodearrays))
    # Possible values for HPC NodeState (states marked with * shall not occur for CC nodes):
    #   Unknown, Provisioning, Offline, Starting, Online, Draining, Rejected(*), Removing, NotDeployed(*), Stopping(*) 
    # For node already removed from CC (Unreachable nodes in CycleCloudNodes also considered as already removed in CC):
    #   1. If the current state is a stable state, directly remove
    #   2. If the current state is *ing, do nothing in this round, wait it to go into stable state
    # For shrinking node:
    #   1. If the current state is unknown or offline, directly remove
    #   2. If the current state is online, we shall take offline
    #   3. if neither of above, it must be draining, do nothing in this round, wait it to go into offline
    # For other HPC node which has corresponding CC node: 
    #   1. If the current state is offline, bring it online
    #   2. If the current state if Unknown
    cc_nodeid_to_shrink = []
    hpc_nodes_to_remove = []
    hpc_nodes_to_bring_online = []
    hpc_nodes_to_take_offline = []
    hpc_nodes_to_assign_template = []
    for hpc_node in hpc_cn_nodes:
        if hpc_node.transitioning:
            continue
        if hpc_node.to_remove:
            hpc_nodes_to_remove.append(hpc_node.name)
            continue
        if hpc_node.to_shrink:
            if ci_equals(hpc_node.state, "Online"):
                hpc_nodes_to_take_offline.append(hpc_node.name)
            else:
                hpc_nodes_to_remove.append(hpc_node.name)
                cc_nodeid_to_shrink.append(hpc_node.cc_node_id)
            continue
        if hpc_node.cc_node:
            if ci_equals(hpc_node.state, "Offline"):
                hpc_nodes_to_bring_online.append(hpc_node.name)
            if ci_equals(hpc_node.state, "Unknown"):
                hpc_nodes_to_assign_template.append(hpc_node.name)

    # Create HPC node groups for CC node arrays
    cc_map_hpc_groups = ["CycleCloudNodes"] + list(cc_nodearrays)
    for cc_grp in cc_map_hpc_groups:
        if ci_notin(cc_grp, hpc_node_groups):
            logging.info("Create HPC node group: {}".format(cc_grp))
            hpcpack_rest_client.add_node_group(cc_grp, "Cycle Cloud Node group")

    # Add HPC nodes into corresponding node groups
    add_cc_tag_nodes = [n.name for n in hpc_cn_nodes if n.shall_addcyclecloudtag]
    if len(add_cc_tag_nodes) > 0:
        logging.info("Adding HPC nodes to node group CycleCloudNodes: {}".format(add_cc_tag_nodes))
        hpcpack_rest_client.add_node_to_node_group("CycleCloudNodes", add_cc_tag_nodes)
    for cc_grp in list(cc_nodearrays):
        add_array_tag_nodes = [n.name for n in hpc_cn_nodes if n.shall_addnodearraytag and ci_equals(n.cc_nodearray, cc_grp)]
        if len(add_array_tag_nodes) > 0:
            logging.info("Adding HPC nodes to node group {}: {}".format(cc_grp, add_array_tag_nodes))
            hpcpack_rest_client.add_node_to_node_group(cc_grp, add_array_tag_nodes)
    
    if len(hpc_nodes_to_bring_online) > 0:
        logging.info("Bringing the HPC nodes online: {}".format(hpc_nodes_to_bring_online))
        if dry_run:
            logging.info("Dry-run: no real action")
        else:
            hpcpack_rest_client.bring_nodes_online(hpc_nodes_to_bring_online)
    if len(hpc_nodes_to_remove) > 0:
        logging.info("Removing the HPC nodes: {}".format(hpc_nodes_to_remove))
        if dry_run:
            logging.info("Dry-run: no real action")
        else:
            hpcpack_rest_client.remove_nodes(hpc_nodes_to_remove)
    if len(hpc_nodes_to_take_offline) > 0:
        logging.info("Taking the HPC nodes offline: {}".format(hpc_nodes_to_take_offline))
        if dry_run:
            logging.info("Dry-run: no real action")
        else:
            hpcpack_rest_client.take_nodes_offline(hpc_nodes_to_take_offline)
    if len(hpc_nodes_to_assign_template) > 0:
        logging.info("Assigning default node template for the HPC nodes: {}".format(hpc_nodes_to_assign_template))
        if dry_run:
            logging.info("Dry-run: no real action")
        else:
            hpcpack_rest_client.assign_default_compute_node_template(hpc_nodes_to_assign_template)
    cc_nodeid_to_shrink.extend([cn.delayed_node_id.node_id for cn in cc_nodes if not cn.create_time_remaining])
    if len(cc_nodeid_to_shrink) > 0:
        logging.info("Shut down the following Cycle cloud node: {}".format(cc_nodeid_to_shrink))
        if dry_run:
            logging.info("Dry-run: skip ...")
        else:
            node_mgr.shutdown_nodes([n for n in cc_nodes if ci_in(n.delayed_node_id.node_id, cc_nodeid_to_shrink)])

    ### Start scale up checking:
    logging.info("Start scale up checking ...")
    if ctx_handler:
        ctx_handler.set_context("[scale-up]")

    # Exclude the already online HPC nodes before calling node_mgr.allocate
    exclude_node_ids = [n.cc_node_id for n in hpc_cn_nodes if n.cc_node and (n.ready_for_job or n.to_shrink)]
    for cn in cc_nodes:
        if ci_in(cn.delayed_node_id.node_id, exclude_node_ids):
            cn.closed = True    

    # "ComputeNodes", "CycleCloudNodes", "AzureIaaSNodes" are all treated as default
    # grow_by_socket not supported yet, treat as grow_by_node
    defaultGroups = ["Default", "ComputeNodes", "AzureIaaSNodes", "CycleCloudNodes"]
    default_cores_to_grow = default_nodes_to_grow = 0.0

    # If the current CC nodes in the node array cannot satisfy the grow decision, the group is hungry
    # For a hungry group, no idle check is required if the node health is OK
    group_hungry: Dict[str, bool] = {}
    nbrNewNodes: int = 0
    grow_groups = list(grow_decisions.keys())
    for grp in grow_groups:
        tmp = grow_decisions.pop(grp)
        if not (tmp.cores_to_grow + tmp.nodes_to_grow + tmp.sockets_to_grow):
            continue
        if ci_in(grp, defaultGroups):
            default_cores_to_grow += tmp.cores_to_grow
            default_nodes_to_grow += tmp.nodes_to_grow + tmp.sockets_to_grow
            continue
        if ci_notin(grp, cc_nodearrays):
            logging.warning("No mapping node array for the grow requirement {}:{}".format(grp, grow_decisions[grp]))
            grow_decisions.pop(grp)
            continue
        group_hungry[grp] = False
        array = ci_lookup(grp, cc_nodearrays)
        selector =  {'ncpus': 1, 'node.nodearray':[array]}
        target_cores = math.ceil(tmp.cores_to_grow)
        target_nodes = math.ceil(tmp.nodes_to_grow + tmp.sockets_to_grow)
        if target_nodes:
            logging.info("Allocate: {}  Target Nodes: {}".format(selector, target_nodes))
            result = node_mgr.allocate(selector, node_count=target_nodes)
            logging.info(result)
            if not result or result.total_slots < target_nodes:
                group_hungry[grp] = True
        if target_cores:
            logging.info("Allocate: {}  Target Cores: {}".format(selector, target_cores))
            result = node_mgr.allocate(selector, slot_count=target_cores)
            logging.info(result)
            if not result or result.total_slots < target_cores:
                group_hungry[grp] = True
        if len(node_mgr.new_nodes) > nbrNewNodes:
            group_hungry[grp] = True
        nbrNewNodes = len(node_mgr.new_nodes)

    # We then check the grow decision for the default node groups:
    checkShrinkNeeded = True
    growForDefaultGroup = True if default_nodes_to_grow or default_cores_to_grow else False
    if growForDefaultGroup:
        selector = {'ncpus': 1}
        if default_nodes_to_grow:
            target_nodes = math.ceil(default_nodes_to_grow)
            logging.info("Allocate: {}  Target Nodes: {}".format(selector, target_nodes))
            result = node_mgr.allocate({'ncpus': 1}, node_count=target_nodes)
            if not result or result.total_slots < target_nodes:
                checkShrinkNeeded = False
        if default_cores_to_grow:
            target_cores = math.ceil(default_cores_to_grow)
            logging.info("Allocate: {}  Target Cores: {}".format(selector, target_cores))
            result = node_mgr.allocate({'ncpus': 1}, slot_count=target_cores)
            if not result or result.total_slots < target_cores:
                checkShrinkNeeded = False
        if len(node_mgr.new_nodes) > nbrNewNodes:
            checkShrinkNeeded = False
        nbrNewNodes = len(node_mgr.new_nodes)

    if nbrNewNodes > 0:
        logging.info("Need to Allocate {} nodes in total".format(nbrNewNodes))
        if dry_run:
            logging.info("Dry-run: skipping node bootup...")
        else:
            logging.info("Allocating {} nodes in total".format(len(node_mgr.new_nodes)))            
            bootup_result = node_mgr.bootup()
            logging.info(bootup_result)
    else:
        logging.info("No need to allocate new nodes ...")

    ### Start the shrink checking
    if ctx_handler:
        ctx_handler.set_context("[scale-down]")

    if not checkShrinkNeeded:
        logging.info("No shrink check at this round ...")
        if not dry_run:
            for nhi in node_history.active_items:
                if not nhi.stopping_or_stopped:
                    nhi.idle_from = None
            node_history.save()   
        return
    logging.info("Start scale down checking ...")
    # By default, we check idle for all CC nodes in HPC Pack with 'Offline', 'Starting', 'Online', 'Draining' state
    idle_check_hpc_nodes = [n for n in hpc_cn_nodes if n.cc_node and (not n.to_remove) and (not n.to_shrink) and ci_in(n.state, ["Offline", "Starting", "Online", "Draining"])]

    # We can exclude some nodes from idle checking:
    # 1. If HPC Pack ask for grow in default node group(s), all healthy ONLINE nodes are considered as busy
    # 2. If HPC Pack ask for grow in certain node group, all healthy ONLINE nodes in that node group are considered as busy
    # 3. If a node group is hungry (new CC required or grow request not satisfied), no idle check needed for all nodes in that node array
    if growForDefaultGroup:
        idle_check_hpc_nodes = [n for n in idle_check_hpc_nodes if not n.ready_for_job]
    for grp, hungry in group_hungry.items():
        if hungry:
            idle_check_hpc_nodes = [n for n in idle_check_hpc_nodes if not ci_equals(grp, n.cc_nodearray)]
        elif not growForDefaultGroup:
            idle_check_hpc_nodes = [n for n in idle_check_hpc_nodes if not (ci_equals(grp, n.cc_nodearray) and n.ready_for_job)]

    curtime = datetime.utcnow()
    idle_node_names = []
    if len(idle_check_hpc_nodes) > 0:
        idle_nodes = hpcpack_rest_client.check_nodes_idle([n.name for n in idle_check_hpc_nodes])
        if len(idle_nodes) > 0:
            idle_node_names = [n.node_name for n in idle_nodes]
            logging.info("The following node is idle: {}".format(idle_node_names))
        else:
            logging.info("No idle node found in this round.")

    new_shrink_node = []
    for nhi in node_history.active_items:
        if nhi.stopping_or_stopped:
            continue
        if ci_in(nhi.hostname, idle_node_names):
            if nhi.idle_from is None:
                nhi.idle_from = curtime
            elif nhi.shall_stop(idle_timeout_seconds):
                nhi.stop_time = curtime
                new_shrink_node.append(nhi.hostname)
        else:
            nhi.idle_from = None
    if len(new_shrink_node) > 0:
        logging.info("The following nodes will be shrinked: {}".format(new_shrink_node))
        if dry_run:
            logging.info("Dry-run: skip ...")
        else:
            node_mgr.shutdown_nodes([n for n in cc_nodes if ci_in(n.hostname, new_shrink_node)])
            hpcpack_rest_client.remove_nodes(new_shrink_node)
        
    if not dry_run:
        logging.info("Save node history: {}".format(node_history))
        node_history.save()

  
def load_config_defaults_from_jetpack() -> None:
    jetpack_cmd = 'C:\cycle\jetpack\system\Bin\jetpack_wrapper.cmd'
    if not os.path.exists(jetpack_cmd):
        return
    
    try:
        autoscale_enabled = check_output([jetpack_cmd, "config", 'cyclecloud.cluster.autoscale.start_enabled']).strip().decode()
        autoscale_idle_time_after_jobs = check_output([jetpack_cmd, "config", 'cyclecloud.cluster.autoscale.idle_time_after_jobs']).strip().decode()
        cluster_name = check_output([jetpack_cmd, "config", 'cyclecloud.cluster.name']).strip().decode()
        url = check_output([jetpack_cmd, "config", 'cyclecloud.config.web_server']).strip().decode()
        password = check_output([jetpack_cmd, "config", 'cyclecloud.config.password']).strip().decode()
        username = check_output([jetpack_cmd, "config", 'cyclecloud.config.username']).strip().decode()


        global CONFIG_DEFAULTS
        CONFIG_DEFAULTS['cyclecloud']['cluster_name'] = cluster_name
        CONFIG_DEFAULTS['cyclecloud']['url'] = url
        CONFIG_DEFAULTS['cyclecloud']['password'] = password
        CONFIG_DEFAULTS['cyclecloud']['username'] = username
        CONFIG_DEFAULTS['autoscale']['start_enabled'] = ci_equals(autoscale_enabled, "True")
        CONFIG_DEFAULTS['autoscale']['idle_time_after_jobs'] = int(autoscale_idle_time_after_jobs)
    except CalledProcessError:
        logging.warning("Failed to get cluster configuration from jetpack...")

def load_autoscaler_config(
    config_file: str
) -> Dict[str, Any]:

    from_file = {}
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            from_file = json.load(f)

    # If we're running on a cluster node, then get connection info from jetpack
    load_config_defaults_from_jetpack()

    # Super trivial merge
    config = dict(CONFIG_DEFAULTS)
    config.update(from_file)
    for key in CONFIG_DEFAULTS.keys():
        if isinstance(CONFIG_DEFAULTS[key], dict) and key in from_file:
            config[key] = dict(CONFIG_DEFAULTS[key])
            config[key].update(from_file[key])
    
    return config

def new_rest_client(
    config: Dict[str, Any]
) -> HpcRestClient:

    hpcpack_config = config.get('hpcpack') or {}    
    hpc_pem_file = hpcpack_config.get('pem') or CONFIG_DEFAULTS['hpcpack']['pem']
    hn_hostname = hpcpack_config.get('hn_hostname') or CONFIG_DEFAULTS['hpcpack']['hn_hostname']
    return HpcRestClient(config, pem=hpc_pem_file, hostname=hn_hostname)

if __name__ == "__main__":

    config_file=""
    if len(sys.argv) > 1:
        config_file = sys.argv[1]    

    dry_run = False
    if len(sys.argv) > 2:
        dry_run = ci_in(sys.argv[2], ['true', 'dryrun'])

    ctx_handler = register_result_handler(DefaultContextHandler("[initialization]"))
    config = load_autoscaler_config(config_file)
    logging.initialize_logging(config)
    logging.info("------------------------------------------------------------------------")
    if config["autoscale"]["start_enabled"]:
        autoscale_hpcpack(config, ctx_handler=ctx_handler, dry_run=dry_run)
    else:
        logging.info("Autoscaler is not enabled")