from datetime import datetime, timedelta
from typing import Optional, List, Union
import jsonpickle
import os
from .caseinsensitive import ci_in, ci_equals

class HpcNodeItem:
    def __init__(
        self,
        node_id: str,
        hostname: str
    ) -> None:
        self.node_id = node_id
        self.hostname = hostname
        self.emerge_time = datetime.utcnow()
        self.idle_from: Optional[datetime] = None
        self.shrink_time: Optional[datetime] = None
        self.archive_time: Optional[datetime] = None

    def __str__(self) -> str:
        return "HpcNodeItem(node_id={}, hostname={}, emerge_time={}, idle_from={}, shrink_time={})".format(
            self.node_id, self.hostname, self.emerge_time, self.idle_from, self.shrink_time)
    
    def __repr__(self) -> str:
        return "HpcNodeItem(node_id={}, hostname={}, emerge_time={}, idle_from={}, shrink_time={})".format(
            self.node_id, self.hostname, self.emerge_time, self.idle_from, self.shrink_time)

class HpcNodeHistory:
    def __init__(
        self,
        statefile: str
    ) -> None:
        self.statefile = statefile
        self.updated: datetime = datetime.utcnow()
        self.__items: List[HpcNodeItem] = []
        self.reload()

    @property
    def all_items(self) -> List[HpcNodeItem]:
        return self.__items

    @property
    def active_items(self) -> List[HpcNodeItem]:
        return [i for i in self.__items if i.archive_time is None]

    @property
    def archived_items(self) -> List[HpcNodeItem]:
        return [i for i in self.__items if i.archive_time is not None]

    def find_by_id(self, node_id: str) -> Optional[HpcNodeItem]:
        for n in self.__items:
            if ci_equals(n.node_id, node_id):
                return n
        return None

    def find_by_hostname(self, hostname: str) -> Optional[HpcNodeItem]:
        for n in self.active_items:
            if ci_equals(n.hostname, hostname):
                return n
        return None
    
    def find_items(self, ids:List[str] = [], hostnames:List[str] = []) -> List[HpcNodeItem]:
        return [i for i in self.__items if ci_in(i.node_id, ids) or ci_in(i.hostname, hostnames)]

    def insert(self, item: HpcNodeItem) -> None:
        existingItem = self.find_by_id(item.node_id)
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
            except:
                pass
        if nodehistory:
            # If file was updated 7 days ago, do not load it
            if nodehistory["updated"] + timedelta(days=7) > datetime.utcnow() and nodehistory["updated"] < datetime.utcnow():
                self.__items.clear()
                self.__items.extend(nodehistory["items"])
                try:
                    # if file was updated 3 minutes ago, the idle_from time is not correct
                    if nodehistory["updated"] + timedelta(minutes=3) < datetime.utcnow():
                        for n in self.__items:
                            if n.shrink_time is None:
                                n.idle_from = None
                except:
                    self.__items.clear()

    def save(self) -> None:
        pickedContent = jsonpickle.encode(
            {
                'updated': datetime.utcnow(),
                'items': self.__items
            })
        with open(self.statefile, 'w') as f:
                f.write(pickedContent)

    def __str__(self) -> str:
        return "HpcNodeHistory(updated={}, items={})".format(self.updated, self.active_items)
    
    def __repr__(self) -> str:
        return "HpcNodeHistory(updated={}, items={})".format(self.updated, self.active_items)
