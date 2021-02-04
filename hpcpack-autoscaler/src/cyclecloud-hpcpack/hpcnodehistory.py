import jsonpickle
import os
import hpc.autoscale.hpclogging as logging
from datetime import datetime, timedelta
from typing import Iterable, Optional, List
from hpc.autoscale.node.node import Node
from .commonutil import ci_find_one, ci_in, ci_notin, ci_equals
from .hpcpackdriver import HpcNode, SuspiciousCCNodeId

class NodeHistoryItem:
    def __init__(
        self,
        node_id: str,
        hostname: Optional[str] = None,
        emerge_time: datetime = datetime.utcnow()
    ) -> None:
        self.node_id = node_id
        self.hostname = hostname
        self.emerge_time = emerge_time
        self.start_time = datetime.utcnow()
        self.idle_from: Optional[datetime] = None
        self.stop_time: Optional[datetime] = None
        self.archive_time: Optional[datetime] = None

    @property
    def shall_purge(self):
        if self.archive_time is None:
            return False
        return self.archive_time + timedelta(days=14) < datetime.utcnow()

    @property
    def archived(self):
        return self.archive_time is not None

    @property
    def stopping_or_stopped(self):
        return self.stop_time is not None

    def shall_stop(self, idle_timeout: int = 900):
        if self.archived or self.stopping_or_stopped:
            return False
        if self.idle_from is None:
            return False
        return self.idle_from + timedelta(seconds=idle_timeout) < datetime.utcnow()

    def __str__(self) -> str:
        return "HpcNodeItem(node_id={}, hostname={}, emerge_time={}, start_time={}, idle_from={}, shrink_time={})".format(
            self.node_id, self.hostname, self.emerge_time, self.start_time, self.idle_from, self.stop_time)
    
    def __repr__(self) -> str:
        return "HpcNodeItem(node_id={}, hostname={}, emerge_time={}, start_time={}, idle_from={}, shrink_time={})".format(
            self.node_id, self.hostname, self.emerge_time, self.start_time, self.idle_from, self.stop_time)

