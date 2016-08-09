#+
# Copyright 2015 iXsystems, Inc.
# All rights reserved
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted providing that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
#####################################################################

import copy
import re
import collections
import dateutil.parser
from six import string_types


operators_table = {
    '=': lambda x, y: x == y,
    '!=': lambda x, y: x != y,
    '>': lambda x, y: x > y,
    '<': lambda x, y: x < y,
    '>=': lambda x, y: x >= y,
    '<=': lambda x, y: x <= y,
    '~': lambda x, y: re.search(str(y), str(x)),
    'in': lambda x, y: x in y,
    'nin': lambda x, y: x not in y
}


conversions_table = {
    'timestamp': lambda v: dateutil.parser.parse(v)
}


def eval_logic_and(item, lst):
    for i in lst:
        if not eval_tuple(item, i):
            return False

    return True


def eval_logic_or(item, lst):
    for i in lst:
        if eval_tuple(item, i):
            return True

    return False


def eval_logic_nor(item, lst):
    for i in lst:
        if eval_tuple(item, i):
            return False

    return True


def eval_logic_operator(item, t):
    op, lst = t
    return globals()['eval_logic_{0}'.format(op)](item, lst)


def eval_field_operator(item, t):
    left, op, right = t

    if len(t) == 4:
        right = conversions_table[t[3]](right)

    return operators_table[op](item.get(left), right)


def eval_tuple(item, t):
    if len(t) == 2:
        return eval_logic_operator(item, t)

    if len(t) in (3, 4):
        return eval_field_operator(item, t)


def matches(obj, *rules):
    fail = False
    for r in rules:
        if not eval_tuple(obj, r):
            fail = True
            break

    return not fail


def filter_and_map(fn, items):
    for i in items:
        result = fn(i)
        if result is None:
            continue

        yield result


def partition(s):
    pos = s.find('.')
    if pos == -1:
        return s, None

    if s[pos - 1] == '\\':
        right = None
        left, middle = s.split('.', 1)
        left = left.replace('\\', '.')
        if middle.find('.') != -1:
            middle, right = middle.split('.', 1)
        return left + middle, right
    else:
        return s.split('.', 1)


def wrap(obj):
    if type(obj) in (QueryDict, QueryList, QueryIterator):
        return obj

    if hasattr(obj, '__getstate__'):
        obj = obj.__getstate__()

    if hasattr(obj, '__next__'):
        obj = QueryIterator(obj)

    if isinstance(obj, dict):
        return QueryDict(obj)

    if isinstance(obj, (list, tuple)):
        return QueryList(obj)

    return obj


class QueryMixin(object):
    def query(self, *rules, **params):
        single = params.pop('single', False)
        count = params.pop('count', None)
        offset = params.pop('offset', None)
        limit = params.pop('limit', None)
        sort = params.pop('sort', None)
        postprocess = params.pop('callback', None)
        select = params.pop('select', None)
        stream = params.pop('stream', False)
        result = iter(self)

        def search(data):
            for i in data:
                if matches(i, *rules):
                    yield i

        if rules:
            result = search(result)

        if select:
            def select_fn(fn, obj):
                obj = fn(obj) if fn else obj
                obj = wrap(obj)

                if isinstance(select, (list, tuple)):
                    return [obj.get(i) for i in select]

                if isinstance(select, str):
                    return obj.get(select)

            old = postprocess
            postprocess = lambda o: select_fn(old, o)

        if sort:
            def sort_transform(result, key):
                reverse = False
                if key.startswith('-'):
                    key = key[1:]
                    reverse=True
                result.append((key, reverse))

            _sort = []
            if isinstance(sort, string_types):
                sort_transform(_sort, sort)
            elif isinstance(sort, (tuple, list)):
                for s in sort:
                    sort_transform(_sort, s)
            if _sort:
                for key, reverse in reversed(_sort):
                    result = sorted(result, key=lambda x: x[key], reverse=reverse)

        if offset:
            result = iter(list(result)[offset:])

        if limit:
            result = iter(list(result)[:limit])

        if postprocess:
            result = filter_and_map(postprocess, result)

        if single:
            return next(result, None)

        if count:
            return len(list(result))

        return result if stream else list(result)


