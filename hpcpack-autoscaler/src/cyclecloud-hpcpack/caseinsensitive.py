from typing import Any, Dict, List, Optional, Union, Set

def ci_equals(a:Optional[str], b:Optional[str]) -> bool:
    if a is None or b is None:
        return a == b
    return a.casefold() == b.casefold()

def ci_in(a:str, b:Union[List[str], Set[str], Dict[str, Any]]) -> bool:
    if isinstance(b, dict):
        b = b.keys()
    for c in b:
        if ci_equals(a, c):
            return True
    return False

def ci_notin(a:str, b:Union[List[str], Set[str], Dict[str, Any]]) -> bool:
    return not ci_in(a, b)

def ci_lookup(a:str, b:Union[List[str], Set[str]]) -> Optional[str]:
    for c in b:
        if ci_equals(a, c):
            return c
    return False

def ci_set(a:Union[List[str], Set[str]]) -> Set[str]:
    dic: Dict[str, str] = {}
    for c in a:
        if c.casefold() in dic:
            continue
        dic[c.casefold()] = c
    return set(dic.values())

def ci_interset(a:Union[List[str], Set[str]], b:Union[List[str], Set[str]]) -> Set[str]:
    r = set()
    a = ci_set(a)
    b = ci_set(b)
    for c in a:
        if ci_in(c, b):
            r.add(c)
    return r
