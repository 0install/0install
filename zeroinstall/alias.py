"""
Support code for 0alias scripts.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, SafeException
from zeroinstall import support

_old_template = '''#!/bin/sh
if [ "$*" = "--versions" ]; then
  exec 0launch -gd '%s' "$@"
else
  exec 0launch %s '%s' "$@"
fi
''' 

_template = '''#!/bin/sh
exec 0launch %s'%s' "$@"
'''

class NotAnAliasScript(SafeException):
	pass

class ScriptInfo(object):
	"""@since: 1.3"""
	uri = None
	main = None
	command = 'run'

	# For backwards compatibility
	def __iter__(self):
		return iter([self.uri, self.main])

def parse_script_header(stream):
	"""Parse a 0alias script, if possible.
	This does the same as L{parse_script}, except with an existing stream.
	The stream position at exit is undefined.
	@type stream: file
	@rtype: L{ScriptInfo}
	@since: 1.12"""
	try:
		stream.seek(0)
		template_header = _template[:_template.index("%s'")]
		actual_header = stream.read(len(template_header))
		stream.seek(0)
		if template_header == actual_header:
			# If it's a 0alias script, it should be quite short!
			rest = stream.read()
			line = rest.split('\n')[1]
		else:
			old_template_header = \
			    _old_template[:_old_template.index("-gd '")]
			actual_header = stream.read(len(old_template_header))
			if old_template_header != actual_header:
				return None
			rest = stream.read()
			line = rest.split('\n')[2]
	except UnicodeDecodeError:
		return None

	info = ScriptInfo()
	split = line.rfind("' '")
	if split != -1:
		# We have a --main or --command
		info.uri = line[split + 3:].split("'")[0]
		start, value = line[:split].split("'", 1)
		option = start.split('--', 1)[1].strip()
		value = value.replace("'\\''", "'")
		if option == 'main':
			info.main = value
		elif option == 'command':
			info.command = value or None
		else:
			return None
	else:
		info.uri = line.split("'", 2)[1]

	return info

def parse_script(pathname):
	"""Extract the URI and main values from a 0alias script.
	@param pathname: the script to be examined
	@type pathname: str
	@return: information about the alias script
	@rtype: L{ScriptInfo}
	@raise NotAnAliasScript: if we can't parse the script"""
	with open(pathname, 'rt') as stream:
		info = parse_script_header(stream)
		if info is None:
			raise NotAnAliasScript(_("'%s' does not look like a script created by 0alias") % pathname)
		return info

def write_script(stream, interface_uri, main = None, command = None):
	"""Write a shell script to stream that will launch the given program.
	@param stream: the stream to write to
	@type stream: file
	@param interface_uri: the program to launch
	@type interface_uri: str
	@param main: the --main argument to pass to 0launch, if any
	@type main: str | None
	@param command: the --command argument to pass to 0launch, if any
	@type command: str | None"""
	assert "'" not in interface_uri
	assert "\\" not in interface_uri
	assert main is None or command is None, "Can't set --main and --command together"

	if main is not None:
		option = "--main '%s' " % main.replace("'", "'\\''")
	elif command is not None:
		option = "--command '%s' " % command.replace("'", "'\\''")
	else:
		option = ""

	stream.write(support.unicode(_template) % (option, interface_uri))
