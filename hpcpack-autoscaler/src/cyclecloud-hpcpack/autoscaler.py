import os
import json
import math
import sys
import pathlib
from typing import Any, Dict, List, Optional, Tuple
from datetime import datetime, timedelta
from subprocess import check_output, CalledProcessError
import hpc.autoscale.hpclogging as logging
from hpc.autoscale.node.node import Node
from hpc.autoscale.node.nodemanager import NodeManager, new_node_manager
from hpc.autoscale.results import DefaultContextHandler, register_result_handler, BootupResult, ShutdownResult
from hpc.autoscale.util import partition, partition_single, load_config
from .hpcpackdriver import HpcNode, HpcRestClient, GrowDecision
from .commonutil import ci_equals, ci_find_one, ci_in, ci_notin, ci_interset, ci_lookup, make_dict, make_dict_single
from .hpcnodehistory import HpcNodeHistory, NodeHistoryItem


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
    idle_timeout_seconds:int = autoscale_config.get("idle_timeout") or 600    
    provisioning_timeout_seconds = autoscale_config.get("boot_timeout") or 1500
    statefile = autoscale_config.get("statefile") or "C:\\cycle\\jetpack\\config\\autoscaler_state.txt"
    archivefile = autoscale_config.get("archivefile") or "C:\\cycle\\jetpack\\config\\autoscaler_archive.txt"
    node_history = HpcNodeHistory(
        statefile=statefile, 
        archivefile=archivefile, 
        provisioning_timeout=provisioning_timeout_seconds, 
        idle_timeout=idle_timeout_seconds)

    logging.info("Synchronizing the nodes between Cycle cloud and HPC Pack")
    # Initialize data of History info, cc nodes, HPC Pack nodes, HPC grow decisions
    # Get node list from Cycle Cloud
    def nodes_state_key(n: Node) -> Tuple[int, str, int]:
        try:
            state_pri = 1
            if n.state == 'Deallocated':
                state_pri = 2
            elif n.state == 'Stopping':
                state_pri = 3
            elif n.state == 'Terminating':
                state_pri = 4
            name, index = n.name.rsplit("-", 1)
            return (state_pri, name, int(index))
        except Exception:
            return (state_pri, n.name, 0)
    node_mgr: NodeManager = new_node_manager(config)
    for b in node_mgr.get_buckets():
        b.nodes.sort(key=nodes_state_key)
    cc_nodes:List[Node] = node_mgr.get_nodes()
    cc_nodes_by_id = partition_single(cc_nodes, func=lambda n: n.delayed_node_id.node_id)
    # Get compute node list and grow decision from HPC Pack
    hpc_node_groups = hpcpack_rest_client.list_node_groups()
    grow_decisions = hpcpack_rest_client.get_grow_decision()
    logging.info("grow decision: {}".format(grow_decisions))
    hpc_cn_nodes:List[HpcNode] = hpcpack_rest_client.list_computenodes()
    hpc_cn_nodes = [n for n in hpc_cn_nodes if n.active]

    # This function will link node history items, cc nodes and hpc nodes
    node_history.synchronize(cc_nodes, hpc_cn_nodes)

    cc_nodearrays = set([b.nodearray for b in node_mgr.get_buckets()])
    logging.info("Current node arrays in cyclecloud: {}".format(cc_nodearrays))

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

    # Possible values for HPC NodeState (states marked with * shall not occur for CC nodes):
    #   Unknown, Provisioning, Offline, Starting, Online, Draining, Rejected(*), Removing, NotDeployed(*), Stopping(*) 
    # Remove the following HPC Pack nodes:
    #   1. The corresponding CC node already removed
    #   2. The corresponding CC node is stopped and HPC node is not assigned a node template
    # Take offline the following HPC Pack nodes:
    #   1. The corresponding CC node is stopped or is going to stop
    hpc_nodes_to_remove = [n.name for n in hpc_cn_nodes if n.removed_cc_node or (n.stopped_cc_node and not n.template_assigned)]
    hpc_nodes_to_take_offline = [n.name for n in hpc_cn_nodes if n.stopped_cc_node and ci_equals(n.state, "Online")]
    if len(hpc_nodes_to_remove) > 0:
        logging.info("Removing the HPC nodes: {}".format(hpc_nodes_to_remove))
        if dry_run:
            logging.info("Dry-run: no real action")
        else:
            hpcpack_rest_client.remove_nodes(hpc_nodes_to_remove)
    hpc_cn_nodes = [n for n in hpc_cn_nodes if not (n.stopped_cc_node or n.removed_cc_node)]

    # Assign default node template for unapproved CC node 
    hpc_nodes_to_assign_template = [n.name for n in hpc_cn_nodes if n.bound_cc_node and not n.template_assigned]
    if len(hpc_nodes_to_assign_template) > 0:
        logging.info("Assigning default node template for the HPC nodes: {}".format(hpc_nodes_to_assign_template))
        if dry_run:
            logging.info("Dry-run: no real action")
        else:
            hpcpack_rest_client.assign_default_compute_node_template(hpc_nodes_to_assign_template)

    ### Start scale up checking:
    logging.info("Start scale up checking ...")
    if ctx_handler:
        ctx_handler.set_context("[scale-up]")

    hpc_nodes_with_active_cc = [n for n in hpc_cn_nodes if n.template_assigned and n.bound_cc_node]
    # Exclude the already online healthy HPC nodes before calling node_mgr.allocate
    for hpc_node in hpc_nodes_with_active_cc:
        if hpc_node.ready_for_job:
            hpc_node.bound_cc_node.closed = True
    
    # Terminate the provisioning timeout CC nodes
    cc_node_to_terminate: List[Node] = []
    for cc_node in cc_nodes:
        if ci_equals(cc_node.target_state, 'Deallocated') or ci_equals(cc_node.target_state, 'Terminated') or cc_node.create_time_remaining:
            continue
        nhi = node_history.find(cc_id=cc_node.delayed_node_id.node_id)
        if not nhi.hpc_id:
            cc_node.closed = True
            cc_node_to_terminate.append(cc_node)
        else:
            hpc_node = ci_find_one(hpc_nodes_with_active_cc, nhi.hpc_id, lambda n : n.id)
            if hpc_node and hpc_node.error:
                cc_node.closed = True
                cc_node_to_terminate.append(cc_node)

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
            bootup_result:BootupResult = node_mgr.bootup()
            logging.info(bootup_result)
            if bootup_result and bootup_result.nodes:
                for cc_node in bootup_result.nodes:
                    nhi = node_history.find(cc_id = cc_node.delayed_node_id.node_id)
                    if nhi is None:
                        nhi = node_history.insert(NodeHistoryItem(cc_node.delayed_node_id.node_id))
                    else:
                        nhi.restart()
    else:
        logging.info("No need to allocate new nodes ...")

    ### Start the shrink checking
    if ctx_handler:
        ctx_handler.set_context("[scale-down]")

    cc_node_to_shutdown: List[Node] = []
    if not checkShrinkNeeded:
        logging.info("No shrink check at this round ...")
        if not dry_run:
            for nhi in node_history.items:
                if not nhi.stopped and nhi.hpc_id:
                    nhi.idle_from = None
    else:
        logging.info("Start scale down checking ...")
        # By default, we check idle for active CC nodes in HPC Pack with 'Offline', 'Starting', 'Online', 'Draining' state
        candidate_idle_check_nodes = [n for n in hpc_nodes_with_active_cc if (not n.bound_cc_node.keep_alive) and ci_in(n.state, ["Offline", "Starting", "Online", "Draining"])]

        # We can exclude some nodes from idle checking:
        # 1. If HPC Pack ask for grow in default node group(s), all healthy ONLINE nodes are considered as busy
        # 2. If HPC Pack ask for grow in certain node group, all healthy ONLINE nodes in that node group are considered as busy
        # 3. If a node group is hungry (new CC required or grow request not satisfied), no idle check needed for all nodes in that node array
        if growForDefaultGroup:
            candidate_idle_check_nodes = [n for n in candidate_idle_check_nodes if not n.ready_for_job]
        for grp, hungry in group_hungry.items():
            if hungry:
                candidate_idle_check_nodes = [n for n in candidate_idle_check_nodes if not ci_equals(grp, n.cc_nodearray)]
            elif not growForDefaultGroup:
                candidate_idle_check_nodes = [n for n in candidate_idle_check_nodes if not (ci_equals(grp, n.cc_nodearray) and n.ready_for_job)]

        curtime = datetime.utcnow()
        # Offline node must be idle
        idle_node_names = [n.name for n in candidate_idle_check_nodes if ci_equals(n.state, 'Offline')]
        if len(candidate_idle_check_nodes) > len(idle_node_names):
            idle_nodes = hpcpack_rest_client.check_nodes_idle([n.name for n in candidate_idle_check_nodes if not ci_equals(n.state, 'Offline')])
            if len(idle_nodes) > 0:
                idle_node_names.extend([n.node_name for n in idle_nodes])

        if len(idle_node_names) > 0:
            logging.info("The following node is idle: {}".format(idle_node_names))
        else:
            logging.info("No idle node found in this round.")

        retention_days = autoscale_config.get("vm_retention_days") or 7
        for nhi in node_history.items:
            if nhi.stopped:
                if nhi.stop_time + timedelta(days=retention_days) < datetime.utcnow():
                    cc_node = cc_nodes_by_id.get(nhi.cc_id)
                    if cc_node is not None:
                        cc_node_to_terminate.append(cc_node)
                continue
            if ci_in(nhi.hostname, idle_node_names):
                if nhi.idle_from is None:
                    nhi.idle_from = curtime
                elif nhi.idle_timeout(idle_timeout_seconds):
                    nhi.stop_time = curtime
                    cc_node = cc_nodes_by_id.get(nhi.cc_id)
                    if cc_node is not None:
                        cc_node_to_shutdown.append(cc_node)
            else:
                nhi.idle_from = None

    shrinking_cc_node_ids = [n.delayed_node_id.node_id for n in cc_node_to_terminate]
    shrinking_cc_node_ids.extend([n.delayed_node_id.node_id for n in cc_node_to_shutdown])
    hpc_nodes_to_bring_online = [n.name for n in hpc_nodes_with_active_cc if ci_equals(n.state, 'Offline') and not n.error and ci_notin(n.cc_node_id, shrinking_cc_node_ids)]
    hpc_nodes_to_take_offline.extend([n.name for n in hpc_nodes_with_active_cc if ci_equals(n.state, 'Online') and ci_in(n.cc_node_id, shrinking_cc_node_ids)])
    if len(hpc_nodes_to_bring_online) > 0:
        logging.info("Bringing the HPC nodes online: {}".format(hpc_nodes_to_bring_online))
        if dry_run:
            logging.info("Dry-run: no real action")
        else:
            hpcpack_rest_client.bring_nodes_online(hpc_nodes_to_bring_online)

    if len(hpc_nodes_to_take_offline) > 0:
        logging.info("Taking the HPC nodes offline: {}".format(hpc_nodes_to_take_offline))
        if dry_run:
            logging.info("Dry-run: no real action")
        else:
            hpcpack_rest_client.take_nodes_offline(hpc_nodes_to_take_offline)

    if len(cc_node_to_shutdown) > 0:
        logging.info("Shut down the following Cycle cloud node: {}".format([cn.name for cn in cc_node_to_shutdown]))
        if dry_run:
            logging.info("Dry-run: skip ...")
        else:            
            node_mgr.shutdown_nodes(cc_node_to_shutdown)

    if len(cc_node_to_terminate) > 0:
        logging.info("Terminating the following provisioning-timeout Cycle cloud nodes: {}".format([cn.name for cn in cc_node_to_terminate]))
        if dry_run:
            logging.info("Dry-run: skip ...")
        else:            
            node_mgr.terminate_nodes(cc_node_to_terminate)

    if not dry_run:
        logging.info("Save node history: {}".format(node_history))
        node_history.save()


def new_rest_client(
    config: Dict[str, Any]
) -> HpcRestClient:

    hpcpack_config = config.get('hpcpack') or {}    
    hpc_pem_file = hpcpack_config.get('pem')
    hn_hostname = hpcpack_config.get('hn_hostname')
    return HpcRestClient(config, pem=hpc_pem_file, hostname=hn_hostname)

if __name__ == "__main__":

    config_file=""
    if len(sys.argv) > 1:
        config_file = sys.argv[1]    

    dry_run = False
    if len(sys.argv) > 2:
        dry_run = ci_in(sys.argv[2], ['true', 'dryrun'])

    ctx_handler = register_result_handler(DefaultContextHandler("[initialization]"))
    config = load_config(config_file)
    logging.initialize_logging(config)
    logging.info("------------------------------------------------------------------------")
    if config["autoscale"]["start_enabled"]:
        autoscale_hpcpack(config, ctx_handler=ctx_handler, dry_run=dry_run)
    else:
        logging.info("Autoscaler is not enabled")