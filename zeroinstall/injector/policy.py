"""
This class brings together a L{solve.Solver} to choose a set of implmentations, a
L{fetch.Fetcher} to download additional components, and the user's configuration
settings.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os
from logging import info, debug, warn

from zeroinstall import SafeException
from zeroinstall.injector import arch, model
from zeroinstall.injector.model import Interface, Implementation, network_levels, network_offline, network_full
from zeroinstall.injector.namespaces import config_site, config_prog
from zeroinstall.injector.config import load_config
from zeroinstall.support import tasks

# If we started a check within this period, don't start another one:
FAILED_CHECK_DELAY = 60 * 60	# 1 Hour

class Policy(object):
	"""Chooses a set of implementations based on a policy.
	Typical use:
	 1. Create a Policy object, giving it the URI of the program to be run and a handler.
	 2. Call L{solve_with_downloads}. If more information is needed, a L{fetch.Fetcher} will be used to download it.
	 3. When all downloads are complete, the L{solver} contains the chosen versions.
	 4. Use L{get_uncached_implementations} to find where to get these versions and download them
	    using L{download_uncached_implementations}.

	@ivar target_arch: target architecture for binaries
	@type target_arch: L{arch.Architecture}
	@ivar root: URI of the root interface
	@ivar solver: solver used to choose a set of implementations
	@type solver: L{solve.Solver}
	@ivar watchers: callbacks to invoke after recalculating
	@ivar help_with_testing: default stability policy
	@type help_with_testing: bool
	@ivar network_use: one of the model.network_* values
	@ivar freshness: seconds allowed since last update
	@type freshness: int
	@ivar stale_feeds: set of feeds which are present but haven't been checked for a long time
	@type stale_feeds: set
	"""
	__slots__ = ['root', 'watchers', 'requirements', 'config', '_warned_offline',
		     'command', 'target_arch',
		     'stale_feeds', 'solver']

	help_with_testing = property(lambda self: self.config.help_with_testing,
				     lambda self, value: setattr(self.config, 'help_with_testing', bool(value)))

	network_use = property(lambda self: self.config.network_use,
			       lambda self, value: setattr(self.config, 'network_use', value))

	freshness = property(lambda self: self.config.freshness,
			     lambda self, value: setattr(self.config, 'freshness', str(value)))

	implementation = property(lambda self: self.solver.selections)

	ready = property(lambda self: self.solver.ready)

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
		self.watchers = []
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
			self.target_arch = arch.get_host_architecture()
		else:
			assert root == src == None
			assert command == -1
			self.target_arch = arch.get_architecture(requirements.os, requirements.cpu)
		self.requirements = requirements

		self.stale_feeds = set()

		if config is None:
			self.config = load_config(handler)
		else:
			assert handler is None, "can't pass a handler and a config"
			self.config = config

		from zeroinstall.injector.solver import DefaultSolver
		self.solver = DefaultSolver(self.config)

		# If we need to download something but can't because we are offline,
		# warn the user. But only the first time.
		self._warned_offline = False

		debug(_("Supported systems: '%s'"), arch.os_ranks)
		debug(_("Supported processors: '%s'"), arch.machine_ranks)

		if requirements.before or requirements.not_before:
			self.solver.extra_restrictions[config.iface_cache.get_interface(requirements.interface_uri)] = [
					model.VersionRangeRestriction(model.parse_version(requirements.before),
								      model.parse_version(requirements.not_before))]

	@property
	def fetcher(self):
		return self.config.fetcher

	def save_config(self):
		self.config.save_globals()

	def recalculate(self, fetch_stale_interfaces = True):
		"""@deprecated: see L{solve_with_downloads} """
		import warnings
		warnings.warn("Policy.recalculate is deprecated!", DeprecationWarning, stacklevel = 2)

		self.stale_feeds = set()

		host_arch = self.target_arch
		if self.requirements.source:
			host_arch = arch.SourceArchitecture(host_arch)
		self.solver.solve(self.root, host_arch, command_name = self.command)

		if self.network_use == network_offline:
			fetch_stale_interfaces = False

		blockers = []
		for f in self.solver.feeds_used:
			if os.path.isabs(f): continue
			feed = self.config.iface_cache.get_feed(f)
			if feed is None or feed.last_modified is None:
				self.download_and_import_feed_if_online(f)	# Will start a download
			elif self.is_stale(feed):
				debug(_("Adding %s to stale set"), f)
				self.stale_feeds.add(self.config.iface_cache.get_interface(f))	# Legacy API
				if fetch_stale_interfaces:
					self.download_and_import_feed_if_online(f)	# Will start a download

		for w in self.watchers: w()

		return blockers

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

	def download_and_import_feed_if_online(self, feed_url):
		"""If we're online, call L{fetch.Fetcher.download_and_import_feed}. Otherwise, log a suitable warning."""
		if self.network_use != network_offline:
			debug(_("Feed %s not cached and not off-line. Downloading..."), feed_url)
			return self.fetcher.download_and_import_feed(feed_url, self.config.iface_cache)
		else:
			if self._warned_offline:
				debug(_("Not downloading feed '%s' because we are off-line."), feed_url)
			else:
				warn(_("Not downloading feed '%s' because we are in off-line mode."), feed_url)
				self._warned_offline = True

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
		"""List all chosen implementations which aren't yet available locally.
		@rtype: [(L{model.Interface}, L{model.Implementation})]"""
		iface_cache = self.config.iface_cache
		uncached = []
		for uri, selection in self.solver.selections.selections.iteritems():
			impl = selection.impl
			assert impl, self.solver.selections
			if not self.get_cached(impl):
				uncached.append((iface_cache.get_interface(uri), impl))
		return uncached

	def refresh_all(self, force = True):
		"""Start downloading all feeds for all selected interfaces.
		@param force: Whether to restart existing downloads."""
		return self.solve_with_downloads(force = True)

	def get_feed_targets(self, feed):
		"""@deprecated: use IfaceCache.get_feed_targets"""
		return self.config.iface_cache.get_feed_targets(feed)

	@tasks.async
	def solve_with_downloads(self, force = False, update_local = False):
		"""Run the solver, then download any feeds that are missing or
		that need to be updated. Each time a new feed is imported into
		the cache, the solver is run again, possibly adding new downloads.
		@param force: whether to download even if we're already ready to run.
		@param update_local: fetch PackageKit feeds even if we're ready to run."""

		downloads_finished = set()		# Successful or otherwise
		downloads_in_progress = {}		# URL -> Download

		host_arch = self.target_arch
		if self.requirements.source:
			host_arch = arch.SourceArchitecture(host_arch)

		# There are three cases:
		# 1. We want to run immediately if possible. If not, download all the information we can.
		#    (force = False, update_local = False)
		# 2. We're in no hurry, but don't want to use the network unnecessarily.
		#    We should still update local information (from PackageKit).
		#    (force = False, update_local = True)
		# 3. The user explicitly asked us to refresh everything.
		#    (force = True)

		try_quick_exit = not (force or update_local)

		while True:
			self.solver.solve(self.root, host_arch, command_name = self.command)
			for w in self.watchers: w()

			if try_quick_exit and self.solver.ready:
				break
			try_quick_exit = False

			if not self.solver.ready:
				force = True

			for f in self.solver.feeds_used:
				if f in downloads_finished or f in downloads_in_progress:
					continue
				if os.path.isabs(f):
					if force:
						self.config.iface_cache.get_feed(f, force = True)
						downloads_in_progress[f] = tasks.IdleBlocker('Refresh local feed')
					continue
				elif f.startswith('distribution:'):
					if force or update_local:
						downloads_in_progress[f] = self.fetcher.download_and_import_feed(f, self.config.iface_cache)
				elif force and self.network_use != network_offline:
					downloads_in_progress[f] = self.fetcher.download_and_import_feed(f, self.config.iface_cache)
					# Once we've starting downloading some things,
					# we might as well get them all.
					force = True

			if not downloads_in_progress:
				if self.network_use == network_offline:
					info(_("Can't choose versions and in off-line mode, so aborting"))
				break

			# Wait for at least one download to finish
			blockers = downloads_in_progress.values()
			yield blockers
			tasks.check(blockers, self.handler.report_error)

			for f in downloads_in_progress.keys():
				if f in downloads_in_progress and downloads_in_progress[f].happened:
					del downloads_in_progress[f]
					downloads_finished.add(f)

					# Need to refetch any "distribution" feed that
					# depends on this one
					distro_feed_url = 'distribution:' + f
					if distro_feed_url in downloads_finished:
						downloads_finished.remove(distro_feed_url)
					if distro_feed_url in downloads_in_progress:
						del downloads_in_progress[distro_feed_url]

	@tasks.async
	def solve_and_download_impls(self, refresh = False, select_only = False):
		"""Run L{solve_with_downloads} and then get the selected implementations too.
		@raise SafeException: if we couldn't select a set of implementations
		@since: 0.40"""
		refreshed = self.solve_with_downloads(refresh)
		if refreshed:
			yield refreshed
			tasks.check(refreshed)

		if not self.solver.ready:
			raise self.solver.get_failure_reason()

		if not select_only:
			downloaded = self.download_uncached_implementations()
			if downloaded:
				yield downloaded
				tasks.check(downloaded)

	def need_download(self):
		"""Decide whether we need to download anything (but don't do it!)
		@return: true if we MUST download something (feeds or implementations)
		@rtype: bool"""
		host_arch = self.target_arch
		if self.requirements.source:
			host_arch = arch.SourceArchitecture(host_arch)
		self.solver.solve(self.root, host_arch, command_name = self.command)
		for w in self.watchers: w()

		if not self.solver.ready:
			return True		# Maybe a newer version will work?

		if self.get_uncached_implementations():
			return True

		return False

	def download_uncached_implementations(self):
		"""Download all implementations chosen by the solver that are missing from the cache."""
		assert self.solver.ready, "Solver is not ready!\n%s" % self.solver.selections
		return self.fetcher.download_impls([impl for impl in self.solver.selections.values() if not self.get_cached(impl)],
						   self.config.stores)

	def download_icon(self, interface, force = False):
		"""Download an icon for this interface and add it to the
		icon cache. If the interface has no icon or we are offline, do nothing.
		@return: the task doing the import, or None
		@rtype: L{tasks.Task}"""
		if self.network_use == network_offline:
			info("Not downloading icon for %s as we are off-line", interface)
			return

		modification_time = None

		existing_icon = self.config.iface_cache.get_icon_path(interface)
		if existing_icon:
			file_mtime = os.stat(existing_icon).st_mtime
			from email.utils import formatdate
			modification_time = formatdate(timeval = file_mtime, localtime = False, usegmt = True)

		return self.fetcher.download_icon(interface, force, modification_time)

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
