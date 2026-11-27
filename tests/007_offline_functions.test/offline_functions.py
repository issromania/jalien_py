#!/usr/bin/env python3
"""Offline checks of the alienpy helper functions: no connection to the JAliEn services is done.
Exit code is the number of failed checks; every failure is printed."""

import collections
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time

FAILED = []
CHECKS = 0


def check(name: str, got, expected) -> None:
    """Compare got with expected and record the failure"""
    global CHECKS
    CHECKS += 1
    if got != expected:
        FAILED.append(name)
        print(f'FAIL {name}\n     got      : {got!r}\n     expected : {expected!r}')


WORK_DIR = tempfile.mkdtemp(prefix = 'alienpy_offline_test_')
os.environ['ALIENPY_DEBUG_FILE'] = os.path.join(WORK_DIR, 'alienpy_debug.log')

from alienpy.global_vars import AlienSessionInfo  # noqa: E402
from alienpy.tools_nowb import (CreateJsonCommand, create_metafile, expand_path_local, fileIsValid, filter_file_prop, format_dst_fn, get_arg,  # noqa: E402
                                get_arg_2values, get_arg_value, get_arg_value_multiple, get_hash_meta, get_lfn_meta, get_lfn_name, get_size_meta,
                                is_help, list_files_local, make_tmp_fn, md5, name2regex, name_is_plain_regex, time_str2unixmili, valid_regex)
from alienpy.tools_stackcmd import deque_pop_pos  # noqa: E402
from alienpy.wb_api import retf_result2ret  # noqa: E402
from alienpy.xrd_tools import expand_path_grid  # noqa: E402


def t_expand_path_grid() -> None:
    """Grid path interpretation: home, current dir, . and .., prefixes, normalization, trailing /"""
    saved = {k: AlienSessionInfo.get(k) for k in ('alienHome', 'currentdir')}
    AlienSessionInfo.update(alienHome = '/alice/cern.ch/user/t/tester/', currentdir = '/alice/cern.ch/user/t/tester/work/')
    home = '/alice/cern.ch/user/t/tester'
    cwd = f'{home}/work'
    cases = (('~', home), ('~/', f'{home}/'), ('~/x', f'{home}/x'), ('%ALIEN/x', f'{home}/x'),
             ('x', f'{cwd}/x'), ('x/', f'{cwd}/x/'), ('./x', f'{cwd}/x'), ('.', cwd), ('..', home), ('../x', f'{home}/x'),
             ('/a//b/../c/', '/a/c/'), ('/a/./b', '/a/b'), ('alien:~/x', f'{home}/x'), ('alien:/alice/x', '/alice/x'),
             ('x y', f'{cwd}/x y'), ('/alice/x/', '/alice/x/'),
             ('/alice/d/profile//x', '/alice/d/profile/x'), ('/alice/d/myfile:1', '/alice/d/myfile:1'), ('/alice/d/alien:x', '/alice/d/alien:x'))
    for arg, expected in cases: check(f'expand_path_grid({arg!r})', expand_path_grid(arg), expected)
    AlienSessionInfo.update(saved)


def t_expand_path_local() -> None:
    """Local path interpretation: ~, relative to the current dir, file: prefix, trailing / for directories"""
    old_cwd = os.getcwd()
    os.chdir(WORK_DIR)
    real_work = os.path.realpath(WORK_DIR)
    old_home = os.environ.get('HOME')  # HOME is set here: the HOME of a CI job can be a not existing directory
    os.environ['HOME'] = WORK_DIR
    check('expand_path_local(~ existing dir)', expand_path_local('~'), f'{real_work}/')
    os.environ['HOME'] = os.path.join(WORK_DIR, 'missing_home')
    check('expand_path_local(~ not existing)', expand_path_local('~'), f'{real_work}/missing_home')
    if old_home is None:
        os.environ.pop('HOME', None)
    else:
        os.environ['HOME'] = old_home
    check('expand_path_local(rel file)', expand_path_local('somefile'), f'{real_work}/somefile')
    check('expand_path_local(file: prefix)', expand_path_local('file:somefile'), f'{real_work}/somefile')
    check('expand_path_local(. is dir)', expand_path_local('.'), f'{real_work}/')
    check('expand_path_local(strict, missing)', expand_path_local('missing_file', strict = True), '')
    check('expand_path_local(empty)', expand_path_local(''), '')
    check('expand_path_local(file: inside name)', expand_path_local('file:my_file:1'), f'{real_work}/my_file:1')
    os.chdir(old_cwd)


