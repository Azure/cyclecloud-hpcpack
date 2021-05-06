import json
from hpc.autoscale.node.node import Node
import requests
import urllib3
import hpc.autoscale.hpclogging as logging
from datetime import datetime, timedelta
from time import sleep
from requests.models import Response
from requests.exceptions import HTTPError
from typing import Any, Dict, Iterable, List, NamedTuple, Optional, Union
from .commonutil import ci_equals, ci_in, ci_notin, ci_interset, make_dict_single

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

GrowDecision = NamedTuple("GrowDecision", [("cores_to_grow", float), ("nodes_to_grow", float), ("sockets_to_grow", float)])
IdleNode = NamedTuple("IdleNode", [("node_name", str), ("timestamp", datetime), ("server_name", float)])
NodeIdentity = NamedTuple("NodeIdentity", [("Id", str), ("Name", str)])

class HpcNode:
    # Possible values for HPC node health: 
    #   OK, Warning, Error, Transitional, Unapproved
    # Possible values for HPC node state (states marked with * shall not occur for CC nodes):
    #   Unknown, Provisioning, Offline, Starting, Online, Draining, Rejected(*), Removing, NotDeployed(*), Stopping(*) 
    def __init__(
        self, 
        id: str,
        name: str, 
        nodehealth: str, 
        nodestate: str,
        nodegroups: List[str],
        nodetemplate: Optional[str] = None
    ) -> None:
        self.id = id
        self.name = name
        self.health = nodehealth
        self.state = nodestate
        self.nodegroups = nodegroups
        self.nodetemplate = nodetemplate
        self.cc_node_id: Optional[str] = None
        self.idle_from: Optional[datetime] = None
        self.bound_cc_node: Optional[Node] = None
    
    @property
    def is_computenode(self) -> bool:
        return ci_in("ComputeNodes", self.nodegroups) and not ci_interset(["HeadNodes", "WCFBrokerNodes"], self.nodegroups)

    @property
    def active(self) -> bool:
        return ci_notin(self.state, ["Rejected", "NotDeployed", "Stopping", "Removing"])

    @property
    def is_cc_node(self) -> bool:
        return bool(self.cc_node_id)

    @property
    def error(self) -> bool:
        return ci_equals(self.health, "Error")

    @property
    def template_assigned(self) -> bool:
        return bool(self.nodetemplate)

    @property
    def transitioning(self) -> bool:
        return ci_in(self.state, ["Provisioning", "Starting", "Draining", "Removing"])

    @property
    def ready_for_job(self) -> bool:
        return ci_equals(self.state, "Online") and ci_equals(self.health, "OK")

    @property
    def shall_addcyclecloudtag(self) -> bool:
        return self.bound_cc_node and ci_notin("CycleCloudNodes", self.nodegroups)

    @property
    def shall_addnodearraytag(self) -> bool:
        return self.bound_cc_node and ci_notin(self.cc_nodearray, self.nodegroups)

    @property
    def cc_nodearray(self) -> Optional[str]:
        return self.bound_cc_node.nodearray if self.bound_cc_node else None

    @property
    def removed_cc_node(self) -> bool:
        if self.bound_cc_node:
            return False
        return self.is_cc_node or (ci_in("CycleCloudNodes", self.nodegroups) and (self.error or not self.template_assigned))

    @property
    def stopped_cc_node(self) -> bool:
        if not self.bound_cc_node:
            return False
        return ci_equals(self.bound_cc_node.target_state, 'Deallocated')

    def shall_stop(self, idle_timeout) -> bool:
        if not self.bound_cc_node:
            return False
        if ci_equals(self.bound_cc_node.target_state, 'Deallocated'):
            return False
        if self.idle_from is None:
            return False
        return self.idle_from + timedelta(seconds=idle_timeout) < datetime.utcnow()

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
            logging.info("{} resp: {}".format(function_name, str(res.content)))
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
        nodes: List[NodeIdentity] = self.list_nodes(status=False, filters=filters)
        return [n.Name for n in nodes]

    def list_nodes(
        self, 
        filters: Dict[str, str] = {}
    ) -> Union[List[NodeIdentity], List[HpcNode]]:
        res = self._get(self.list_nodes.__name__, self.LIST_NODES_ROUTE, filters)
        nodes = [NodeIdentity(i['Id'], i['Name']) for i in json.loads(res.content)]
        if len(nodes) == 0:
            return nodes
        nodeId_byName = make_dict_single(nodes, keyfunc=lambda n : n.Name, valuefunc=lambda n : n.Id)
        res = self._get(self.list_nodes.__name__, self.LIST_NODES_STATUS_ROUTE, filters)
        nodeStatusList = []
        for n in json.loads(res.content):
            nodeName = n["Name"]
            if nodeName in nodeId_byName:
                nodeStatusList.append(HpcNode(nodeId_byName[nodeName], nodeName, n["NodeHealth"],n["NodeState"],n["Groups"], n["NodeTemplate"]))
        return nodeStatusList

    def list_computenodes(self) -> List[HpcNode]:
        nodes = self.list_nodes(filters={"nodeGroup":"ComputeNodes"})
        return [n for n in nodes if n.is_computenode]

    def get_nodes(
        self, 
        node_names: Iterable[str]
    ) -> Union[List[NodeIdentity], List[HpcNode]]:
        assert len(node_names) > 0
        res = self._get(self.list_nodes.__name__, self.LIST_NODES_ROUTE, None)
        nodes = [NodeIdentity(i['Id'], i['Name']) for i in json.loads(res.content) if ci_in(i['Name'], node_names)]
        if len(nodes) == 0:
            return []
        nodeId_byName = make_dict_single(nodes, keyfunc=lambda n : n.Name, valuefunc=lambda n : n.Id)
        params = json.dumps({"nodeNames": node_names})
        res = self._post(self.get_node_status_exact.__name__, self.NODE_STATUS_EXACT_ROUTE, params)
        nodeStatusList = []
        for n in json.loads(res.content):
            nodeName = n["Name"]
            if nodeName in nodeId_byName:
                nodeStatusList.append(HpcNode(nodeId_byName[nodeName], nodeName, n["NodeHealth"],n["NodeState"],n["Groups"], n["NodeTemplate"]))
        return nodeStatusList

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