class HpcNodeHistory:
    def __init__(
        self,
        statefile: str,
        provisioning_timeout: int = 1500,
        idle_timeout: int = 900
    ) -> None:
        self.statefile = statefile
        self.provisioning_timeout = provisioning_timeout
        self.idle_timeout = idle_timeout
        self.__init_time: datetime = datetime.utcnow()
        self.__items: List[NodeHistoryItem] = []
        self.reload()

    @property
    def all_items(self) -> List[NodeHistoryItem]:
        return self.__items

    @property
    def active_items(self) -> List[NodeHistoryItem]:
        return [i for i in self.__items if not i.archived]

    @property
    def archived_items(self) -> List[NodeHistoryItem]:
        return [i for i in self.__items if i.archived]

    # The items recently archived
    @property
    def new_archived_items(self) -> List[NodeHistoryItem]:
        return [i for i in self.__items if i.archived and i.archive_time > self.__init_time]

    # The items in shrinking
    @property
    def shrink_items(self) -> List[NodeHistoryItem]:
        return [i for i in self.active_items if i.stop_time is not None]

    # The provisioning timeout items
    def provision_timeout_items(self, ready_nodes:List[str]) -> List[NodeHistoryItem]:
        target = datetime.utcnow() - timedelta(seconds=self.provisioning_timeout)
        return [i for i in self.active_items if ci_notin(i.hostname, ready_nodes) and (not i.stopping_or_stopped) and (i.start_time < target)]

    def find_by_id(self, node_id: str, include_archived: bool = False) -> Optional[NodeHistoryItem]:
        for n in self.active_items:
            if ci_equals(n.node_id, node_id):
                return n
        if include_archived:
            for n in self.archived_items:
                if ci_equals(n.node_id, node_id):
                    return n
        return None

    def find_by_hostname(self, hostname: str, include_archived: bool = False) -> Optional[NodeHistoryItem]:
        for n in self.active_items:
            if ci_equals(n.hostname, hostname):
                return n
        if include_archived:
            for n in self.archived_items.sort(reverse=True, key=lambda i: i.archive_time):
                if ci_equals(n.hostname, hostname):
                    return n
        return None
    
    def find_items(self, ids:List[str] = [], hostnames:List[str] = []) -> List[NodeHistoryItem]:
        return [i for i in self.__items if ci_in(i.node_id, ids) or ci_in(i.hostname, hostnames)]

    def insert(self, item: NodeHistoryItem) -> None:
        existingItem = self.find_by_id(item.node_id, include_archived=True)
        if existingItem is not None:
            if existingItem.archive_time is None:
                raise Exception("Duplicate node id {}".format(item.node_id))
            else:
                # node was deallocated and started again?
                item.emerge_time = existingItem.emerge_time
                self.__items.remove(existingItem)
        self.__items.append(item)
    
    def remove_items(self, ids:List[str] = [], hostnames:List[str] = []) -> None:
        for item in self.__items:
            if ci_in(item.node_id, ids) or ci_in(item.hostname, hostnames):
                self.__items.remove(item)
    
    def reload(self) -> None:
        nodehistory = {}
        if os.path.exists(self.statefile):
            try: 
                with open(self.statefile, 'r') as f:
                    encodedContent = f.read()
                    nodehistory = jsonpickle.decode(encodedContent)
            except Exception as ex:
                logging.warning("Failed to load history information from {}: {}".format(self.statefile, ex))

        if nodehistory:
            # If file was updated 7 days ago, do not load it
            if nodehistory["updated"] + timedelta(days=7) > datetime.utcnow() and nodehistory["updated"] < datetime.utcnow():
                self.__items.clear()
                try:
                    items: List[NodeHistoryItem] = nodehistory["items"]
                    self.__items.extend([i for i in items if not i.shall_purge])
                    # if file was updated 3 minutes ago, the idle_from time is not correct
                    if nodehistory["updated"] + timedelta(minutes=3) < datetime.utcnow():
                        logging.warning("The loaded history information was updated 3 minutes before, clear idle_from ...")
                        for n in self.__items:
                            if not n.stopping_or_stopped:
                                n.idle_from = None
                    logging.info("Loaded node history HpcNodeHistory(updated={}, active_items={})".format(nodehistory["updated"], self.active_items))
                except:
                    self.__items.clear()
            else:
                logging.warning("The loaded history information is out-dated, discard it")

    def synchronize(self, cc_nodes: Iterable[Node], hpc_nodes: Iterable[HpcNode]):
        now = datetime.utcnow()
        for cc_node in cc_nodes:
            nhi = self.find_by_id(cc_node.delayed_node_id.node_id)
            if nhi is None:
                nhi = NodeHistoryItem(cc_node.delayed_node_id.node_id, cc_node.hostname)
                self.insert(nhi)
            else:
                if not nhi.hostname:
                    nhi.hostname = cc_node.hostname
                elif not ci_equals(nhi.hostname, cc_node.hostname):
                    logging.warning("node hostname changed for node {}, {} => {}".format(nhi.node_id, nhi.hostname, cc_node.hostname))
                    # somehow the node hostname changed
                    # if the orig host name still in HPC node list, we will create a new item and give an empty node_id
                    if ci_in(nhi.hostname, [n.name for n in hpc_nodes]):
                        nhi.node_id = SuspiciousCCNodeId
                    else:
                        self.remove_items(ids=[nhi.node_id])
                    nhi = NodeHistoryItem(cc_node.delayed_node_id.node_id, cc_node.hostname, nhi.emerge_time)
                    self.insert(nhi)
                if nhi.archive_time is not None:
                    # an archived node shown again, remove the original one and 
                    self.__items.remove(nhi)
                    nhi = NodeHistoryItem(cc_node.delayed_node_id.node_id, cc_node.hostname, nhi.emerge_time)
                    self.insert(nhi)

            cc_node.create_time_unix = nhi.start_time.timestamp()
            cc_node.create_time_remaining = max(0, self.provisioning_timeout + cc_node.create_time_unix - now.timestamp())
            if nhi.idle_from is None:
                cc_node.idle_time_remaining = self.idle_timeout
            else:
                cc_node.idle_time_remaining = max(0, self.idle_timeout + nhi.idle_from.timestamp() - now.timestamp())

            if nhi.stopping_or_stopped:
                cc_node.delete_time_unix = nhi.stop_time.timestamp()
        
        # For node history items no longer exists in cc_nodes, we shall archive them
        cc_node_ids = [n.delayed_node_id.node_id for n in cc_nodes]
        for nhi in self.active_items:
            if ci_notin(nhi.node_id, cc_node_ids):
                if not nhi.stopping_or_stopped:
                    nhi.stop_time = now
                nhi.archive_time = now

        # Map the HPC nodes with CC nodes        
        for hpc_node in hpc_nodes:
            match_nhi = self.find_by_hostname(hpc_node.name, include_archived=True)
            if match_nhi:
                if not match_nhi.archived:
                    cc_node = ci_find_one(cc_nodes, match_nhi.hostname, target_func=lambda n : n.hostname)
                    assert cc_node is not None
                    hpc_node.cc_nodearray = cc_node.nodearray
                    hpc_node.cc_node_id = match_nhi.node_id
                    hpc_node.idle_from = match_nhi.idle_from
                    if match_nhi.stopping_or_stopped:
                        hpc_node.to_shrink = True
                elif hpc_node.error:
                    # An error HPC node matches an archived node history item, suppose it is an already-removed CC node
                    # if the HPC node is healthy, maybe it is an on-premise node with same hostname, we will not touch it
                    hpc_node.cc_node_id = match_nhi.node_id
                    hpc_node.to_remove = True
            else:
                # An error HPC node in CycleCloudNodes group, suppose it is an already-removed CC node
                # we will give it an empty cc node id
                if ci_in("CycleCloudNodes", hpc_node.nodegroups) and hpc_node.error:
                    hpc_node.to_remove = True
                    hpc_node.cc_node_id = SuspiciousCCNodeId

    def save(self) -> None:
        pickedContent = jsonpickle.encode(
            {
                'updated': datetime.utcnow(),
                'items': self.__items
            })
        with open(self.statefile, 'w') as f:
                f.write(pickedContent)

    def __str__(self) -> str:
        return "HpcNodeHistory(items={})".format(self.active_items)
    
    def __repr__(self) -> str:
        return "HpcNodeHistory(items={})".format(self.active_items)
