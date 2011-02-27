"""
This class brings together a L{solve.Solver} to choose a set of implmentations, a
L{fetch.Fetcher} to download additional components, and the user's configuration
settings.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os
from logging import info, debug

from zeroinstall import SafeException
from zeroinstall.injector import arch, model, driver
from zeroinstall.injector.model import Interface, Implementation, network_levels, network_offline, network_full
from zeroinstall.injector.namespaces import config_site, config_prog
from zeroinstall.injector.config import load_config
from zeroinstall.support import tasks

class Policy(object):
	"""@deprecated: Use Driver instead."""
	__slots__ = ['driver']

	help_with_testing = property(lambda self: self.config.help_with_testing,
				     lambda self, value: setattr(self.config, 'help_with_testing', bool(value)))

	network_use = property(lambda self: self.config.network_use,
			       lambda self, value: setattr(self.config, 'network_use', value))

	freshness = property(lambda self: self.config.freshness,
			     lambda self, value: setattr(self.config, 'freshness', str(value)))

	target_arch = property(lambda self: self.driver.target_arch,
			     lambda self, value: setattr(self.driver, 'target_arch', value))

	implementation = property(lambda self: self.solver.selections)

	ready = property(lambda self: self.solver.ready)
	config = property(lambda self: self.driver.config)
	requirements = property(lambda self: self.driver.requirements)

	# (was used by 0test)
	handler = property(lambda self: self.config.handler,
			   lambda self, value: setattr(self.config, 'handler', value))


	def __init__(self, root = None, handler = None, src = None, command = -1, config = None, requirements = None):
		"""
		@param requirements: Details about the program we want to run
		@type requirements: L{requirements.Requirements}
		@param config: The configuration settings to use, or None to load from disk.
		@type config: L{config.Config}
		Note: all other arguments are deprecated (since 0launch 0.52)
		"""
		if requirements is None:
			from zeroinstall.injector.requirements import Requirements
			requirements = Requirements(root)
			requirements.source = bool(src)				# Root impl must be a "src" machine type
			if command == -1:
				if src:
					command = 'compile'
				else:
					command = 'run'
			requirements.command = command
		else:
			assert root == src == None
			assert command == -1

		if config is None:
			config = load_config(handler)
		else:
			assert handler is None, "can't pass a handler and a config"

		self.driver = driver.Driver(config = config, requirements = requirements)

	@property
	def fetcher(self):
		return self.config.fetcher

	@property
	def watchers(self):
		return self.driver.watchers

	@property
	def solver(self):
		return self.driver.solver

	def save_config(self):
		self.config.save_globals()

	def usable_feeds(self, iface):
		"""Generator for C{iface.feeds} that are valid for our architecture.
		@rtype: generator
		@see: L{arch}"""
		if self.requirements.source and iface.uri == self.root:
			# Note: when feeds are recursive, we'll need a better test for root here
			machine_ranks = {'src': 1}
		else:
			machine_ranks = arch.machine_ranks

		for f in self.config.iface_cache.get_feed_imports(iface):
			if f.os in arch.os_ranks and f.machine in machine_ranks:
				yield f
			else:
				debug(_("Skipping '%(feed)s'; unsupported architecture %(os)s-%(machine)s"),
					{'feed': f, 'os': f.os, 'machine': f.machine})

	def is_stale(self, feed):
		"""@deprecated: use IfaceCache.is_stale"""
		return self.config.iface_cache.is_stale(feed, self.config.freshness)

	def get_implementation_path(self, impl):
		"""Return the local path of impl.
		@rtype: str
		@raise zeroinstall.zerostore.NotStored: if it needs to be added to the cache first."""
		assert isinstance(impl, Implementation)
		return impl.local_path or self.config.stores.lookup_any(impl.digests)

	def get_implementation(self, interface):
		"""Get the chosen implementation.
		@type interface: Interface
		@rtype: L{model.Implementation}
		@raise SafeException: if interface has not been fetched or no implementation could be
		chosen."""
		assert isinstance(interface, Interface)

		try:
			return self.implementation[interface]
		except KeyError:
			raise SafeException(_("No usable implementation found for '%s'.") % interface.uri)

	def get_cached(self, impl):
		"""Check whether an implementation is available locally.
		@type impl: model.Implementation
		@rtype: bool
		"""
		return impl.is_available(self.config.stores)

	def get_uncached_implementations(self):
		return self.driver.get_uncached_implementations()

	def refresh_all(self, force = True):
		"""Start downloading all feeds for all selected interfaces.
		@param force: Whether to restart existing downloads."""
		return self.solve_with_downloads(force = True)

	def get_feed_targets(self, feed):
		"""@deprecated: use IfaceCache.get_feed_targets"""
		return self.config.iface_cache.get_feed_targets(feed)

	def solve_with_downloads(self, force = False, update_local = False):
		return self.driver.solve_with_downloads(force, update_local)

	def solve_and_download_impls(self, refresh = False, select_only = False):
		return self.driver.solve_and_download_impls(refresh, select_only)

	def need_download(self):
		return self.driver.need_download()

	def download_uncached_implementations(self):
		return self.driver.download_uncached_implementations()

	def download_icon(self, interface, force = False):
		"""Download an icon for this interface and add it to the
		icon cache. If the interface has no icon or we are offline, do nothing.
		@return: the task doing the import, or None
		@rtype: L{tasks.Task}"""
		if self.network_use == network_offline:
			info("Not downloading icon for %s as we are off-line", interface)
			return

		return self.fetcher.download_icon(interface, force)

	def get_interface(self, uri):
		"""@deprecated: use L{iface_cache.IfaceCache.get_interface} instead"""
		import warnings
		warnings.warn("Policy.get_interface is deprecated!", DeprecationWarning, stacklevel = 2)
		return self.config.iface_cache.get_interface(uri)

	@property
	def command(self):
		return self.requirements.command

	@property
	def root(self):
		return self.requirements.interface_uri

_config = None
def get_deprecated_singleton_config():
	global _config
	if _config is None:
		_config = load_config()
	return _config
