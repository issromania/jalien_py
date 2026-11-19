"""alienpy:: Setup history for interactive shell"""

import atexit
import os
import sys
import logging
from pathlib import Path
from typing import Optional

from .global_vars import AlienSessionInfo
from .wb_api import lfn_list  # nosec PYL-W0614
from . import wb_api as _wb_api  # access to the live _wb_api.ALIENPY_GLOBAL_WB (replaced on reconnection/token-init)

HAS_READLINE = False

__platform = sys.platform.lower()
if __platform == 'darwin':
    try:
        import gnureadline as rl  # type: ignore  # mypy: no-redef
        HAS_READLINE = True
    except ImportError:
        pass
else:
    try:
        import readline as rl  # type: ignore
        HAS_READLINE = True
    except ImportError:
        pass


def setupHistory(wb) -> None:
    """Setup up history mechanics for readline module"""
    if os.getenv('ALIENPY_NO_HISTORY'): return
    if not HAS_READLINE or 'AlienSessionInfo' not in globals() or not wb: return

    # libedit (e.g. python-build-standalone/uv builds) uses its own file format (header line, escaped spaces) and cannot read
    # an empty or GNU readline history file (OSError EINVAL): keep its history in a separate file
    is_libedit = getattr(rl, 'backend', '') == 'editline' or 'libedit' in (rl.__doc__ or '')
    histfile = os.path.join(os.path.expanduser("~"), ".alienpy_history_libedit" if is_libedit else ".alienpy_history")
    if not os.path.exists(histfile): Path(histfile).touch(exist_ok = True)
    rl.set_history_length(-1)  # unlimited history
    if os.path.getsize(histfile) > 0:  # an empty file is created with the first save
        try:
            rl.read_history_file(histfile)
        except OSError as e:
            logging.error('setupHistory:: could not read the history file %s : %s', histfile, e)

    rl.parse_and_bind("bind ^I rl_complete" if is_libedit else "tab: complete")  # libedit has its own syntax
    rl.set_completer_delims(" ")

    matches = []  # readline calls complete() with state 0, 1, 2, ... until None: compute the matches (server listing) only for state 0

    def complete(text: str, state: int) -> Optional[str]:
        if state == 0:
            prompt_line = rl.get_line_buffer()
            tokens = prompt_line.split()
            if len(tokens) == 0:
                matches[:] = [f'{x} ' for x in AlienSessionInfo['commandlist']]
            elif len(tokens) == 1 and not prompt_line.endswith(' '):
                matches[:] = [f'{x} ' for x in AlienSessionInfo['commandlist'] if x.startswith(text)]
            else:
                matches[:] = lfn_list(_wb_api.ALIENPY_GLOBAL_WB or wb, text)
        return matches[state] if state < len(matches) else None

    rl.set_completer(complete)

    saved_len = [rl.get_current_history_length()]  # history entries already in the file

    def startup_hook() -> None:
        cur_len = rl.get_current_history_length()
        if cur_len > saved_len[0]:  # before next prompt save the new line(s); an empty line adds nothing to the history
            rl.append_history_file(cur_len - saved_len[0], histfile)
            saved_len[0] = cur_len
    rl.set_startup_hook(startup_hook)  # GNU readline: saved before each prompt
    atexit.register(startup_hook)  # libedit does not call the startup hook: saved at exit (nothing left to save with GNU readline)


if __name__ == '__main__':
    print('This file should not be executed!', file = sys.stderr, flush = True)
    sys.exit(95)
