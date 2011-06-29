"""
Support code for 0alias scripts.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _

_old_template = '''#!/bin/sh
if [ "$*" = "--versions" ]; then
  exec 0launch -gd '%s' "$@"
else
  exec 0launch %s '%s' "$@"
fi
''' 

_template = '''#!/bin/sh
exec 0launch %s '%s' "$@"
'''

class NotAnAliasScript(Exception):
	pass

def parse_script(pathname):
	"""Extract the URI and main values from a 0alias script.
	@param pathname: the script to be examined
	@return: a tuple containing the URI and the main (or None if not set)
	@rtype: (str, str | None)
	@raise NotAnAliasScript: if we can't parse the script
	"""
	stream = file(pathname)
	template_header = _template[:_template.index("%s '")]
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
			raise NotAnAliasScript(_("'%s' does not look like a script created by 0alias") % pathname)
		rest = stream.read()
		line = rest.split('\n')[2]

	split = line.rfind("' '")
	if split != -1:
		# We have a --main
		uri = line[split + 3:].split("'")[0]
		main = line[:split].split("'", 1)[1].replace("'\\''", "'")
	else:
		main = None
		uri = line.split("'",2)[1]

	return (uri, main)

def write_script(stream, interface_uri, main = None):
	"""Write a shell script to stream that will launch the given program.
	@param stream: the stream to write to
	@param interface_uri: the program to launch
	@param main: the --main argument to pass to 0launch, if any"""
	assert "'" not in interface_uri
	assert "\\" not in interface_uri

	if main is not None:
		main_arg = "--main '%s'" % main.replace("'", "'\\''")
	else:
		main_arg = ""

	stream.write(_template % (main_arg, interface_uri))