def t_args() -> None:
    """Argument helpers remove what they consume from the list"""
    a = ['-T', '4', '-f', '-glob', '*.log', '-exclude_re', 'x', '-exclude_re', 'y', 'src', 'dst']
    check('get_arg present', get_arg(a, '-f'), True)
    check('get_arg absent', get_arg(a, '-f'), False)
    check('get_arg_value', get_arg_value(a, '-T'), '4')
    check('get_arg_value_multiple', get_arg_value_multiple(a, '-exclude_re'), ['x', 'y'])
    check('arguments left', a, ['-glob', '*.log', 'src', 'dst'])
    b = ['src', '-T']
    check('get_arg_value missing value', get_arg_value(b, '-T'), None)
    c = ['-parent', '2', '3', 'src']
    check('get_arg_2values', get_arg_2values(c, '-parent'), ('2', '3'))
    check('get_arg_2values left', c, ['src'])
    check('is_help -h', is_help(['ls', '-h']), True)
    check('is_help --help str', is_help('ls --help'), True)
    check('is_help none', is_help(['ls', '-l']), False)
    d = ['-help', 'x']
    is_help(d, clean_args = True)
    check('is_help clean_args', d, ['x'])


def t_name2regex() -> None:
    """-name selection: verbs are converted to a regex matched against the file name; a plain regex is a pre-selection only"""
    def sel(name_arg: str, path: str) -> bool:
        return bool(re.match(name2regex(name_arg), path))
    check('begin match', sel('begin_std', '/d/001/stdout.log'), True)
    check('begin no match inside name', sel('begin_std', '/d/001/xstdout.log'), False)
    check('begin no match in dir name', sel('begin_std', '/d/stdx/out.log'), False)
    check('ext match', sel('ext_log', '/d/stdout.log'), True)
    check('ext no match', sel('ext_log', '/d/stdout.log.gz'), False)
    check('ends match', sel('ends_out_ext_log', '/d/stdout.log'), True)
    check('begin+ext', sel('begin_std_ext_log', '/d/001/stderr.log'), True)
    check('contain', sel('contain_err', '/d/001/stderr.log'), True)
    check('contain order a b', sel('contain_std_contain_err', '/d/stderr.log'), True)
    check('contain order b a', sel('contain_err_contain_std', '/d/stderr.log'), True)
    check('contain no match', sel('contain_xyz', '/d/stderr.log'), False)
    print('  (expected messages for the invalid -name selections:)', flush = True)
    for bad in ('begin_a_begin_b', 'ext_a_ext_b', 'begin', 'begin_a_ext',
                'contain_a_contain_b_contain_c_contain_d_contain_e'):
        check(f'invalid verbs {bad!r}', name2regex(bad), '')
    check('plain regex detected', name_is_plain_regex('AO2D_[0-9]+'), True)
    check('verbs not plain regex', name_is_plain_regex('begin_AO2D'), False)
    check('plain regex pre-selection', bool(re.match(name2regex('AO2D_[0-9]+'), '/d/AO2D_123.root')), True)
    check('invalid plain regex', name2regex('a('), '')
    check('valid_regex invalid', valid_regex('a('), None)
    check('valid_regex valid', bool(valid_regex('^a.*b$')), True)


def t_format_dst_fn() -> None:
    """Destination name of a copy, -parent N and -rmprefix N (same cases as test 006 for the reference data)"""
    ref = '/alice/cern.ch/user/a/admin/referenceData/'
    cases = (((f'{ref}referenceData.xml', f'{ref}referenceData.xml', 'ci/', 0, 0), 'ci/referenceData.xml'),
             ((f'{ref}referenceData.xml', f'{ref}referenceData.xml', 'ci/', 2, 0), 'ci/admin/referenceData/referenceData.xml'),
             ((f'{ref}referenceData.xml', f'{ref}referenceData.xml', 'ci/', 0, 4), 'ci/admin/referenceData/referenceData.xml'),
             ((f'{ref}001/', f'{ref}001/stdout.log', 'ci/', 0, 0), 'ci/stdout.log'),
             ((f'{ref}001/', f'{ref}001/stdout.log', 'ci/', 2, 0), 'ci/referenceData/001/stdout.log'),
             ((f'{ref}001/', f'{ref}001/stdout.log', 'ci/', 0, 5), 'ci/referenceData/001/stdout.log'),
             ((f'{ref}001/', f'{ref}001/sub/x.log', 'ci/', 0, 0), 'ci/sub/x.log'),
             (('/home/u/data/', '/home/u/data/a/b.txt', '/alice/u/dst/', 0, 0), '/alice/u/dst/a/b.txt'),
             (('/home/u/data/', '/home/u/data/a/b.txt', '/alice/u/dst/', 1, 0), '/alice/u/dst/data/a/b.txt'),
             (('/home/u/f.txt', '/home/u/f.txt', '/alice/u/dst/', 0, 0), '/alice/u/dst/f.txt'),
             (('/home/u/f.txt', '/home/u/f.txt', '/alice/u/dst/newname.txt', 0, 0), '/alice/u/dst/newname.txt'))
    for args, expected in cases: check(f'format_dst_fn{args}', format_dst_fn(*args), expected)


