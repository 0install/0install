import basedir

from namespaces import config_prog

def escape(uri):
	"Convert each space to %20, etc"
	import re
	return re.sub('[^-_./a-zA-Z0-9]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8')[0])

def save_user_overrides(interface):
	path = basedir.save_config_path(config_site, config_path, 'user_overrides')
	path = os.path.join(path, escape(interface.uri))
	print "Save to", path
