import basedir

ns = '0install.net'

def escape(uri):
	"Convert each space to %20, etc"
	import re
	return re.sub('[^-_./a-zA-Z0-9]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8')[0])

def save_user_overrides(interface):
	path = basedir.save_config_path(ns, 'injector', 'user_overrides', escape(interface.uri))
	print "Save to", path
