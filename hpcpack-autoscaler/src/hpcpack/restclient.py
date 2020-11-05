import json
from collections import namedtuple

import requests
import urllib3
from requests.exceptions import HTTPError
from typing import Iterable

import hpc.autoscale.hpclogging as logging

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

GrowDecision = namedtuple("GrowDecision", "cores_to_grow nodes_to_grow sockets_to_grow")
IdleNode = namedtuple("IdleNode", "node_name timestamp server_name")


# TODO: change all method inputs to either all in json format or not


def _return_json_from_res(res):
    jobj = json.loads(res.content)
    return jobj


class HpcRestClient(object):
    DEFAULT_NODEGROUP_TOKEN = "DEFAULT"
    DEFAULT_COMPUTENODE_TEMPLATE = "Default ComputeNode Template"
    # auto-scale api set
    GROW_DECISION_API_ROUTE = "https://{}/HpcManager/api/auto-scale/grow-decision"
    CHECK_NODES_IDLE_ROUTE = "https://{}/HpcManager/api/auto-scale/check-nodes-idle"
    # node management api set
    LIST_NODES_ROUTE = "https://{}/HpcManager/api/nodes"
    BRING_NODES_ONLINE_ROUTE = "https://{}/HpcManager/api/nodes/bringOnline"
    TAKE_NODES_OFFLINE_ROUTE = "https://{}/HpcManager/api/nodes/takeOffline"
    ASSIGN_NODES_TEMPLATE_ROUTE = "https://{}/HpcManager/api/nodes/assignTemplate"
    REMOVE_NODES_ROUTE = "https://{}/HpcManager/api/nodes/remove"
    NODE_STATUS_EXACT_ROUTE = "https://{}/HpcManager/api/nodes/status/getExact"
    # node group api set
    NODE_GROUPS_ROOT_ROUTE = "https://{}/HpcManager/api/node-groups"
    LIST_NODE_GROUPS_ROUTE = NODE_GROUPS_ROOT_ROUTE
    ADD_NEW_GROUP_ROUTE = NODE_GROUPS_ROOT_ROUTE
    ADD_NODES_TO_NODE_GROUP_ROUTE = NODE_GROUPS_ROOT_ROUTE.format("{{}}") + "/{group_name}"

    # constants in result
    NODE_STATUS_NODE_NAME_KEY = "Name"
    NODE_STATUS_NODE_STATE_KEY = "NodeState"
    NODE_STATUS_NODE_STATE_ONLINE_VALUE = "Online"
    NODE_STATUS_NODE_STATE_OFFLINE_VALUE = "Offline"

    NODE_STATUS_NODE_HEALTH_KEY = "NodeHealth"
    NODE_STATUS_NODE_HEALTH_UNAPPROVED_VALUE = "Unapproved"
    NODE_STATUS_NODE_GROUP_KEY = "Groups"

    def __init__(self, config, pem, hostname="localhost"):
        # type: (str) -> None
        self.hostname = hostname
        self._pem = pem

        logging.initialize_logging(config)
        # self.logger = logging_aux.init_logger_aux("hpcframework.restclient", 'hpcframework.restclient.log')

    def _log_error(self, function_name, res):
        logging.error("{}: status_code:{} content:{}".format(function_name, res.status_code, res.content))

    def _log_info(self, function_name, res):
        logging.info("{}: {}".format(function_name, str(res.content)))

    # TODO: consolidate these ceremonies.
    def _get(self, function_name, function_route, params):
        headers = {"Content-Type": "application/json"}
        url = function_route.format(self.hostname)
        res = requests.get(url, headers=headers, verify=False, params=params, cert=self._pem)
        try:
            res.raise_for_status()
            self._log_info(function_name, res)
            return res
        except HTTPError:
            self._log_error(function_name, res)
            raise

    def _post(self, function_name, function_route, data):
        headers = {"Content-Type": "application/json"}
        url = function_route.format(self.hostname)
        res = requests.post(url, data=data, headers=headers, verify=False, cert=self._pem)
        try:
            res.raise_for_status()
            self._log_info(function_name, res)
            return res
        except HTTPError:
            self._log_error(function_name, res)
            raise

    # Starts auto-scale api
    def get_grow_decision(self, node_group_name=None):
        # type: (str) -> dict[str, GrowDecision]
        url = self.GROW_DECISION_API_ROUTE.format(self.hostname)
        res = requests.post(url, verify=False, cert=self._pem, timeout=15)
        if res.ok:
            logging.info(res.content)
            grow_decision_dict = {k.upper(): GrowDecision(v['CoresToGrow'], v['NodesToGrow'], v['SocketsToGrow']) for k, v in json.loads(res.content).items()}
            return grow_decision_dict
        else:
            logging.error("status_code:{} content:{}".format(res.status_code, res.content))

    def list_nodes(self, include_headnode=False):
        # type: (bool) -> dict[str, any]
        res = self._get("list-nodes", "https://{}/HpcManager/api/nodes", {})
        nodesjs = _return_json_from_res(res)
        if not include_headnode:
            nodesjs = [node for node in nodesjs if node["Name"].lower() != self.hostname.lower()]
        return nodesjs

    def list_idle_nodes(self, min_idle_time=300, include_headnode=False):
        # type: (int, bool) -> list[IdleNode]

        nodesjs = self.list_nodes()
        idle_nodes = self.check_nodes_idle([node["Name"] for node in nodesjs])
        idle_nodes = {n.node_name.lower(): n for n in idle_nodes}
        for node in nodesjs:
            if node["Name"] not in idle_nodes:
                print("Node {} not idle".format(node["Name"]))
            else:
                print("Node {} is idle".format(node["Name"]))

        return idle_nodes

    def check_nodes_idle(self, nodes):
        # type: (list[str]) -> list[IdleNode]
        data = json.dumps(nodes)
        res = self._post(self.check_nodes_idle.__name__, self.CHECK_NODES_IDLE_ROUTE, data)
        jobjs = json.loads(res.content)
        return [IdleNode(idle_info['NodeName'], idle_info['TimeStamp'], idle_info['ServerName']) for idle_info in jobjs]

    # Starts node management api
    def bring_nodes_online(self, nodes):
        data = json.dumps(nodes)
        res = self._post(self.bring_nodes_online.__name__, self.BRING_NODES_ONLINE_ROUTE, data)
        return _return_json_from_res(res)

    def take_nodes_offline(self, nodes):
        data = json.dumps(nodes)
        res = self._post(self.take_nodes_offline.__name__, self.TAKE_NODES_OFFLINE_ROUTE, data)
        return _return_json_from_res(res)

    def assign_default_compute_node_template(self, nodename_arr):
        return self.assign_nodes_template(nodename_arr, self.DEFAULT_COMPUTENODE_TEMPLATE)

    def assign_nodes_template(self, nodename_arr, template_name):
        params = json.dumps({"nodeNames": nodename_arr, "templateName": template_name})
        res = self._post(self.assign_nodes_template.__name__, self.ASSIGN_NODES_TEMPLATE_ROUTE, params)
        return _return_json_from_res(res)

    def remove_nodes(self, nodes):
        data = json.dumps(nodes)
        res = self._post(self.remove_nodes.__name__, self.REMOVE_NODES_ROUTE, data)
        return _return_json_from_res(res)

    def get_node_status_exact(self, node_names):
        # type: (Iterable[str]) -> list[dict[str, any]]
        params = json.dumps({"nodeNames": node_names})
        res = self._post(self.get_node_status_exact.__name__, self.NODE_STATUS_EXACT_ROUTE, params)
        return _return_json_from_res(res)

    # Starts node group api
    def list_node_groups(self, group_name=""):
        params = {}
        if group_name != "":
            params['nodeGroupName'] = group_name
        res = self._get(self.list_node_groups.__name__, self.LIST_NODE_GROUPS_ROUTE, params)
        return _return_json_from_res(res)

    def add_node_group(self, group_name, group_description=""):
        params = json.dumps({"name": group_name, "description": group_description})
        res = self._post(self.add_node_group.__name__, self.ADD_NEW_GROUP_ROUTE, params)
        return _return_json_from_res(res)

    def add_node_to_node_group(self, group_name, node_names):
        logging.debug("Adding nodes {} to nodegroup {}".format(node_names, group_name))
        res = self._post(self.add_node_to_node_group.__name__, self.ADD_NODES_TO_NODE_GROUP_ROUTE.format(
            group_name=group_name), json.dumps(node_names))
        return _return_json_from_res(res)