class QueryList(QueryMixin, list):
    def __init__(self, *args, **kwargs):
        super(QueryList, self).__init__(*args, **kwargs)
        for idx, v in enumerate(self):
            self[idx] = wrap(v)

    def __getitem__(self, item):
        if isinstance(item, string_types):
            if item.isdigit():
                return super(QueryList, self).__getitem__(int(item))

            left, right = partition(item)
            return super(QueryList, self).__getitem__(int(left))[right]

        return super(QueryList, self).__getitem__(item)

    def contains_path(self, item):
        if item.isdigit():
            return int(item) < len(self)

        left, right = partition(item)

        try:
            tmp = self[left]
        except IndexError:
            return False

        return tmp.contains_path(right)

    def __setitem__(self, key, value):
        value = wrap(value)

        if isinstance(key, string_types):
            if key.isdigit():
                index = int(key)
                if index >= len(self):
                    self.extend([None] * (index - len(self) + 1))

                super(QueryList, self).__setitem__(index, value)
                return

            left, right = partition(key)
            self[left][right] = value

        super(QueryList, self).__setitem__(key, value)

    def get(self, key, d=None):
        if isinstance(key, string_types):
            key = int(key)

        return self[key] if len(self) > key else d

    def set(self, key, value):
        value = wrap(value)

        if isinstance(key, string_types):
            if key.isdigit():
                self[key] = value
                return

            left, right = partition(key)

            if left not in self:
                ll, _ = partition(right)
                if ll.isdigit():
                    self[left] = []
                else:
                    self[left] = {}

            self[left].set(right, value)

        super(QueryList, self).__setitem__(key, value)

    def append(self, v):
        super(QueryList, self).append(wrap(v))


class QueryIterator(QueryMixin, object):
    def __init__(self, iterable):
        self.iterable = iterable

    def __iter__(self):
        return self

    def __next__(self):
        return wrap(next(self.iterable))


class QueryDictMixin(object):
    def __init__(self, *args, **kwargs):
        source = args[0] if args else None
        if source:
            for k, v in source.items() if isinstance(source, dict) else source:
                if isinstance(k, string_types):
                    k = k.replace('.', r'\.')

                self[k] = v

        for k, v in kwargs.items():
            if isinstance(k, string_types):
                k = k.replace('.', r'\.')

            self[k] = v

    def __deepcopy__(self, memo):
        result = self.__class__.__new__(self.__class__)
        memo[id(self)] = result
        for k, v in self.items():
            if isinstance(k, string_types):
                k = k.replace('.', r'\.')

            result[k] = copy.deepcopy(v, memo)

        return result

    def __getitem__(self, item):
        if not isinstance(item, string_types):
            return super(QueryDictMixin, self).__getitem__(item)

        if super(QueryDictMixin, self).__contains__(item):
            return super(QueryDictMixin, self).__getitem__(item)

        left, right = partition(item)

        if not right:
            return super(QueryDictMixin, self).__getitem__(left)

        return super(QueryDictMixin, self).__getitem__(left)[right]

    def __setitem__(self, key, value):
        value = wrap(value)

        if not isinstance(key, string_types):
            return super(QueryDictMixin, self).__setitem__(key, value)

        left, right = partition(key)

        if not right:
            return super(QueryDictMixin, self).__setitem__(left, value)

        self[left][right] = value

    def contains_path(self, item):
        return item in self

    def __contains__(self, item):
        if not isinstance(item, string_types):
            return super(QueryDictMixin, self).__contains__(item)

        left, right = partition(item)

        if not right:
            return super(QueryDictMixin, self).__contains__(left)

        try:
            tmp = self[left]
        except KeyError:
            return False

        if not isinstance(tmp, (QueryDict, QueryList)):
            return False

        return tmp.contains_path(right)

    def get(self, k, d=None):
        return self[k] if k in self else d

    def set(self, key, value):
        value = wrap(value)

        if not isinstance(key, string_types):
            return super(QueryDictMixin, self).__setitem__(key, value)

        left, right = partition(key)

        if not right:
            return super(QueryDictMixin, self).__setitem__(left, value)

        if left not in self:
            ll, _ = partition(right)
            if ll.isdigit():
                self[left] = []
            else:
                self[left] = {}

        self[left].set(right, value)

    def query(self, *rules, **params):
        return wrap(list(self.values())).query(*rules, **params)


class QueryDict(QueryDictMixin, dict):
    pass


class OrderedQueryDict(QueryDictMixin, collections.OrderedDict):
    pass
