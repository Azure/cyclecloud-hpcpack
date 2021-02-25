from hpc.autoscale.util import partition_single
import jsonpickle
import os
import hpc.autoscale.hpclogging as logging
from datetime import datetime, timedelta
from typing import Dict, Iterable, Optional, List
from hpc.autoscale.node.node import Node
from .commonutil import ci_find_one, ci_in, ci_notin, ci_equals
from .hpcpackdriver import HpcNode

class NodeHistoryItem:
    def __init__(
        self,
        cc_node_id: str,
        hostname: Optional[str] = None,
        emerge_time: datetime = datetime.utcnow()
    ) -> None:
        self.cc_id = cc_node_id
        self.hostname = hostname
        self.emerge_time = emerge_time
        self.start_time = datetime.utcnow()
        self.hpc_id = None
        self.idle_from: Optional[datetime] = None
        self.stop_time: Optional[datetime] = None

    @property
    def stopped(self):
        return self.stop_time is not None

    def restart(self):
        self.idle_from = None
        self.stop_time = None
        self.start_time = datetime.utcnow()

    def reset_hpc_id(self, new_id: Optional[str] = None):
        self.idle_from = None
        self.hpc_id = new_id

    def idle_timeout(self, idle_timeout_seconds: int = 900):
        if self.stopped or not self.idle_from or not self.hpc_id:
            return False
        return self.idle_from + timedelta(seconds=idle_timeout_seconds) < datetime.utcnow()

    def __str__(self) -> str:
        return "HpcNodeItem(cc_id={}, hostname={}, hpc_id={}, emerge_time={}, start_time={}, idle_from={}, stop_time={})".format(
            self.cc_id, self.hostname, self.hpc_id, self.emerge_time, self.start_time, self.idle_from, self.stop_time)
    
    def __repr__(self) -> str:
        return "HpcNodeItem(cc_id={}, hostname={}, hpc_id={}, emerge_time={}, start_time={}, idle_from={}, stop_time={})".format(
            self.cc_id, self.hostname, self.hpc_id, self.emerge_time, self.start_time, self.idle_from, self.stop_time)

    def archive_str(self, archive_time = datetime.utcnow()) -> str:
        return "cc_id={}, hostname={}, hpc_id={}, emerge_time={}, stop_time={}, archive_time={}".format(
            self.cc_id, self.hostname, self.hpc_id, self.emerge_time, self.stop_time, archive_time)

