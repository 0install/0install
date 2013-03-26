"""Functions for escaping and unescaping strings (for URLs, filenames, etc).

The underscore escaping functions are useful when generating directory names
which should be reasonably human-readable, and not contain characters which are
likely to confuse programs (e.g. ":" doesn't work on Windows, "#" confuses
cmake, "=" confuses Java, [:;,] confuse anything that uses these as list item
separators, etc.

See also L{zeroinstall.injector.model.escape} for an older escaping scheme.

@since: 1.13
"""

import re

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

def _under_escape(m):
	"""@rtype: str"""
	c = m.group(0)
	if c == '/':
		return '__'
	else:
		return '_%x_' % ord(c)

def _ununder_escape(m):
	"""@rtype: str"""
	c = m.group(1)
	if c == "":
		return "/"
	else:
		return chr(int(m.group(1), 16))

_troublesome_re = re.compile(r'[]\\[^_`\0-,/:-@{|}~\x7f]')

def underscore_escape(src):
	"""Escape troublesome characters in 'src'.
	The result is a valid file leaf name (i.e. does not contain / etc).
	Letters, digits and characters > 127 are copied unmodified.
	'/' becomes '__'. Other characters become '_code_', where code is the
	lowercase hex value of the character in Unicode.
	@param src: the string to escape
	@type src: str
	@return: the escaped string
	@rtype: str"""
	escaped = re.sub(_troublesome_re, _under_escape, src)

	# Avoid creating hidden files, or specials (. and ..)
	if escaped.startswith("."):
		return "_2e_" + escaped[1:]

	return escaped

_escaped_code_re = re.compile('_([0-9a-fA-F]*)_')

def ununderscore_escape(escaped):
	"""@type escaped: str
	@rtype: str"""
	return _escaped_code_re.sub(_ununder_escape, escaped)