def mk_tree() -> str:
    """Local tree: d/a.log(10 B) d/b.txt(100 B) d/sub/c.log(1000 B) d/sub/deep/d.log(5 B) d/link.log -> sub/c.log"""
    tree = os.path.join(WORK_DIR, 'tree')
    os.makedirs(os.path.join(tree, 'sub', 'deep'))
    for rel, size in (('a.log', 10), ('b.txt', 100), ('sub/c.log', 1000), ('sub/deep/d.log', 5)):
        with open(os.path.join(tree, rel), 'wb') as f: f.write(b'x' * size)
    os.symlink('sub/c.log', os.path.join(tree, 'link.log'))
    return os.path.realpath(tree)


def t_list_files_local() -> None:
    """Local file listing used by upload: globbing, regex, filters"""
    tree = mk_tree()

    def names(ret) -> list:
        return sorted(os.path.relpath(f, tree) for f in ret.out.splitlines()) if ret.exitcode == 0 else [ret.exitcode]

    all_files = ['a.log', 'b.txt', 'link.log', 'sub/c.log', 'sub/deep/d.log']
    check('list all', names(list_files_local(f'{tree}/')), all_files)
    check('list glob in path', names(list_files_local(f'{tree}/*.log')), ['a.log', 'link.log', 'sub/c.log', 'sub/deep/d.log'])
    check('list glob arg', names(list_files_local(f'{tree}/', '*.txt')), ['b.txt'])
    check('list regex', names(list_files_local(f'{tree}/', r'.*/sub/.*\.log$', is_regex = True)), ['sub/c.log', 'sub/deep/d.log'])
    check('list single file', names(list_files_local(f'{tree}/a.log')), ['a.log'])
    check('list missing dir', list_files_local(f'{tree}/missing/').exitcode, 2)
    check('list no match', list_files_local(f'{tree}/', '*.root').exitcode, 2)
    check('list invalid regex', list_files_local(f'{tree}/', 'a(', is_regex = True).exitcode, -1)
    check('list -exclude', names(list_files_local(f'{tree}/', '*.log', find_args = '-exclude sub')), ['a.log', 'link.log'])
    check('list -exclude_re', names(list_files_local(f'{tree}/', '*.log', find_args = '-exclude_re ^sub/deep/')), ['a.log', 'link.log', 'sub/c.log'])
    check('list -exclude_re invalid', list_files_local(f'{tree}/', '*.log', find_args = '-exclude_re a(').exitcode, 22)
    check('list -minsize', names(list_files_local(f'{tree}/', find_args = '-minsize 100')), ['b.txt', 'link.log', 'sub/c.log'])
    check('list -maxsize', names(list_files_local(f'{tree}/', find_args = '-maxsize 10')), ['a.log', 'sub/deep/d.log'])
    check('list -mindepth 1', names(list_files_local(f'{tree}/', find_args = '-mindepth 1')), ['sub/c.log', 'sub/deep/d.log'])
    check('list -maxdepth 0', names(list_files_local(f'{tree}/', find_args = '-maxdepth 0')), ['a.log', 'b.txt', 'link.log'])
    check('list -name_re', names(list_files_local(f'{tree}/', find_args = r'-name_re ^[ac]\.log$')), ['a.log', 'sub/c.log'])
    ret = list_files_local(f'{tree}/', '*.txt')
    check('list ansdict size', ret.ansdict['results'][0]['size'], '100')


