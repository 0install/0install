"""Functions for processing version numbers.
@since: 1.13
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import re

from zeroinstall import SafeException, _

_version_mod_to_value = {
	'pre': -2,
	'rc': -1,
	'': 0,
	'post': 1,
}

# Reverse mapping
_version_value_to_mod = {}
for x in _version_mod_to_value: _version_value_to_mod[_version_mod_to_value[x]] = x
del x

_version_re = re.compile('-([a-z]*)')

def parse_version(version_string):
	"""Convert a version string to an internal representation.
	The parsed format can be compared quickly using the standard Python functions.
	 - Version := DottedList ("-" Mod DottedList?)*
	 - DottedList := (Integer ("." Integer)*)
	@rtype: tuple (opaque)
	@raise SafeException: if the string isn't a valid version
	@since: 0.24 (moved from L{reader}, from where it is still available):"""
	if version_string is None: return None
	parts = _version_re.split(version_string)
	if parts[-1] == '':
		del parts[-1]	# Ends with a modifier
	else:
		parts.append('')
	if not parts:
		raise SafeException(_("Empty version string!"))
	l = len(parts)
	try:
		for x in range(0, l, 2):
			part = parts[x]
			if part:
				parts[x] = list(map(int, parts[x].split('.')))
			else:
				parts[x] = []	# (because ''.split('.') == [''], not [])
		for x in range(1, l, 2):
			parts[x] = _version_mod_to_value[parts[x]]
		return parts
	except ValueError as ex:
		raise SafeException(_("Invalid version format in '%(version_string)s': %(exception)s") % {'version_string': version_string, 'exception': ex})
	except KeyError as ex:
		raise SafeException(_("Invalid version modifier in '%(version_string)s': %(exception)s") % {'version_string': version_string, 'exception': str(ex).strip("u")})

def format_version(version):
	"""Format a parsed version for display. Undoes the effect of L{parse_version}.
	@see: L{model.Implementation.get_version}
	@rtype: str
	@since: 0.24"""
	version = version[:]
	l = len(version)
	for x in range(0, l, 2):
		version[x] = '.'.join(map(str, version[x]))
	for x in range(1, l, 2):
		version[x] = '-' + _version_value_to_mod[version[x]]
	if version[-1] == '-': del version[-1]
	return ''.join(version)


def parse_version_range(r):
	"""Parse a range expression.
	@param r: the range expression
	@type r: str
	@return: a function which returns whether a parsed version is in the range
	@rtype: parsed_version -> bool
	@since: 1.13"""
	parts = r.split('..', 1)
	if len(parts) == 1:
		if r.startswith('!'):
			v = parse_version(r[1:])
			return lambda x: x != v
		else:
			v = parse_version(r)
			return lambda x: x == v

	start, end = parts
	if start:
		start = parse_version(start)
	else:
		start = None
	if end:
		if not end.startswith('!'):
			raise SafeException("End of range must be exclusive (use '..!{end}', not '..{end}')".format(end = end))
		end = parse_version(end[1:])
	else:
		end = None

	def test(v):
		if start is not None and v < start: return False
		if end is not None and v >= end: return False
		return True

	return test

def parse_version_expression(expr):
	"""Parse an expression of the form "RANGE | RANGE | ...".
	@param expr: the expression to parse
	@type expr: str
	@return: a function which tests whether a parsed version is in the range
	@rtype: parsed_version -> bool
	@since: 1.13"""
	tests = [parse_version_range(r.strip()) for r in expr.split('|')]
	return lambda v: any(test(v) for test in tests)
