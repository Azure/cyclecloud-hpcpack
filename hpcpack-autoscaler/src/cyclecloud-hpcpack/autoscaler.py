import os
import json
import math
import sys
import typing
from uuid import uuid4
from typing import Any, Callable, Dict, Iterable, List, Optional, TextIO, Tuple
from datetime import datetime, timedelta
from subprocess import check_call, check_output, CalledProcessError

import hpc.autoscale.hpclogging as logging

from hpc.autoscale.example.readmeutil import clone_dcalc, example, withcontext
from hpc.autoscale.hpctypes import Memory
from hpc.autoscale.job.schedulernode import SchedulerNode
from hpc.autoscale.job.job import Job
from hpc.autoscale.node import nodemanager
from hpc.autoscale.node.constraints import BaseNodeConstraint
from hpc.autoscale.node.node import Node, UnmanagedNode
from hpc.autoscale.node.nodemanager import new_node_manager
from hpc.autoscale.results import DefaultContextHandler, register_result_handler, BootupResult, ShutdownResult


from .restclient import HpcRestClient
from .hpc_cluster_manager import HpcClusterManager

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
        "idle_time_after_jobs": 300,
        "provisioning_timeout": 1500,
        "max_deallocated_nodes": 300,
    },
    'hpcpack': {
        "pem": "C:\\cycle\\jetpack\\system\\bootstrap\\hpc-comm.pem",
        "hn_hostname": "hn",
    },
    'cyclecloud': {
        "cluster_name": None,
        "url": None, # "https://cyclecloud_url" or "https://ReturnProxy_ip:37140" when using ReturnProxy
        "username": None,
        "password": None,
        "verify_certificates": False,
    },
}


def get_target_counts(config: Dict[str, Any], 
    hpcpack_rest_client: Optional[HpcRestClient]
) -> Dict[str, Any]:

    grow_decision = hpcpack_rest_client.get_grow_decision()
    # also provides sockets_to_grow...  but do we care?  
    return grow_decision  

def scale_up(config: Dict[str, Any],
    hpcpack_rest_client: Optional[HpcRestClient] = None,
    ctx_handler: DefaultContextHandler = None,
    dry_run: bool = False,
) -> BootupResult:

    if ctx_handler:
        ctx_handler.set_context("[scale-up]")

    logging.info("Scaling up...")
    target_counts = get_target_counts(config, hpcpack_rest_client)
    logging.info("grow decision: {}".format(target_counts))
    node_mgr = new_node_manager(config['cyclecloud'])

    for group, grow_decision in target_counts.items():
        group =  group.lower()

        # TODO: Nodearray name should be derived from group name...
        # nodearray_names = config.nodearray_names(group)
        nodearray_names = ['cn']

        # WARNING: Specify ncpus or all  jobs will be packed on 1 node!
        selector =  {'ncpus': 1}
        if len(nodearray_names):
            selector["node.nodearray"] = nodearray_names
        else:
            logging.info("No current growth targets.")
            return

        target_cores = math.ceil(grow_decision.cores_to_grow)
        target_nodes = math.ceil(grow_decision.nodes_to_grow)
        if group in config['min_counts']:
            # Maintain min count
            target_nodes = max(config['min_counts'][group], target_nodes)

        if target_cores:
            logging.info("Array: {}  Target Cores: {}".format(selector, target_cores))
            result = node_mgr.allocate(selector, slot_count=target_cores)
            logging.info(result)
        if target_nodes:
            logging.info("Array: {}  Target Nodes: {}".format(selector, target_nodes))
            result = node_mgr.allocate(selector, node_count=target_nodes)
            logging.info(result)

    logging.info("Allocating {} nodes in total".format(len(node_mgr.new_nodes)))
    logging.info("Allocating {} nodes in total".format(len(node_mgr.new_nodes)))
    if dry_run:
        logging.info("Dry-run: skipping node bootup...")        
        return
     
    bootup_result = node_mgr.bootup()
    logging.info(bootup_result)
    return bootup_result

def shutdown_nodes(config: Dict[str, Any], 
    eligible_nodes: List[str]
) -> ShutdownResult:
    if eligible_nodes:
        logging.info("Scaling down nodes: {}".format(eligible_nodes))
        node_mgr = new_node_manager(config['cyclecloud'])

        nodes = [ n for n in node_mgr.get_nodes() if n.hostname in eligible_nodes ]
        logging.debug("Filtered nodes: {}".format(nodes))
        return node_mgr.shutdown_nodes(nodes)
    else:
        return None

def load_cluster_manager_state(config: Dict[str, Any],
    manager: HpcClusterManager
) -> None:

    statefile = config.get('statefile')
    if os.path.exists(statefile):
        try: 
            pickled_state = {}
            with open(statefile, 'r') as f:
                pickled_state = f.read()
            logging.debug("Restoring Manager state: {}".format(pickled_state))
            manager.unpickle(pickled_state)
        except:
            logging.exception("Failed to re-load autoscaler state from {}...".format(statefile))

    # Load pre-existing nodes into manager
    node_mgr = new_node_manager(config['cyclecloud'])
    all_nodes = node_mgr.get_nodes()
    for node in all_nodes:
        # Wait for node to get assigned a hostname and node id
        if node.hostname and node.delayed_node_id:
            manager.add_slaveinfo(node.hostname, node.delayed_node_id.node_id, node.vcpu_count, last_heartbeat=None)