def t_filter_file_prop() -> None:
    """Filters applied on a file description (the same function filters the grid find results)"""
    f_obj = {'lfn': '/base/x/y/file.root', 'size': '500', 'owner': 'u1', 'gowner': 'g1', 'jobid': 12, 'ctime': '1700000000000'}
    check('filter no opts', filter_file_prop(f_obj, '/base', ''), True)
    check('filter -user ok', filter_file_prop(f_obj, '/base', '-user u1'), True)
    check('filter -user no', filter_file_prop(f_obj, '/base', '-user u2'), False)
    check('filter -group no', filter_file_prop(f_obj, '/base', '-group g2'), False)
    check('filter -jobid number', filter_file_prop(f_obj, '/base', '-jobid 12'), True)
    check('filter -jobid no', filter_file_prop(f_obj, '/base', '-jobid 13'), False)
    check('filter -minsize equal', filter_file_prop(f_obj, '/base', '-minsize 500'), True)
    check('filter -maxsize below', filter_file_prop(f_obj, '/base', '-maxsize 499'), False)
    check('filter -min-ctime', filter_file_prop(f_obj, '/base', '-min-ctime 1600000000'), True)
    check('filter -max-ctime', filter_file_prop(f_obj, '/base', '-max-ctime 1600000000'), False)
    check('filter -mindepth 2', filter_file_prop(f_obj, '/base', '-mindepth 2'), True)
    check('filter -maxdepth 1', filter_file_prop(f_obj, '/base', '-maxdepth 1'), False)
    check('filter -exclude relative', filter_file_prop(f_obj, '/base', '-exclude base'), True)
    check('filter -exclude', filter_file_prop(f_obj, '/base', '-exclude x/y'), False)
    check('filter -exclude_re', filter_file_prop(f_obj, '/base', '', [re.compile(r'\.root$')]), False)
    f_rep = {'lfn': '/a/x/a/y.root', 'size': '1', 'owner': 'u', 'gowner': 'g'}  # the base dir appears again inside the path
    check('filter base repeated -maxdepth', filter_file_prop(f_rep, '/a', '-maxdepth 1'), False)
    check('filter base repeated -exclude', filter_file_prop(f_rep, '/a', '-exclude x/a'), False)


def t_time() -> None:
    """Time arguments of -min-ctime/-max-ctime: unix time in s (10 digits) or ms (13 digits)"""
    check('time 10 digits', time_str2unixmili('1672531200'), 1672531200000)
    check('time 13 digits', time_str2unixmili('1672531200000'), 1672531200000)
    check('time strptime form', time_str2unixmili("'01.01.2023 00:00:00','%d.%m.%Y %H:%M:%S'"), 1672531200000)
    check('time invalid', time_str2unixmili('x'), -1)
    now_ms = int(time.time() * 1000)
    check('time empty is now', abs(time_str2unixmili('') - now_ms) < 5000, True)


def t_integrity() -> None:
    """md5 and the validation of an existing download target (cp skip/re-download decision)"""
    fn = os.path.join(WORK_DIR, 'valid.bin')
    content = os.urandom(3 * 1024 * 1024 + 7)
    good_md5 = hashlib.md5(content).hexdigest()  # noqa: S324

    def mk() -> None:
        with open(fn, 'wb') as f: f.write(content)
        os.utime(fn, (time.time(), time.time()))

    mk()
    check('md5 vs hashlib', md5(fn), good_md5)
    old_ms = int((time.time() - 3600) * 1000)
    new_ms = int((time.time() + 3600) * 1000)
    check('valid md5', fileIsValid(fn, len(content), old_ms, good_md5).exitcode, 0)
    check('valid md5 kept', os.path.isfile(fn), True)
    check('invalid md5', fileIsValid(fn, len(content), old_ms, '0' * 32).exitcode, 9)
    check('invalid md5 removed', os.path.isfile(fn), False)
    mk()
    check('invalid size', fileIsValid(fn, len(content) + 1, old_ms, good_md5).exitcode, 9)
    check('invalid size removed', os.path.isfile(fn), False)
    mk()
    check('source newer', fileIsValid(fn, len(content), new_ms, good_md5).exitcode, 9)
    check('source newer removed', os.path.isfile(fn), False)
    mk()
    check('shallow ignores md5', fileIsValid(fn, len(content), old_ms, '0' * 32, shallow_check = True).exitcode, 0)
    os.remove(fn)
    check('missing target', fileIsValid(fn, len(content), old_ms, good_md5).exitcode, 2)


