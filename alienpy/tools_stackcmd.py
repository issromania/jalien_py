"""alienpy:: command stack manipulation"""

import sys
from collections import deque

from .global_vars import AlienSessionInfo


def push2stack(path: str) -> None:
    if not path or 'AlienSessionInfo' not in globals(): return
    home = ''
    if AlienSessionInfo['alienHome']: home = AlienSessionInfo['alienHome'][:-1]
    if home and (path == home or path.startswith(f'{home}/')): path = f'~{path[len(home):]}'  # only a leading home path component
    AlienSessionInfo['pathq'].appendleft(path)


def deque_pop_pos(dq: deque, pos: int = 1) -> str:
    if abs(pos) > len(dq) - 1: return ''
    pos = - pos
    dq.rotate(pos)
    val = ''
    if pos > 0:
        val = dq.pop()
        dq.rotate(- pos)  # undo the initial rotation
    else:
        val = dq.popleft()
        dq.rotate(abs(pos))  # undo the initial rotation
    return val  # noqa: R504


if __name__ == '__main__':
    print('This file should not be executed!', file = sys.stderr, flush = True)
    sys.exit(95)
