"""
This class brings together a L{solve.Solver} to choose a set of implmentations, a
L{fetch.Fetcher} to download additional components, and the user's configuration
settings.
@since: 0.53
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os
from logging import info, debug

from zeroinstall.injector import arch, model
from zeroinstall.injector.model import network_offline
from zeroinstall.support import tasks

class Driver(object):
	"""Chooses a set of implementations based on a policy.
	Typical use:
	 1. Create a Driver object, giving it the requirements about the program to be run.
	 2. Call L{solve_with_downloads}. If more information is needed, a L{fetch.Fetcher} will be used to download it.
	 3. When all downloads are complete, the L{solver} contains the chosen versions.
	 4. Use L{get_uncached_implementations} to find where to get these versions and download them
	    using L{download_uncached_implementations}.

	@ivar target_arch: target architecture for binaries (deprecated)
	@type target_arch: L{arch.Architecture}
	@ivar solver: solver used to choose a set of implementations
	@type solver: L{solve.Solver}
	@ivar watchers: callbacks to invoke after solving
	"""
	__slots__ = ['watchers', 'requirements', 'config', 'target_arch', 'solver']

	def __init__(self, config, requirements):
		"""
		@param config: The configuration settings to use
		@type config: L{config.Config}
		@param requirements: Details about the program we want to run
		@type requirements: L{requirements.Requirements}
		@since: 0.53
		"""
		self.watchers = []

		assert config
		self.config = config

		assert requirements
		self.requirements = requirements

		self.target_arch = arch.get_architecture(requirements.os, requirements.cpu)

		from zeroinstall.injector.solver import DefaultSolver
		self.solver = DefaultSolver(self.config)

		debug(_("Supported systems: '%s'"), arch.os_ranks)
		debug(_("Supported processors: '%s'"), arch.machine_ranks)

		if requirements.before or requirements.not_before:
			self.solver.extra_restrictions[config.iface_cache.get_interface(requirements.interface_uri)] = [
					model.VersionRangeRestriction(model.parse_version(requirements.before),
								      model.parse_version(requirements.not_before))]

	def get_uncached_implementations(self):
		"""List all chosen implementations which aren't yet available locally.
		@rtype: [(L{model.Interface}, L{model.Implementation})]"""
		iface_cache = self.config.iface_cache
		stores = self.config.stores
		uncached = []
		for uri, selection in self.solver.selections.selections.iteritems():
			impl = selection.impl
			assert impl, self.solver.selections
			if not impl.is_available(stores):
				uncached.append((iface_cache.get_interface(uri), impl))
		return uncached

	@tasks.async
	def solve_with_downloads(self, force = False, update_local = False):
		"""Run the solver, then download any feeds that are missing or
		that need to be updated. Each time a new feed is imported into
		the cache, the solver is run again, possibly adding new downloads.
		@param force: whether to download even if we're already ready to run.
		@param update_local: fetch PackageKit feeds even if we're ready to run."""

		downloads_finished = set()		# Successful or otherwise
		downloads_in_progress = {}		# URL -> Download

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
			self.solver.solve_for(self.requirements)
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
						downloads_in_progress[f] = self.config.fetcher.download_and_import_feed(f, self.config.iface_cache)
				elif force and self.config.network_use != network_offline:
					downloads_in_progress[f] = self.config.fetcher.download_and_import_feed(f, self.config.iface_cache)
					# Once we've starting downloading some things,
					# we might as well get them all.
					force = True

			if not downloads_in_progress:
				if self.config.network_use == network_offline:
					info(_("Can't choose versions and in off-line mode, so aborting"))
				break

			# Wait for at least one download to finish
			blockers = downloads_in_progress.values()
			yield blockers
			tasks.check(blockers, self.config.handler.report_error)

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
		self.solver.solve_for(self.requirements)
		for w in self.watchers: w()

		if not self.solver.ready:
			return True		# Maybe a newer version will work?

		if self.get_uncached_implementations():
			return True

		return False

	def download_uncached_implementations(self):
		"""Download all implementations chosen by the solver that are missing from the cache."""
		assert self.solver.ready, "Solver is not ready!\n%s" % self.solver.selections
		stores = self.config.stores
		return self.config.fetcher.download_impls([impl for impl in self.solver.selections.values() if not impl.is_available(stores)],
						   stores)