def t_metafile() -> None:
    """meta4 file used as xrootd virtual redirector for downloads"""
    meta = os.path.join(WORK_DIR, 'test.meta4')
    lfn = '/alice/data/a&b<c>.root'
    replicas = ['root://se1.example//x?authz=a&b', 'root://se2.example//x']
    check('metafile created', create_metafile(meta, lfn, '/tmp/a&b"c.root', 1234, 'd41d8cd98f00b204e9800998ecf8427e', replicas), meta)
    check('metafile lfn', get_lfn_meta(meta), lfn)
    check('metafile size', get_size_meta(meta), '1234')
    check('metafile hash', get_hash_meta(meta), ('md5', 'd41d8cd98f00b204e9800998ecf8427e'))
    check('metafile no md5', create_metafile(meta, lfn, '/tmp/x', 1, '', replicas) and get_hash_meta(meta), ('', ''))
    check('metafile no replicas', create_metafile(meta, lfn, '/tmp/x', 1, '', []), '')
    check('metafile missing file', get_size_meta(os.path.join(WORK_DIR, 'missing.meta4')), 0)


def t_tmp_names() -> None:
    """Temporary names of downloaded lfns (edit/cat) map back to the lfn"""
    lfn = '/alice/cern.ch/user/t/tester/dir with space/f.txt'
    tmp = make_tmp_fn(lfn)
    check('tmp name reversible', get_lfn_name(tmp), lfn)
    check('tmp name no /', '/' in os.path.basename(tmp), False)
    check('tmp uuid5 deterministic', make_tmp_fn(lfn, '.meta4', uuid5 = True), make_tmp_fn(lfn, '.meta4', uuid5 = True))


def t_json_and_answers() -> None:
    """Command serialization and conversion of a server answer to RET"""
    check('CreateJsonCommand list', json.loads(CreateJsonCommand('ls', ['-l', '/a b'])), {'command': 'ls', 'options': ['-l', '/a b']})
    check('CreateJsonCommand str', json.loads(CreateJsonCommand('ls -l /x')), {'command': 'ls', 'options': ['-l', '/x']})
    check('CreateJsonCommand opts', json.loads(CreateJsonCommand('ls', ['-l'], 'nomsg nokeys'))['options'], ['-nokeys', '-nomsg', '-l'])
    saved = {k: AlienSessionInfo.get(k) for k in ('user', 'alienHome', 'currentdir', 'prevdir')}
    AlienSessionInfo.update(user = 'tester', alienHome = '/alice/home/', currentdir = '/alice/home/', prevdir = '')
    answer = {'metadata': {'exitcode': '0', 'error': '', 'user': 'tester', 'currentdir': '/alice/home/sub/'},
              'results': [{'message': 'line1'}, {'lfn': '/x'}, {'message': 'line2'}]}
    ret = retf_result2ret(json.dumps(answer))
    check('retf exitcode', ret.exitcode, 0)
    check('retf out', ret.out, 'line1\nline2')
    check('retf session currentdir', AlienSessionInfo['currentdir'], '/alice/home/sub/')
    check('retf session prevdir', AlienSessionInfo['prevdir'], '/alice/home/')
    ret = retf_result2ret({'metadata': {'exitcode': '2', 'error': 'no such file', 'user': 'tester', 'currentdir': '/alice/home/sub/'}, 'results': []})
    check('retf error', (ret.exitcode, ret.out, ret.err), (2, '', 'no such file'))
    check('retf not json', retf_result2ret('{x').exitcode, 22)
    check('retf not alien format', retf_result2ret({'a': 1}).exitcode, 42)
    check('retf empty', retf_result2ret('').exitcode, 61)
    AlienSessionInfo.update(saved)


def t_stack() -> None:
    """Directory stack helper of popd +N/-N: bash semantics, +N counted from the top (left, index 0), -N from the bottom (right, -0 is the last)"""
    dq = collections.deque(['a', 'b', 'c', 'd'])
    check('deque_pop_pos +1', deque_pop_pos(dq, 1), 'b')
    check('deque_pop_pos order kept', list(dq), ['a', 'c', 'd'])
    check('deque_pop_pos -1', deque_pop_pos(dq, -1), 'c')
    check('deque_pop_pos order kept 2', list(dq), ['a', 'd'])
    check('deque_pop_pos out of range', deque_pop_pos(dq, 5), '')


if __name__ == '__main__':
    try:
        for test in (t_expand_path_grid, t_expand_path_local, t_args, t_name2regex, t_format_dst_fn, t_list_files_local,
                     t_filter_file_prop, t_time, t_integrity, t_metafile, t_tmp_names, t_json_and_answers, t_stack):
            print(f'Trying {test.__doc__.splitlines()[0]} ..', flush = True)
            try:
                test()
            except Exception as e:
                FAILED.append(test.__name__)
                print(f'FAIL {test.__name__} raised {e!r}')
    finally:
        shutil.rmtree(WORK_DIR, ignore_errors = True)
    print(f'{CHECKS} checks, {len(FAILED)} failed')
    sys.exit(min(len(FAILED), 255))
