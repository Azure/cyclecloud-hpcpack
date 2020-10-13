import threading
from datetime import datetime, timedelta

import pytz
from typing import Iterable, Callable, NamedTuple, Set, Dict, List, Tuple

import hpc.autoscale.hpclogging as logging
#import logging_aux
from hpcpack.restclient import HpcRestClient
from hpc.autoscale.node.node import Node, UnmanagedNode


class HpcState:
    Unknown, Provisioning, Running, Draining, Closing, Closed = range(6)
    Names = ["Unknown", "Provisioning", "Running", "Draining", "Closing", "Closed"]


def _upper_strings(strs):
    # type: (Iterable[str]) -> Iterable[str]
    return (x.upper() for x in strs)


def _check_node_health_unapproved(node_status):
    # type: (Dict[str, any]) -> bool
    return node_status[
               HpcRestClient.NODE_STATUS_NODE_HEALTH_KEY] == HpcRestClient.NODE_STATUS_NODE_HEALTH_UNAPPROVED_VALUE


def _find_missing_nodes(rq_nodes, res_nodes):
    # type: (List[str], List[str]) -> List[str]
    return [name for name in _upper_strings(rq_nodes) if name not in _upper_strings(res_nodes)]


def _check_node_state(node_status, target_state):
    # type: (dict[str, any], str) -> bool
    return node_status[HpcRestClient.NODE_STATUS_NODE_STATE_KEY] == target_state


def _check_node_state_offline(node_status):
    # type: (dict[str, any]) -> bool
    return _check_node_state(node_status, HpcRestClient.NODE_STATUS_NODE_STATE_OFFLINE_VALUE)


def _check_node_state_online(node_status):
    # type: (dict[str, any]) -> bool
    return _check_node_state(node_status, HpcRestClient.NODE_STATUS_NODE_STATE_ONLINE_VALUE)


def _get_hostname_from_fqdn(fqdn):
    # type: (str) -> str
    return fqdn.split('.')[0]


def _get_node_name_from_status(node_status):
    # type: (dict[str, any]) -> str
    return node_status[HpcRestClient.NODE_STATUS_NODE_NAME_KEY]


def _get_node_names_from_status(node_status_list):
    # type: (List[Dict[str, any]]) -> List[str]
    return map(_get_node_name_from_status, node_status_list)


def _get_node_state_from_status(node_status):
    # type: (dict[str, any]) -> str
    return node_status[HpcRestClient.NODE_STATUS_NODE_STATE_KEY]


class HpcNode(object):

    def __init__(self, hostname: str, node_id: str, idle_since: datetime, state: str) -> None:
        self.hostname = hostname
        self.idle_since = idle_since
        self.node_id = node_id

        

class HpcClusterManager(object):
    CHECK_CONFIGURING_NODES_INTERVAL = 5  # in seconds
    AZURE_NODE_GROUP_NAME = "Azure"
    AZURE_NODE_GROUP_DESCRIPTION = "The autoscaled compute nodes in the cluster"

    # TODO: add configuration_timeout
    def __init__(self, config: dict, hpc_rest_client: HpcRestClient, node_mgr: NodeManager, 
                 provisioning_timeout: timedelta = timedelta(minutes=15), idle_timeout: timedelta = timedelta(minutes=3),
                 node_group: str = "", min_node_count: int = 1) -> None:

        logging.initialize_logging(config)

        self._slave_info_table = {}  # type: Dict[str, HpcNode]
        self._removed_nodes = set()  # type: Set[str]
        self._deleted_nodes = set()  # type: Set[str]
        self._node_idle_check_table = {}
        self._table_lock = threading.Lock()
        self._provisioning_timeout = provisioning_timeout
        self._hpc_client = hpc_rest_client
        self._node_group = node_group  # TODO: change to a centralized config

        self._node_idle_timedelta = idle_timeout

        # TODO: Should allow min count per nodearray / group
        self.min_node_count = min_node_count

        # callbacks
        self._node_closed_callbacks = []  # type: [Callable[[[str]], ()]]        

    def pickle(self):
        # type: () => (str)
        import jsonpickle
        return jsonpickle.encode(
            {
            '_slave_info_table': self._slave_info_table,
            '_removed_nodes': self._removed_nodes,
            '_deleted_nodes': self._deleted_nodes,
            '_node_idle_check_table': self._node_idle_check_table,
            }
        )

    def unpickle(self, pickled):
        # type: (str) => ()
        import jsonpickle
        if not pickled:
            logging.info("No previous cluster state to load...")
            return

        state = jsonpickle.decode(pickled)
        self._slave_info_table = state['_slave_info_table']
        self._removed_nodes = state['_removed_nodes']
        self._deleted_nodes = state['_deleted_nodes']
        self._node_idle_check_table = state['_node_idle_check_table']