def store_cluster_manager_state(config: Dict[str, Any], 
    manager: HpcClusterManager
) -> None:

    statefile = config.get('statefile')
    try:
        with open(statefile, 'w') as f:
            f.write(manager.pickle())
    except:
        logging.warning("Failed to store autoscaler state to {}...".format(statefile))

def manage_cluster(cconfig: Dict[str, Any],
    hpcpack_rest_client: Optional[HpcRestClient] = None,
    ctx_handler: DefaultContextHandler = None,
    dry_run: bool = False,
) -> ShutdownResult:

    default_node_group = "ComputeNodes"
    autoscale_config = config.get('autoscale') or {}
    provisioning_timeout_secs = autoscale_config.get('provisioning_timeout') or CONFIG_DEFAULTS['autoscale']['provisioning_timeout']
    idle_timeout_secs = autoscale_config.get('idle_time_after_jobs') or CONFIG_DEFAULTS['autoscale']['idle_time_after_jobs']

    provisioning_timeout = timedelta(seconds=provisioning_timeout_secs)
    idle_timeout = timedelta(seconds=idle_timeout_secs)
    manager = HpcClusterManager(config, hpcpack_rest_client, provisioning_timeout=provisioning_timeout, 
                                idle_timeout=idle_timeout, 
                                node_group=default_node_group)

    if ctx_handler:
        ctx_handler.set_context("[hpcpack-state]")

    # Reload manager state
    load_cluster_manager_state(config, manager)

    # Post-autostart provisioning and Autostop statemachine
    manager.configure_cluster()    
    nodes_to_shutdown = manager.check_deleted_nodes()

    if ctx_handler:
        ctx_handler.set_context("[scale-down]")

    if dry_run:
        logging.info("Dry-run: skipping node termination...")
    else:
        shutdown_result = shutdown_nodes(config, nodes_to_shutdown)

    # Store updated manager state
    store_cluster_manager_state(config, manager)
    return shutdown_result
    

def load_config_defaults_from_jetpack() -> None:
    jetpack_cmd = 'C:\cycle\jetpack\system\Bin\jetpack_wrapper.cmd'
    if not os.path.exists(jetpack_cmd):
        return
    
    try:        
        cluster_name = check_output([jetpack_cmd, "config", 'cyclecloud.cluster.name']).strip().decode()
        url = check_output([jetpack_cmd, "config", 'cyclecloud.config.web_server']).strip().decode()
        password = check_output([jetpack_cmd, "config", 'cyclecloud.config.password']).strip().decode()
        username = check_output([jetpack_cmd, "config", 'cyclecloud.config.username']).strip().decode()

        global CONFIG_DEFAULTS
        CONFIG_DEFAULTS['cyclecloud']['cluster_name'] = cluster_name
        CONFIG_DEFAULTS['cyclecloud']['url'] = url
        CONFIG_DEFAULTS['cyclecloud']['password'] = password
        CONFIG_DEFAULTS['cyclecloud']['username'] = username
    except CalledProcessError:
        logging.warning("Failed to get cluster configuration from jetpack...")

def load_autoscaler_config(config_file: str
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

def new_rest_client(config: Dict[str, Any]
) -> HpcRestClient:

    hpcpack_config = config.get('hpcpack') or {}    
    hpc_pem_file = hpcpack_config.get('pem') or CONFIG_DEFAULTS['hpcpack']['pem']
    hn_hostname = hpcpack_config.get('hn_hostname') or CONFIG_DEFAULTS['hpcpack']['hn_hostname']
    return HpcRestClient(config, pem=hpc_pem_file, hostname=hn_hostname)

def autoscale_hpcpack(config: Dict[str, Any],
    ctx_handler: DefaultContextHandler = None,
    hpcpack_rest_client: Optional[HpcRestClient] = None,
    dry_run: bool = False,
) -> BootupResult:

    if not hpcpack_rest_client:
        hpcpack_rest_client = new_rest_client(config)

    logging.info("Checking running nodes and autostop if needed...")
    manage_cluster(config, hpcpack_rest_client, ctx_handler, dry_run)

    if ctx_handler:
        ctx_handler.set_context("[scale-up]")
    logging.info("Checking growth targets and autostarting if needed...")    
    return scale_up(config, hpcpack_rest_client, ctx_handler, dry_run)
    

if __name__ == "__main__":

    config_file=""
    if len(sys.argv) > 1:
        config_file = sys.argv[1]    

    dry_run = False
    if len(sys.argv) > 2:
        dry_run = sys.argv[2].lower() in ['true', 'dryrun']

    ctx_handler = register_result_handler(DefaultContextHandler("[initialization]"))
    

    config = load_autoscaler_config(config_file)
    logging.initialize_logging(config) 

    autoscale_hpcpack(config, ctx_handler=ctx_handler, dry_run=dry_run)