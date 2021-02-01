from datetime import datetime, timedelta
import json
from time import sleep
import requests
from requests.models import Response
import urllib3
from requests.exceptions import HTTPError
from typing import Any, Dict, Iterable, List, NamedTuple, Optional

import hpc.autoscale.hpclogging as logging
from .caseinsensitive import ci_equals, ci_in, ci_interset

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

GrowDecision = NamedTuple("GrowDecision", [("cores_to_grow", float), ("nodes_to_grow", float), ("sockets_to_grow", float)])
IdleNode = NamedTuple("IdleNode", [("node_name", str), ("timestamp", datetime), ("server_name", float)])

# TODO: change all method inputs to either all in json format or not

def _return_json_from_res(
    res: Response
) -> Any:
    return json.loads(res.content)

class HpcRestClient:
    DEFAULT_COMPUTENODE_TEMPLATE = "Default ComputeNode Template"
    # auto-scale api set
    GROW_DECISION_API_ROUTE = "https://{}/HpcManager/api/auto-scale/grow-decision"
    CHECK_NODES_IDLE_ROUTE = "https://{}/HpcManager/api/auto-scale/check-nodes-idle"
    # node management api set
    LIST_NODES_ROUTE = "https://{}/HpcManager/api/nodes"
    LIST_NODES_STATUS_ROUTE = "https://{}/HpcManager/api/nodes/status"
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

    def __init__(
        self, 
        config: Dict[str, Any], 
        pem: str, 
        hostname: str = "localhost"
    ) -> None:
        self.hostname = hostname
        self._pem = pem

        logging.initialize_logging(config)
        # self.logger = logging_aux.init_logger_aux("hpcframework.restclient", 'hpcframework.restclient.log')

    def _log_error(
        self, 
        function_name: str, 
        res: Response
    ) -> None:
        logging.error("{}: status_code:{} content:{}".format(function_name, res.status_code, res.content))

    def _log_info(
        self, 
        function_name: str, 
        res: Response
    ) -> None:
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

    def _post(
        self, 
        function_name: str, 
        function_route: str,
        data
    ) -> Response:
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
    def get_grow_decision(
        self, 
        node_group_name: Optional[str] = None
    ) -> Dict[str, GrowDecision]:
        url = self.GROW_DECISION_API_ROUTE.format(self.hostname)
        res = requests.post(url, verify=False, cert=self._pem, timeout=15)
        if res.ok:
            logging.info(res.content)
            grow_decision_dict = {k: GrowDecision(v['CoresToGrow'], v['NodesToGrow'], v['SocketsToGrow']) for k, v in json.loads(res.content).items()}
            if not ci_in("default", grow_decision_dict):
                grow_decision_dict["default"] = GrowDecision(0.0, 0.0, 0.0)
            return grow_decision_dict
        else:
            logging.error("status_code:{} content:{}".format(res.status_code, res.content))

    def list_nodes(
        self, 
        include_headnode: bool = False,
        include_details: bool = False,
        filters: Optional[Dict[str, str]] = None
    ) -> List[Any]:

        filters = filters or {}
        apiRoute = self.LIST_NODES_STATUS_ROUTE if include_details else self.LIST_NODES_ROUTE
        res = self._get(self.list_nodes.__name__, apiRoute, filters)
        nodesjs = _return_json_from_res(res)
        if not include_headnode:
            nodesjs = [node for node in nodesjs if node["Name"].lower() != self.hostname.lower()]
        return nodesjs

    def list_computenodes(self) -> List[Any]:
        nodes = self.list_nodes(include_details=True, filters={"nodeGroup":"ComputeNodes"})
        return [n for n in nodes if not ci_interset(["HeadNodes", "WCFBrokerNodes"], n["Groups"])]

    def list_idle_nodes(
        self, 
        min_idle_time: int = 300, 
        include_headnode: bool = False
    ) -> List[IdleNode]:
        nodesjs = self.list_nodes()
        idle_nodes = self.check_nodes_idle([node["Name"] for node in nodesjs])
        idle_nodes = {n.node_name.lower(): n for n in idle_nodes}
        for node in nodesjs:
            if node["Name"] not in idle_nodes:
                print("Node {} not idle".format(node["Name"]))
            else:
                print("Node {} is idle".format(node["Name"]))
        return idle_nodes

    def check_nodes_idle(
        self, 
        nodes: Iterable[str]
    ) -> List[IdleNode]:
        data = json.dumps(nodes)
        res = self._post(self.check_nodes_idle.__name__, self.CHECK_NODES_IDLE_ROUTE, data)
        jobjs = json.loads(res.content)
        return [IdleNode(idle_info['NodeName'], idle_info['TimeStamp'], idle_info['ServerName']) for idle_info in jobjs]

    # Starts node management api
    def bring_nodes_online(
        self, 
        nodes: Iterable[str]
    ):
        data = json.dumps(nodes)
        res = self._post(self.bring_nodes_online.__name__, self.BRING_NODES_ONLINE_ROUTE, data)
        return _return_json_from_res(res)

    def take_nodes_offline(
        self, 
        nodes: Iterable[str]
    ):
        data = json.dumps(nodes)
        res = self._post(self.take_nodes_offline.__name__, self.TAKE_NODES_OFFLINE_ROUTE, data)
        return _return_json_from_res(res)

    def assign_default_compute_node_template(
        self, 
        nodes: Iterable[str]
    ):
        return self.assign_nodes_template(nodes, self.DEFAULT_COMPUTENODE_TEMPLATE)

    def assign_nodes_template(
        self, 
        nodes: Iterable[str], 
        template_name
    ):
        params = json.dumps({"nodeNames": nodes, "templateName": template_name})
        res = self._post(self.assign_nodes_template.__name__, self.ASSIGN_NODES_TEMPLATE_ROUTE, params)
        return _return_json_from_res(res)

    def remove_nodes(
        self, 
        nodes: Iterable[str]
    ):
        data = json.dumps(nodes)
        res = self._post(self.remove_nodes.__name__, self.REMOVE_NODES_ROUTE, data)
        return _return_json_from_res(res)

    def get_node_status_exact(
        self, 
        node_names: Iterable[str]
    ):
        # type: (Iterable[str]) -> list[dict[str, Any]]
        params = json.dumps({"nodeNames": node_names})
        res = self._post(self.get_node_status_exact.__name__, self.NODE_STATUS_EXACT_ROUTE, params)
        return _return_json_from_res(res)

    def wait_node_state(
        self, 
        node_names: Iterable[str],
        target_state: str,
        timeout_seconds: int = 30,
        interval: int = 1
    ) -> bool:
        end = datetime.utcnow()
        if timeout_seconds < 0:
            end = datetime.utcnow() + timedelta(weeks=9999)
        elif timeout_seconds > 0:
            end = datetime.utcnow() + timedelta(seconds=timeout_seconds)
        while True:
            nodes = self.get_node_status_exact(node_names)
            if len(nodes) == len([n for n in nodes if ci_equals(n["NodeState"], target_state)]):
                return True
            if datetime.utcnow() > end:
                return False
            sleep(interval) 

    # Starts node group api
    def list_node_groups(
        self, 
        group_name: Optional[str] = None
    ):
        params = {}
        if not group_name:
            params['nodeGroupName'] = group_name
        res = self._get(self.list_node_groups.__name__, self.LIST_NODE_GROUPS_ROUTE, params)
        return _return_json_from_res(res)

    def add_node_group(
        self, 
        group_name: str, 
        group_description: str = ""
    ):
        params = json.dumps({"name": group_name, "description": group_description})
        res = self._post(self.add_node_group.__name__, self.ADD_NEW_GROUP_ROUTE, params)
        return _return_json_from_res(res)

    def add_node_to_node_group(
        self, 
        group_name: str, 
        node_names: Iterable[str]
    ):
        logging.debug("Adding nodes {} to nodegroup {}".format(node_names, group_name))
        res = self._post(self.add_node_to_node_group.__name__, self.ADD_NODES_TO_NODE_GROUP_ROUTE.format(
            group_name=group_name), json.dumps(node_names))
        return _return_json_from_res(res)

