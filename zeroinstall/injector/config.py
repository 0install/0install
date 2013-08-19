"""
Holds user settings and various helper objects.
@since: 0.53
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import support, _, logger
import os

try:
	import ConfigParser
except ImportError:
	import configparser as ConfigParser

from zeroinstall import zerostore
from zeroinstall.injector.model import network_levels, network_full
from zeroinstall.injector.namespaces import config_site, config_prog
from zeroinstall.support import basedir

DEFAULT_MIRROR = "http://roscidus.com/0mirror"
DEFAULT_KEY_LOOKUP_SERVER = 'https://keylookup.appspot.com'

class Config(object):
	"""
	@ivar auto_approve_keys: whether to approve known keys automatically
	@type auto_approve_keys: bool
	@ivar handler: handler for main-loop integration
	@type handler: L{handler.Handler}
	@ivar key_info_server: the base URL of a key information server
	@type key_info_server: str
	@ivar mirror: the base URL of a mirror site for feeds, keys and implementations (since 1.10)
	@type mirror: str | None
	@ivar freshness: seconds since a feed was last checked before it is considered stale
	@type freshness: int
	"""

	__slots__ = ['help_with_testing', 'freshness', 'network_use', 'mirror', 'key_info_server', 'auto_approve_keys',
		     '_fetcher', '_stores', '_iface_cache', '_handler', '_trust_mgr', '_trust_db', '_app_mgr']

	def __init__(self, handler = None):
		"""@type handler: L{zeroinstall.injector.handler.Handler} | None"""
		self.help_with_testing = False
		self.freshness = 60 * 60 * 24 * 30
		self.network_use = network_full
		self._handler = handler
		self._app_mgr = self._fetcher = self._stores = self._iface_cache = self._trust_mgr = self._trust_db = None
		self.mirror = DEFAULT_MIRROR
		self.key_info_server = DEFAULT_KEY_LOOKUP_SERVER
		self.auto_approve_keys = True

	feed_mirror = property(lambda self: self.mirror, lambda self, value: setattr(self, 'mirror', value))

	@property
	def stores(self):
		if not self._stores:
			self._stores = zerostore.Stores()
		return self._stores

	@property
	def iface_cache(self):
		if not self._iface_cache:
			from zeroinstall.injector import iface_cache
			self._iface_cache = iface_cache.iface_cache
			#self._iface_cache = iface_cache.IfaceCache()
		return self._iface_cache

	@property
	def fetcher(self):
		if not self._fetcher:
			from zeroinstall.injector import fetch
			self._fetcher = fetch.Fetcher(self)
		return self._fetcher

	@property
	def trust_mgr(self):
		if not self._trust_mgr:
			from zeroinstall.injector import trust
			self._trust_mgr = trust.TrustMgr(self)
		return self._trust_mgr

	@property
	def trust_db(self):
		from zeroinstall.injector import trust
		self._trust_db = trust.trust_db

	@property
	def handler(self):
		if not self._handler:
			from zeroinstall.injector import handler
			if os.isatty(2):
				self._handler = handler.ConsoleHandler()
			else:
				self._handler = handler.Handler()
		return self._handler

	@property
	def app_mgr(self):
		if not self._app_mgr:
			from zeroinstall import apps
			self._app_mgr = apps.AppManager(self)
		return self._app_mgr

	def save_globals(self):
		"""Write global settings."""
		parser = ConfigParser.ConfigParser()
		parser.add_section('global')

		parser.set('global', 'help_with_testing', str(self.help_with_testing))
		parser.set('global', 'network_use', self.network_use)
		parser.set('global', 'freshness', str(self.freshness))
		parser.set('global', 'auto_approve_keys', str(self.auto_approve_keys))

		path = basedir.save_config_path(config_site, config_prog)
		path = os.path.join(path, 'global')
		with open(path + '.new', 'wt') as stream:
			parser.write(stream)
		support.portable_rename(path + '.new', path)

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

	assert config.network_use in network_levels, config.network_use

	return config
