import json
import requests
import urllib3
import hpc.autoscale.hpclogging as logging
from datetime import datetime, timedelta
from time import sleep
from requests.models import Response
from requests.exceptions import HTTPError
from typing import Any, Dict, Iterable, List, NamedTuple, Optional
from .commonutil import ci_equals, ci_in, ci_notin, ci_interset

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

SuspiciousCCNodeId = '00000000-0000-0000-0000-000000000000'
GrowDecision = NamedTuple("GrowDecision", [("cores_to_grow", float), ("nodes_to_grow", float), ("sockets_to_grow", float)])
IdleNode = NamedTuple("IdleNode", [("node_name", str), ("timestamp", datetime), ("server_name", float)])

class HpcNode:
    # Possible values for HPC node health: 
    #   OK, Warning, Error, Transitional, Unapproved
    # Possible values for HPC node state (states marked with * shall not occur for CC nodes):
    #   Unknown, Provisioning, Offline, Starting, Online, Draining, Rejected(*), Removing, NotDeployed(*), Stopping(*) 
    def __init__(
        self, 
        name: str, 
        nodehealth: str, 
        nodestate: str,
        nodegroups: List[str],
        nodetemplate: Optional[str] = None
    ) -> None:
        self.name = name
        self.health = nodehealth
        self.state = nodestate
        self.nodegroups = nodegroups
        self.nodetemplate = nodetemplate
        self.cc_node_id: Optional[str] = None
        self.cc_nodearray: Optional[str] = None
        self.idle_from: Optional[datetime] = None
        self.to_remove = False
        self.to_shrink = False
    
    @property
    def is_computenode(self) -> bool:
        return ci_in("ComputeNodes", self.nodegroups) and not ci_interset(["HeadNodes", "WCFBrokerNodes"], self.nodegroups)

    @property
    def active(self) -> bool:
        return ci_notin(self.state, ["Rejected", "NotDeployed", "Stopping", "Removing"])

    @property
    def cc_node(self) -> bool:
        return bool(self.cc_node_id) and self.cc_node_id != SuspiciousCCNodeId

    @property
    def suspicious_cc_node(self) -> bool:
        return self.cc_node_id == SuspiciousCCNodeId

    @property
    def error(self) -> bool:
        return ci_equals(self.state, "Error")

    @property
    def transitioning(self) -> bool:
        return ci_in(self.state, ["Provisioning", "Starting", "Draining", "Removing"])

    @property
    def ready_for_job(self) -> bool:
        return ci_equals(self.state, "Online") and ci_equals(self.health, "OK")


    @property
    def shall_addcyclecloudtag(self) -> bool:
        return self.cc_node and ci_notin("CycleCloudNodes", self.nodegroups) and (not self.to_remove) and (not self.to_shrink)

    @property
    def shall_addnodearraytag(self) -> bool:
        return self.cc_node and ci_notin(self.cc_nodearray, self.nodegroups) and (not self.to_remove) and (not self.to_shrink)

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

    # TODO: consolidate these ceremonies.
    def _get(
        self, 
        function_name: str, 
        function_route: str, 
        params
    ) -> Response:
        headers = {"Content-Type": "application/json"}
        url = function_route.format(self.hostname)
        res = requests.get(url, headers=headers, verify=False, params=params, cert=self._pem)
        try:
            res.raise_for_status()
            logging.info("{}: {}".format(function_name, str(res.content)))
            return res
        except HTTPError:
            logging.error("{}: status_code:{} content:{}".format(function_name, res.status_code, res.content))
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
            logging.info("{}: {}".format(function_name, str(res.content)))
            return res
        except HTTPError:
            logging.error("{}: status_code:{} content:{}".format(function_name, res.status_code, res.content))
            raise

    # Starts auto-scale api
    def get_grow_decision(self) -> Dict[str, GrowDecision]:
        res = self._post(self.get_grow_decision.__name__, self.GROW_DECISION_API_ROUTE, data=None)
        logging.info(res.content)
        grow_decision_dict = {k: GrowDecision(v['CoresToGrow'], v['NodesToGrow'], v['SocketsToGrow']) for k, v in json.loads(res.content).items()}
        if not ci_in("Default", grow_decision_dict):
            grow_decision_dict["Default"] = GrowDecision(0.0, 0.0, 0.0)
        return grow_decision_dict

    def list_node_names(
        self,
        filters: Dict[str, str] = {}
    ) -> List[str]:
        res = self._get(self.list_node_names.__name__, self.LIST_NODES_ROUTE, filters)
        retnodes = json.loads(res.content)
        return [n["NetBiosName"] for n in retnodes]

    def list_nodes(
        self, 
        filters: Dict[str, str] = {}
    ) -> List[HpcNode]:
        res = self._get(self.list_nodes.__name__, self.LIST_NODES_STATUS_ROUTE, filters)
        return [HpcNode(n["Name"], n["NodeHealth"],n["NodeState"],n["Groups"], n["NodeTemplate"]) for n in json.loads(res.content)]

    def list_computenodes(self) -> List[HpcNode]:
        nodes = self.list_nodes(filters={"nodeGroup":"ComputeNodes"})
        return [n for n in nodes if n.is_computenode]

    def get_nodes(
        self, 
        node_names: Iterable[str]
    ) -> List[HpcNode]:
        assert len(node_names) > 0
        params = json.dumps({"nodeNames": node_names})
        res = self._post(self.get_node_status_exact.__name__, self.NODE_STATUS_EXACT_ROUTE, params)
        return [HpcNode(n["Name"], n["NodeHealth"],n["NodeState"],n["Groups"], n["NodeTemplate"]) for n in json.loads(res.content)]

    def list_idle_nodes(
        self, 
        filters: Dict[str, str] = {}
    ) -> List[IdleNode]:
        node_names = self.list_node_names(filters)
        if len(node_names) > 0:
            return self.check_nodes_idle(node_names)
        return []

    def check_nodes_idle(
        self, 
        node_names: Iterable[str]
    ) -> List[IdleNode]:
        assert len(node_names) > 0
        data = json.dumps(node_names)
        res = self._post(self.check_nodes_idle.__name__, self.CHECK_NODES_IDLE_ROUTE, data)
        return [IdleNode(i['NodeName'], i['TimeStamp'], i['ServerName']) for i in json.loads(res.content)]

    # Starts node management api
    def bring_nodes_online(
        self, 
        node_names: Iterable[str]
    ) -> List[str]:
        assert len(node_names) > 0
        data = json.dumps(node_names)
        res = self._post(self.bring_nodes_online.__name__, self.BRING_NODES_ONLINE_ROUTE, data)
        return json.loads(res.content)

    def take_nodes_offline(
        self, 
        node_names: Iterable[str]
    ) -> List[str]:
        assert len(node_names) > 0
        data = json.dumps(node_names)
        res = self._post(self.take_nodes_offline.__name__, self.TAKE_NODES_OFFLINE_ROUTE, data)
        return json.loads(res.content)

    def assign_default_compute_node_template(
        self, 
        node_names: Iterable[str]
    ) -> List[str]:
        assert len(node_names) > 0
        return self.assign_nodes_template(node_names, self.DEFAULT_COMPUTENODE_TEMPLATE)

    def assign_nodes_template(
        self, 
        node_names: Iterable[str], 
        template_name: str
    ) -> List[str]:
        assert len(node_names) > 0 and template_name
        params = json.dumps({"nodeNames": node_names, "templateName": template_name})
        res = self._post(self.assign_nodes_template.__name__, self.ASSIGN_NODES_TEMPLATE_ROUTE, params)
        return json.loads(res.content)

    def remove_nodes(
        self, 
        node_names: Iterable[str]
    ) -> List[str]:
        assert len(node_names) > 0
        data = json.dumps(node_names)
        res = self._post(self.remove_nodes.__name__, self.REMOVE_NODES_ROUTE, data)
        return json.loads(res.content)

    def wait_node_state(
        self, 
        node_names: Iterable[str],
        target_state: str,
        timeout_seconds: int = 30,
        interval: int = 1
    ) -> bool:
        assert len(node_names) > 0
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
    ) -> List[str]:
        params = {}
        if group_name:
            params['nodeGroupName'] = group_name
        res = self._get(self.list_node_groups.__name__, self.LIST_NODE_GROUPS_ROUTE, params)
        return json.loads(res.content)

    def add_node_group(
        self, 
        group_name: str, 
        group_description: str = ""
    ) -> bool:
        params = json.dumps({"name": group_name, "description": group_description})
        try:
            self._post(self.add_node_group.__name__, self.ADD_NEW_GROUP_ROUTE, params)
            return True
        except:
            return False

    def add_node_to_node_group(
        self, 
        group_name: str, 
        node_names: Iterable[str]
    ) -> List[str]:
        assert len(node_names) > 0 and group_name
        logging.debug("Adding nodes {} to nodegroup {}".format(node_names, group_name))
        res = self._post(self.add_node_to_node_group.__name__, self.ADD_NODES_TO_NODE_GROUP_ROUTE.format(
            group_name=group_name), json.dumps(node_names))
        return json.loads(res.content)

