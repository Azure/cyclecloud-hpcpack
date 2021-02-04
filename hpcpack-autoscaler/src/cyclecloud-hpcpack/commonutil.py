from typing import Any, Callable, Dict, Iterable, List, Optional, Union, Set, TypeVar

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

T = TypeVar("T")
K = TypeVar("K")
V = TypeVar("V")

def ci_find_one(source: Iterable[T], target_value:str, target_func:Callable[[T], str]) -> Optional[T]:
    for i in source:
        if ci_equals(target_value, target_func(i)):
            return i
    return None

def ci_find(source: Iterable[T], target_value:str, target_func:Callable[[T], str]) -> List[T]:
    ret = []
    for i in source:
        if ci_equals(target_value, target_func(i)):
            ret.append(i)
    return ret    

def make_dict(source: List[T], keyfunc: Callable[[T], K], valuefunc: Callable[[T], V] = lambda  x: x) -> Dict[K, List[V]]:
    by_key: Dict[K, List[V]] = {}
    for item in source:
        key = keyfunc(item)
        value = valuefunc(item)
        if key not in by_key:
            by_key[key] = []
        by_key[key].append(value)
    return by_key

def make_dict_single(
    source: List[T], keyfunc: Callable[[T], K], valuefunc: Callable[[T], V] = lambda  x: x, strict: bool = True) -> Dict[K, V]:
    result = make_dict(source, keyfunc, valuefunc)
    ret: Dict[K, V] = {}
    for key, value in result.items():
        if len(value) > 1:
            if strict or not reduce(lambda x, y: x == y, value):  # type: ignore
                raise RuntimeError(
                    "Could not partition list into single values - key={} values={}".format(
                        key, value,
                    )
                )
        ret[key] = value[0]
    return ret