class HpcNodeHistory:
    def __init__(
        self,
        statefile: str,
        archivefile: str,
        provisioning_timeout: int = 1500,
        idle_timeout: int = 900
    ) -> None:
        self.__statefile = statefile
        self.__provisioning_timeout = provisioning_timeout
        self.__idle_timeout = idle_timeout
        self.__archivefile = archivefile
        self.__items: List[NodeHistoryItem] = []
        self.__items_to_archive: List[NodeHistoryItem] = []
        self.reload()

    @property
    def items(self) -> List[NodeHistoryItem]:
        return self.__items

    def find(
        self, 
        cc_id: Optional[str] = None,
        hpc_id: Optional[str] = None,
        hostname: Optional[str] = None
    ) -> Optional[NodeHistoryItem]:
        if not (bool(cc_id) or bool(hpc_id) or bool(hostname)):
            raise Exception("Specify at least one condition")
        for n in self.__items:
            if ((ci_equals(n.cc_id, cc_id) or not cc_id) and
                (ci_equals(n.hpc_id, hpc_id) or not hpc_id) and 
                (ci_equals(n.hostname, hostname) or not hostname)):
                return n
        return None       
    
    def find_items(self, hpc_ids:List[str] = [], cc_ids:List[str] = [], hostnames:List[str] = []) -> List[NodeHistoryItem]:
        return [i for i in self.__items if ci_in(i.hpc_id, hpc_ids) or ci_in(i.cc_id, cc_ids) or ci_in(i.hostname, hostnames)]

    def insert(self, item: NodeHistoryItem, overwrite: bool = False) -> None:
        existingItem = self.find(cc_id=item.cc_id)
        if existingItem is not None:
            if not overwrite:
                raise Exception("Duplicate node id {}".format(item.cc_id))
            else:
                self.__items.remove(existingItem)
        self.__items.append(item)
    
    def reload(self) -> None:
        nodehistory = {}
        if os.path.exists(self.__statefile):
            try: 
                with open(self.__statefile, 'r') as f:
                    encodedContent = f.read()
                    nodehistory = jsonpickle.decode(encodedContent)
            except Exception as ex:
                logging.warning("Failed to load history information from {}: {}".format(self.__statefile, ex))

        if nodehistory:
            # If file was updated 7 days ago, do not load it
            if nodehistory["updated"] + timedelta(days=7) > datetime.utcnow() and nodehistory["updated"] < datetime.utcnow():
                self.__items.clear()
                try:
                    items: List[NodeHistoryItem] = nodehistory["items"]
                    self.__items.extend(items)
                    # if file was updated 3 minutes ago, the idle_from time is not correct
                    if nodehistory["updated"] + timedelta(minutes=3) < datetime.utcnow():
                        logging.warning("The loaded history information was updated 3 minutes before, clear idle_from ...")
                        for n in self.__items:
                            if not n.stopped:
                                n.idle_from = None
                    logging.info("Loaded node history HpcNodeHistory(updated={}, items={})".format(nodehistory["updated"], self.items))
                except:
                    self.__items.clear()
            else:
                logging.warning("The loaded history information is out-dated, discard it")

    def synchronize(self, cc_nodes: Iterable[Node], hpc_nodes: Iterable[HpcNode]):
        nhi_by_cc_id = partition_single(self.items, func = lambda n: n.cc_id)
        now = datetime.utcnow()
        # Refresh node history items with CC node list
        for cc_node in cc_nodes:
            nhi = nhi_by_cc_id.get(cc_node.delayed_node_id.node_id)
            if nhi is None:
                nhi = NodeHistoryItem(cc_node.delayed_node_id.node_id, cc_node.hostname)
                self.insert(nhi)
                nhi_by_cc_id[nhi.cc_id] = nhi
            else:
                if not nhi.hostname:
                    nhi.hostname = cc_node.hostname
                elif not ci_equals(nhi.hostname, cc_node.hostname):
                    logging.warning("Node hostname changed for node {}, {} => {}".format(nhi.cc_id, nhi.hostname, cc_node.hostname))
                    # Somehow the node hostname changed, should not happen
                    # if the orig host name still in HPC node list, we shall remove the HPC node
                    if nhi.hpc_id:
                        hpc_node = ci_find_one(hpc_nodes, nhi.hpc_id, target_func=lambda n: n.id)
                        if hpc_node is not None:
                            hpc_node.cc_node_id = nhi.cc_id
                    self.__items.remove(nhi)
                    self.__items_to_archive.append(nhi)
                    nhi = NodeHistoryItem(cc_node.delayed_node_id.node_id, cc_node.hostname, nhi.emerge_time)
                    self.insert(nhi)
                    nhi_by_cc_id[nhi.cc_id] = nhi
            if ci_equals(cc_node.target_state, 'Deallocated') or ci_equals(cc_node.target_state, 'Terminated'):
                cc_node.create_time_remaining =  self.__provisioning_timeout
                cc_node.idle_time_remaining = self.__idle_timeout
                if not nhi.stopped:
                    nhi.stop_time = now
            else:
                if nhi.stopped:
                    nhi.restart()
                cc_node.create_time_unix = nhi.start_time.timestamp()
                cc_node.create_time_remaining = max(0, self.__provisioning_timeout + cc_node.create_time_unix - now.timestamp())
                if nhi.idle_from is None:
                    cc_node.idle_time_remaining = self.__idle_timeout
                else:
                    cc_node.idle_time_remaining = max(0, self.__idle_timeout + nhi.idle_from.timestamp() - now.timestamp())

        # Bound hpc nodes with CC nodes as per the info in node history
        cc_node_by_id: Dict[str, Node] = partition_single(cc_nodes, func=lambda n: n.delayed_node_id.node_id)
        nhi_by_hpc_id: Dict[str, NodeHistoryItem] = partition_single([nhi for nhi in self.__items if nhi.hpc_id], func = lambda n: n.hpc_id)
        for hpc_node in hpc_nodes:
            if hpc_node.is_cc_node:
                continue
            nhi = nhi_by_hpc_id.pop(hpc_node.id, None)
            if nhi is not None:
                hpc_node.cc_node_id = nhi.cc_id
                hpc_node.idle_from = nhi.idle_from
                hpc_node.bound_cc_node = cc_node_by_id.get(nhi.cc_id)

        # For the nodes already removed from HPC Pack side, if they still exist in CC side
        # We shall reset the hpc_id for the node history item
        for nhi in nhi_by_hpc_id.values():
            if ci_in(nhi.cc_id, cc_node_by_id):
                nhi.reset_hpc_id()

        hpc_node_to_bound = [n for n in hpc_nodes if not n.is_cc_node]
        nhi_to_bound_with_hpc = [nhi for nhi in self.__items if nhi.hostname and not nhi.hpc_id]
        if len(hpc_node_to_bound) > 0 and len(nhi_to_bound_with_hpc) > 0:
            candidate_nhi = [nhi for nhi in nhi_to_bound_with_hpc if ci_in(nhi.cc_id, cc_node_by_id)]
            candidate_nhi.extend([nhi for nhi in nhi_to_bound_with_hpc if not ci_in(nhi.cc_id, cc_node_by_id)])
            # Map the HPC nodes with CC nodes by hostname  
            for hpc_node in hpc_node_to_bound:
                # First search in active node history items
                match_nhi = ci_find_one(candidate_nhi, hpc_node.name, target_func=lambda n: n.hostname)
                if match_nhi:
                    match_nhi.reset_hpc_id(hpc_node.id)
                    hpc_node.cc_node_id = match_nhi.cc_id
                    hpc_node.bound_cc_node = cc_node_by_id.get(match_nhi.cc_id)

        # Refresh the node history items, archive the stale items
        hpc_ids = [hpc_node.id for hpc_node in hpc_nodes]
        self.__items_to_archive.extend([nhi for nhi in self.__items if ci_notin(nhi.cc_id, cc_node_by_id) and ci_notin(nhi.hpc_id, hpc_ids)])
        self.__items[:] = [nhi for nhi in self.__items if ci_in(nhi.cc_id, cc_node_by_id) or ci_in(nhi.hpc_id, hpc_ids)]

    def save(self) -> None:
        cur_time = datetime.utcnow()
        pickedContent = jsonpickle.encode(
            {
                'updated': cur_time,
                'items': self.__items
            })
        with open(self.__statefile, 'w') as sf:
            sf.write(pickedContent)
        if len(self.__items_to_archive) > 0:
            with open(self.__archivefile, 'a+') as af:
                for i in self.__items_to_archive:
                    af.write("\n{}".format(i.archive_str(cur_time)))

    def __str__(self) -> str:
        return "HpcNodeHistory(items={})".format(self.items)
    
    def __repr__(self) -> str:
        return "HpcNodeHistory(items={})".format(self.items)
