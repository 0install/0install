"""
Holds user settings and various helper objects.
@since: 0.53
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger

try:
	import ConfigParser
except ImportError:
	import configparser as ConfigParser

from zeroinstall.injector.model import network_levels, network_full
from zeroinstall.injector.namespaces import config_site, config_prog
from zeroinstall.support import basedir

DEFAULT_MIRROR = "http://roscidus.com/0mirror"
DEFAULT_KEY_LOOKUP_SERVER = 'https://keylookup.appspot.com'

class Config(object):
	"""
	@ivar auto_approve_keys: whether to approve known keys automatically
	@type auto_approve_keys: bool
	@ivar key_info_server: the base URL of a key information server
	@type key_info_server: str
	@ivar mirror: the base URL of a mirror site for feeds, keys and implementations (since 1.10)
	@type mirror: str | None
	@ivar freshness: seconds since a feed was last checked before it is considered stale
	@type freshness: int
	"""

	__slots__ = ['help_with_testing', 'freshness', 'network_use', 'mirror', 'key_info_server', 'auto_approve_keys',
		     '_iface_cache']

	def __init__(self, handler = None):
		"""@type handler: L{zeroinstall.injector.handler.Handler} | None"""
		self.help_with_testing = False
		self.freshness = 60 * 60 * 24 * 30
		self.network_use = network_full
		self._iface_cache = None
		self.mirror = DEFAULT_MIRROR
		self.key_info_server = DEFAULT_KEY_LOOKUP_SERVER
		self.auto_approve_keys = True

	feed_mirror = property(lambda self: self.mirror, lambda self, value: setattr(self, 'mirror', value))

	@property
	def iface_cache(self):
		if not self._iface_cache:
			from zeroinstall.injector import iface_cache
			self._iface_cache = iface_cache.iface_cache
			#self._iface_cache = iface_cache.IfaceCache()
		return self._iface_cache

def load_config(handler = None):
	"""@type handler: L{zeroinstall.injector.handler.Handler} | None
	@rtype: L{Config}"""
	config = Config(handler)
	parser = ConfigParser.RawConfigParser()
	parser.add_section('global')
	parser.set('global', 'help_with_testing', 'False')
	parser.set('global', 'freshness', str(60 * 60 * 24 * 30))	# One month
	parser.set('global', 'network_use', 'full')
	parser.set('global', 'auto_approve_keys', 'True')
	parser.set('global', 'key_info_server', DEFAULT_KEY_LOOKUP_SERVER)

	path = basedir.load_first_config(config_site, config_prog, 'global')
	if path:
		logger.info("Loading configuration from %s", path)
		try:
			parser.read(path)
		except Exception as ex:
			logger.warning(_("Error loading config: %s"), str(ex) or repr(ex))

	config.help_with_testing = parser.getboolean('global', 'help_with_testing')
	config.network_use = parser.get('global', 'network_use')
	config.freshness = int(parser.get('global', 'freshness'))
	config.auto_approve_keys = parser.getboolean('global', 'auto_approve_keys')
	config.key_info_server = parser.get('global', 'key_info_server')

	assert config.network_use in network_levels, config.network_use

	return config
