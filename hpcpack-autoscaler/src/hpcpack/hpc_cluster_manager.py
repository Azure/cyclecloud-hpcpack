import threading
from datetime import datetime, timedelta

import pytz
from typing import Iterable, Callable, NamedTuple, Set, Dict, List, Tuple

import hpc.autoscale.hpclogging as logging
#import logging_aux
from hpcpack.restclient import HpcRestClient


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
    u_rq_nodes = list(_upper_strings(rq_nodes))
    u_res_nodes = list(_upper_strings(res_nodes))
    return [name for name in u_rq_nodes if name not in u_res_nodes]


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
    return node_status[HpcRestClient.NODE_STATUS_NODE_NAME_KEY].upper()


def _get_node_names_from_status(node_status_list):
    # type: (List[Dict[str, any]]) -> List[str]
    return map(_get_node_name_from_status, node_status_list)


def _get_node_state_from_status(node_status):
    # type: (dict[str, any]) -> str
    return node_status[HpcRestClient.NODE_STATUS_NODE_STATE_KEY]


class HpcClusterManager(object):
    CHECK_CONFIGURING_NODES_INTERVAL = 5  # in seconds
    AZURE_NODE_GROUP_NAME = "Azure"
    AZURE_NODE_GROUP_DESCRIPTION = "The autoscaled compute nodes in the cluster"

    NODE_IDLE_TIMEOUT = 180.0

    # TODO: add configuration_timeout
    def __init__(self, config, hpc_rest_client, provisioning_timeout=timedelta(minutes=15), idle_timeout=timedelta(minutes=3),
                 node_group="", min_node_count=1):
        # type: (HpcRestClient, timedelta, timedelta, str) -> ()

        logging.initialize_logging(config)
        # self.logger = logging_aux.init_logger_aux("hpcframework.clustermanager", "hpcframework.clustermanager.log")

        self._slave_info_table = {}  # type: Dict[str, SlaveInfo]
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

    def check_deleted_nodes(self):
        # type: () -> (Set[str])
        return self._deleted_nodes
    
    def node_terminated(self, node_name):
        # type: (str) -> ()
        u_node_name = node_name.upper()
        self._deleted_nodes.remove(node_name)
        self._slave_info_table.pop(u_node_name)

    def _node_group_specified(self):
        # type: () -> bool
        return self._node_group != ""

    def subscribe_node_closed_callback(self, callback):
        # type: (Callable[[list[str]], ()]) -> ()
        self._node_closed_callbacks.append(callback)

    def add_slaveinfo(self, hostname, node_id, cpus, last_heartbeat=None):
        # type: (str, str, str, float, datetime) -> ()
        if last_heartbeat is None:
            last_heartbeat = datetime.now(pytz.utc)
        u_hostname = hostname.upper()
        if u_hostname in self._slave_info_table:
            old_slaveinfo = self._slave_info_table[u_hostname]
            if old_slaveinfo.node_id != node_id:
                logging.warn(
                    "Reused Compute Node hostname {} detected. Existing node_id: {}, new node_id {}.  Dropping the old node.".format(
                        hostname, old_slaveinfo.node_id, node_id))                
            else: 
                # BRW simply skip existing slave info
                return

        # Add slaveinfo for new nodes
        slaveinfo = SlaveInfo(u_hostname, node_id, cpus, last_heartbeat, HpcState.Provisioning)
        self._slave_info_table[u_hostname] = slaveinfo
        logging.info("New compute node entry added: {}".format(str(slaveinfo)))

    def update_slaves_last_seen(self, hostname_arr, now=None):
        # type:(Iterable[str], datetime) -> ()
        if now is None:
            now = datetime.now(pytz.utc)
        for hostname in hostname_arr:
            self.update_slave_last_seen(hostname, now)

    def update_slave_last_seen(self, hostname, now=None):
        # type: (str, datetime) -> ()
        if now is None:
            now = datetime.now(pytz.utc)
        u_hostname = hostname.upper()
        if u_hostname in self._slave_info_table:
            self._slave_info_table[u_hostname] = self._slave_info_table[u_hostname]._replace(last_seen=now)
            logging.info("Slave seen: {}".format(u_hostname))
        else:
            logging.error("Host {} is not recognized. No entry will be updated.".format(u_hostname))
            logging.debug("_table {} ".format(self._slave_info_table))

    def get_task_info(self, hostname):
        # type: (str) -> (str, str)
        u_hostname = hostname.upper()
        if u_hostname in self._slave_info_table:
            entry = self._slave_info_table[u_hostname]
            return entry.task_id, entry.agent_id
        else:
            logging.error("Host {} is not recognized. Failed to get task info.".format(u_hostname))
            return "", ""

    def get_host_state(self, hostname):
        # type: (str) -> int
        u_hostname = hostname.upper()
        if u_hostname in self._slave_info_table:
            entry = self._slave_info_table[u_hostname]
            return entry.state
        else:
            logging.error("Host {} is not recognized. Failed to get host state.".format(u_hostname))
            return HpcState.Unknown

    # def _exec_callback(self, callbacks):
    #     for callback in callbacks:
    #         try:
    #             logging.debug('Callback %s on %s' % callback.__name__)
    #             callback()
    #         except Exception as e:
    #             logging.exception('Error in %s callback: %s' % (callback.__name__, str(e)))

    def check_fqdn_collision(self, fqdn):
        # type: (str) -> bool
        u_fqdn = fqdn.upper()
        u_hostname = _get_hostname_from_fqdn(u_fqdn)
        if u_hostname in self._slave_info_table:
            if self._slave_info_table[u_hostname].fqdn != u_fqdn:
                return True
        return False

    def _check_timeout(self, now=None):
        # type: (datetime) -> ([SlaveInfo], [SlaveInfo])
        # TODO: Check configuring timeout
        if now is None:
            now = datetime.now(pytz.utc)
        provision_timeout_list = []
        running_list = []
        for host in dict(self._slave_info_table).values():
            if host.state == HpcState.Provisioning and now - host.last_seen >= self._provisioning_timeout:
                logging.warn("Provisioning timeout: {}".format(str(host)))
                provision_timeout_list.append(host)
            elif host.state == HpcState.Running:
                running_list.append(host)

        return provision_timeout_list, running_list

    def get_cores_in_provisioning(self):
        cores = 0.0
        for host in dict(self._slave_info_table).values():
            if host.state == HpcState.Provisioning:
                cores += host.cpus
        logging.info("Cores in provisioning: {}".format(cores))
        return cores

    def _get_nodes_name_in_state(self, state):
        # type: (HpcState) -> [str]
        return [host.hostname for host in dict(self._slave_info_table).values() if host.state == state]

    def check_node_groups(nodes):
        nodearray_names = [ node.nodearray_name for node in nodes ]

        groups = self._hpc_client.list_node_groups()
        unique_names = set(nodearray_names)
        for name in unique_names:
            if name not in groups:
                self._hpc_client.add_node_group(name, "Azure autoscale group: {}".format(name))
        return list(set(unique_names + groups))

    # TODO:  make state_machine methods more testable
    def _provision_compute_nodes_state_machine(self):
        # type: () -> ()
        provisioning_node_names = self._get_nodes_name_in_state(HpcState.Provisioning)

        if not provisioning_node_names:
            logging.debug("No nodes in provisioning...")
            return

        logging.info("Nodes in provisioning: {}".format(provisioning_node_names))
        groups = self._hpc_client.list_node_groups(self.AZURE_NODE_GROUP_NAME)
        if self.AZURE_NODE_GROUP_NAME not in groups:
            self._hpc_client.add_node_group(self.AZURE_NODE_GROUP_NAME, self.AZURE_NODE_GROUP_DESCRIPTION)
        
        # We won't create target node group, but check if it exists
        # Check after Mesos group has been created to support specified group is Mesos group
        # if self._node_group_specified():
        #     target_group = self._hpc_client.list_node_groups(self._node_group)
        #     if self._node_group.upper() not in (x.upper() for x in target_group):
        #         logging.error(
        #             "Target node group is not created:{}. Stop configure compute nodes.".format(self._node_group))
        #         return

        # state check
        node_status_list = self._hpc_client.get_node_status_exact(provisioning_node_names)
        logging.info("Get node_status_list:{}".format(str(node_status_list)))
        unapproved_node_list = []
        take_offline_node_list = []
        bring_online_node_list = []
        change_node_group_node_list = []
        provisioned_node_names = []
        invalid_state_node_dict = {}
        for node_status in node_status_list:
            node_name = _get_node_name_from_status(node_status)
            node_state = _get_node_state_from_status(node_status)
            in_node_group = self._check_node_in_specified_group(node_status, self._node_group)
            in_azure_group = self._check_node_in_specified_group(node_status, self.AZURE_NODE_GROUP_NAME)
            if _check_node_health_unapproved(node_status):
                unapproved_node_list.append(node_name)
            # node approved
            # BRW TODO Need to add node to the correct NodeGroups => need nodearray name and support multiple groups here
            # elif (not self._check_node_in_groups(node_status, node.nodearray??????) or
            elif ((self._node_group_specified() and not in_node_group) or not in_azure_group):
                if _check_node_state_online(node_status):
                    take_offline_node_list.append(node_name)
                elif _check_node_state_offline(node_status):
                    change_node_group_node_list.append(node_name)
                else:
                    invalid_state_node_dict[node_name] = node_state
            # node group properly set
            elif _check_node_state_offline(node_status):
                bring_online_node_list.append(node_name)
            elif _check_node_state_online(node_status):
                # this node is all set
                provisioned_node_names.append(node_name)
            else:
                invalid_state_node_dict[node_name] = node_state

        missing_nodes = _find_missing_nodes(provisioning_node_names, (_get_node_names_from_status(node_status_list)))
        try:
            if invalid_state_node_dict:
                logging.info("Node(s) in invalid state when provisioning: {}".format(str(invalid_state_node_dict)))
            if unapproved_node_list:
                logging.info("Assigning node template for node(s): {}".format(str(unapproved_node_list)))
                self._hpc_client.assign_default_compute_node_template(unapproved_node_list)
            if take_offline_node_list:
                logging.info("Taking node(s) offline: {}".format(str(take_offline_node_list)))
                self._hpc_client.take_nodes_offline(take_offline_node_list)
            if bring_online_node_list:
                logging.info("Bringing node(s) online: {}".format(str(bring_online_node_list)))
                self._hpc_client.bring_nodes_online(bring_online_node_list)
            if change_node_group_node_list:
                logging.info("Changing node group node(s): {}".format(str(change_node_group_node_list)))
                # BRW TODO Add node to nodearray group => need map of node_name to nodearray name
                # self._hpc_client.add_node_to_node_group(node.nodearray, change_node_group_node_list)
                self._hpc_client.add_node_to_node_group(self.AZURE_NODE_GROUP_NAME, change_node_group_node_list)
                if self._node_group_specified():
                    if self._node_group == "ComputeNodes":
                        logging.warn("Skipping AddToGroup ComputeNodes")  # TODO: Is this needed/correct?
                    else:
                        self._hpc_client.add_node_to_node_group(self._node_group, change_node_group_node_list)
        except:
            # Swallow all exceptions here. As we don't want any exception to prevent provisioned nodes to work
            logging.exception('Exception happened when configuring compute node.')

        # state change
        if provisioned_node_names:
            logging.info("Nodes provisioned: {}".format(provisioned_node_names))
            self._set_nodes_running(provisioned_node_names)
        if missing_nodes:
            # Missing is valid state of nodes in provisioning.
            logging.info("Nodes missing when provisioning: {}".format(missing_nodes))

    def _check_runaway_and_idle_compute_nodes(self):
        # type: () -> ()
        logging.info("Checking runaway and idle compute nodes...")
        (provision_timeout_list, running_list) = self._check_timeout()
        if not provision_timeout_list and not running_list:
            logging.info("No running or provisioning nodes to check.")
            return

        if provision_timeout_list:
            logging.info("Get provision_timeout_list:{}".format(str(provision_timeout_list)))
            self._set_nodes_draining(host.hostname for host in provision_timeout_list)
        if running_list:
            running_node_names = [host.hostname for host in running_list]
            node_status_list = self._hpc_client.get_node_status_exact(running_node_names)

            # Unapproved nodes and missing nodes in running state are runaway nodes
            unapproved_nodes = [_get_node_name_from_status(status) for status in node_status_list if
                                _check_node_health_unapproved(status)]
            missing_nodes = _find_missing_nodes(running_node_names, _get_node_names_from_status(node_status_list))
            if unapproved_nodes:
                logging.warn("Unapproved nodes in running state:{}".format(unapproved_nodes))
                self._set_nodes_closed(unapproved_nodes)
            if missing_nodes:
                logging.warn("Missing nodes in running state:{}".format(missing_nodes))
                self._set_nodes_closed(missing_nodes)

            if self.get_cores_in_provisioning() <= 0.0:
                # Update running node names to remove closed nodes
                running_node_names = [name for name in running_node_names if
                                      (name not in unapproved_nodes and name not in missing_nodes)]
                idle_nodes = self._hpc_client.check_nodes_idle(running_node_names)
                logging.info("Get idle_nodes:{}".format(str(idle_nodes)))
                idle_timeout_nodes = self._check_node_idle_timeout([node.node_name for node in idle_nodes])
                logging.info("Get idle_timeout_nodes:{}".format(str(idle_timeout_nodes)))
                node_count_after_autostop = len(running_node_names) - len(idle_timeout_nodes)

                # Maintain min_node_count (and try to stay stablish by sorting idle nodes)
                if node_count_after_autostop < self.min_node_count:
                    preserved_node_count = self.min_node_count - node_count_after_autostop
                    logging.info("Preserving min_core_count({}) idle nodes from autostop".format(preserved_node_count))
                    if len(idle_timeout_nodes) <= preserved_node_count:
                        idle_timeout_nodes=[]
                    else:                        
                        sorted_idle_timeout_nodes = sorted(idle_timeout_nodes, key=lambda n: n.upper())
                        idle_timeout_nodes = sorted_idle_timeout_nodes[preserved_node_count:]                 
                    
                self._set_nodes_draining(idle_timeout_nodes)
            else:
                # If there is still node growing, we won't shrink at the same time
                self._reset_node_idle_check()
                logging.info(
                    "Reset node idle timeout as there are nodes being provisioning. Cores in provisioning: {}".format(
                        self.get_cores_in_provisioning()))

    def _reset_node_idle_check(self):
        # type: () -> ()
        self._node_idle_check_table.clear()
        self._removed_nodes.clear()

    def _check_node_idle_timeout(self, node_names, now=None):
        # type: (Iterable[str], datetime) -> [str]
        if now is None:
            now = datetime.now(pytz.utc)
        new_node_idle_check_table = {}
        for u_node_name in _upper_strings(node_names):
            if u_node_name in self._node_idle_check_table:
                if u_node_name in self._removed_nodes:
                    new_node_idle_check_table[u_node_name] = now
                    self._removed_nodes.discard(u_node_name)
                else:
                    new_node_idle_check_table[u_node_name] = self._node_idle_check_table[u_node_name]
            else:
                new_node_idle_check_table[u_node_name] = now
        self._node_idle_check_table = new_node_idle_check_table
        logging.info("_check_node_idle_timeout: now - " + str(now))
        logging.info("_check_node_idle_timeout: " + str(self._node_idle_check_table))
        return [name for name, value in self._node_idle_check_table.items() if
                (now - value) >= self._node_idle_timedelta]


    def configure_cluster(self):
        # type: () -> ()
        logging.info("Current Node Info table:\n{}".format(self._slave_info_table))
        self._provision_compute_nodes_state_machine()
        self._check_runaway_and_idle_compute_nodes()
        self._drain_and_stop_nodes()

    def _start_configure_cluster_timer(self):
        # type: () -> ()
        try:
            self.configure_cluster()
        except Exception as ex:
            logging.exception(ex)
        timer = threading.Timer(self.CHECK_CONFIGURING_NODES_INTERVAL, self._start_configure_cluster_timer)
        timer.daemon = True
        timer.start()


    def start(self):
        self._start_configure_cluster_timer()

    def _check_deploy_failure(self, set_nodes):
        # type: (List[Tuple[str, int]]) -> ()
        for node, old_state in set_nodes:
            if old_state == HpcState.Provisioning:
                logging.error(
                    "Node {} failed to deploy. Previous state: {}".format(node, HpcState.Names[old_state]))

    def _set_nodes_draining(self, node_names):
        # type: (Iterable[str]) -> ()
        self._removed_nodes.update(_upper_strings(node_names))
        self._check_deploy_failure(self._set_node_state(node_names, HpcState.Draining, "Draining"))

    def _set_nodes_closing(self, node_names):
        # type: (Iterable[str]) -> ()
        self._removed_nodes.update(_upper_strings(node_names))
        self._check_deploy_failure(self._set_node_state(node_names, HpcState.Closing, "Closing"))

    def _set_nodes_closed(self, node_names):
        # type: (Iterable[str]) -> ()
        self._removed_nodes.update(_upper_strings(node_names))
        closed_nodes = self._set_node_state(node_names, HpcState.Closed, "Closed")
        if self._node_closed_callbacks:
            for callback in self._node_closed_callbacks:
                callback([node for node, _ in closed_nodes])
        self._check_deploy_failure(closed_nodes)

    def _set_nodes_running(self, node_names):
        # type: (Iterable[str]) -> ()
        self._set_node_state(node_names, HpcState.Running, "Running")

    def _set_node_state(self, node_names, node_state, state_name):
        # type: (Iterable[str], int, str) -> [(str, int)]
        set_nodes = []
        for node_name in node_names:
            u_hostname = node_name.upper()
            if u_hostname in self._slave_info_table:
                if self._slave_info_table[u_hostname].state != node_state:
                    old_state = self._slave_info_table[u_hostname].state
                    self._slave_info_table[u_hostname] = self._slave_info_table[u_hostname]._replace(state=node_state)
                    set_nodes.append((u_hostname, old_state))
                    logging.info("Host {} set to {} from {}.".format(
                        u_hostname, state_name, HpcState.Names[old_state]))
            else:
                logging.error("Host {} is not recognized. State {} Ignored.".format(u_hostname, state_name))
        return set_nodes

    def _drain_and_stop_nodes(self):
        # type: () -> ()
        logging.info("Checking for draining nodes to close and shutdown...")
        node_names_to_drain = self._get_nodes_name_in_state(HpcState.Draining)
        node_names_to_close = self._get_nodes_name_in_state(HpcState.Closing)

        if not node_names_to_close and not node_names_to_drain:
            logging.info("No nodes to close.")
            return

        if node_names_to_drain:
            drained_node_names = self._drain_nodes_state_machine(node_names_to_drain)
            if drained_node_names:
                node_names_to_close += drained_node_names  # short-cut the drained nodes to close

        if node_names_to_close:
            self._close_node_state_machine(node_names_to_close)

    def _drain_nodes_state_machine(self, node_names):
        # type: (list[str]) -> list[str]
        logging.info("Draining nodes: {}".format(node_names))
        take_offline_node_list = []
        invalid_state_node_dict = {}
        drained_node_names = []
        node_status_list = self._hpc_client.get_node_status_exact(node_names)
        for node_status in node_status_list:
            node_name = _get_node_name_from_status(node_status)
            node_state = _get_node_state_from_status(node_status)
            if _check_node_state_online(node_status):
                take_offline_node_list.append(node_name)
            elif _check_node_state_offline(node_status):
                drained_node_names.append(node_name)
            else:
                invalid_state_node_dict[node_name] = node_state

        missing_nodes = _find_missing_nodes(node_names, _get_node_names_from_status(node_status_list))

        try:
            if invalid_state_node_dict:
                logging.info("Node(s) in invalid state when draining: {}".format(str(invalid_state_node_dict)))
            if take_offline_node_list:
                logging.info("Taking node(s) offline: {}".format(str(take_offline_node_list)))
                self._hpc_client.take_nodes_offline(take_offline_node_list)
        except:
            # Swallow all exceptions here. As we don't want any exception to prevent drained nodes to be closed
            logging.exception('Exception happened when draining compute node.')

        if drained_node_names:
            logging.info("Drained nodes:{}".format(drained_node_names))
            self._set_nodes_closing(drained_node_names)
        if missing_nodes:
            logging.info("Missing nodes when draining:{}".format(missing_nodes))
            self._set_nodes_closed(missing_nodes)

        return drained_node_names

    def _close_node_state_machine(self, node_names):
        # type: (list[str]) -> ()
        logging.info("Closing nodes: {}".format(node_names))
        to_remove_node_names = []
        re_drain_node_names = []
        closed_node = []
        node_status_list = self._hpc_client.get_node_status_exact(node_names)
        for node_status in node_status_list:
            node_name = node_status[HpcRestClient.NODE_STATUS_NODE_NAME_KEY]  # type: str
            if _check_node_health_unapproved(node_status):
                # already removed node
                closed_node.append(node_name)
            else:
                if not _check_node_state_offline(node_status):
                    # node is not properly drained
                    re_drain_node_names.append(node_name)
                else:
                    to_remove_node_names.append(node_name)

        # more already removed nodes
        closed_node += _find_missing_nodes(node_names, re_drain_node_names + to_remove_node_names)

        try:
            if to_remove_node_names:
                logging.info("Remove node(s): {}".format(to_remove_node_names))
                self._deleted_nodes.update(to_remove_node_names)
                self._hpc_client.remove_nodes(to_remove_node_names)
        except:
            # Swallow all exceptions here. As we don't want any exception to prevent removed nodes go to closed
            logging.exception('Exception happened when configuring compute node.')

        if closed_node:
            logging.info("Closed nodes:{}".format(closed_node))
            self._set_nodes_closed(closed_node)
        if re_drain_node_names:
            logging.info("Closed nodes failed:{}".format(re_drain_node_names))
            self._set_nodes_draining(re_drain_node_names)

    def _check_node_in_specified_group(self, node_status, group_name):
        # type: (dict[str, any]) -> bool
        group_names = list(_upper_strings(node_status[HpcRestClient.NODE_STATUS_NODE_GROUP_KEY]))
        in_group = group_name.upper() in group_names
        logging.debug("Checking node in group {} from groups {} (ingroup: {})".format(group_name.upper(), group_names, in_group))
        return in_group

SlaveInfo = NamedTuple("SlaveInfo",
                       [("hostname", str), ("node_id", str), ("cpus", float), ("last_seen", datetime), ("state", int)])