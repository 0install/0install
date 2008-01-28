"""
Chooses a set of implementations based on a policy.

@deprecated: see L{solver}
"""

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import time
import sys, os, sets
from logging import info, debug, warn
import arch

from model import *
from namespaces import *
import ConfigParser
from zeroinstall import NeedDownload
from zeroinstall.support import tasks, basedir
from zeroinstall.injector.iface_cache import iface_cache, PendingFeed
from zeroinstall.injector.trust import trust_db

# If we started a check within this period, don't start another one:
FAILED_CHECK_DELAY = 60 * 60	# 1 Hour

def _cook(policy, required_digest, recipe, force = False):
	"""A Cook follows a Recipe."""
	# Maybe we're taking this metaphor too far?

	# Start downloading all the ingredients.
	downloads = {}	# Downloads that are not yet successful
	streams = {}	# Streams collected from successful downloads

	# Start a download for each ingredient
	blockers = []
	for step in recipe.steps:
		blocker, stream = policy.download_archive(step, force = force)
		assert stream
		blockers.append(blocker)
		streams[step] = stream

	while blockers:
		yield blockers
		tasks.check(blockers)
		blockers = [b for b in blockers if not b.happened]

	from zeroinstall.zerostore import unpack

	# Create an empty directory for the new implementation
	store = iface_cache.stores.stores[0]
	tmpdir = store.get_tmp_dir_for(required_digest)
	try:
		# Unpack each of the downloaded archives into it in turn
		for step in recipe.steps:
			stream = streams[step]
			stream.seek(0)
			unpack.unpack_archive_over(step.url, stream, tmpdir, step.extract)
		# Check that the result is correct and store it in the cache
		store.check_manifest_and_rename(required_digest, tmpdir)
		tmpdir = None
	finally:
		# If unpacking fails, remove the temporary directory
		if tmpdir is not None:
			from zeroinstall import support
			support.ro_rmtree(tmpdir)

class Policy(object):
	"""Chooses a set of implementations based on a policy.
	Typical use:
	 1. Create a Policy object, giving it the URI of the program to be run and a handler.
	 2. Call L{recalculate}. If more information is needed, the handler will be used to download it.
	 3. When all downloads are complete, the L{implementation} map contains the chosen versions.
	 4. Use L{get_uncached_implementations} to find where to get these versions and download them
	    using L{begin_impl_download}.

	@ivar root: URI of the root interface
	@ivar implementation: chosen implementations
	@type implementation: {model.Interface: model.Implementation or None}
	@ivar watchers: callbacks to invoke after recalculating
	@ivar help_with_testing: default stability policy
	@type help_with_testing: bool
	@ivar network_use: one of the model.network_* values
	@ivar freshness: seconds allowed since last update
	@type freshness: int
	@ivar ready: whether L{implementation} is complete enough to run the program
	@type ready: bool
	@ivar handler: handler for main-loop integration
	@type handler: L{handler.Handler}
	@ivar src: whether we are looking for source code
	@type src: bool
	@ivar stale_feeds: set of feeds which are present but haven't been checked for a long time
	@type stale_feeds: set
	"""
	__slots__ = ['root', 'watchers',
		     'freshness', 'handler', '_warned_offline',
		     'src', 'stale_feeds', 'solver']
	
	help_with_testing = property(lambda self: self.solver.help_with_testing,
				     lambda self, value: setattr(self.solver, 'help_with_testing', value))

	network_use = property(lambda self: self.solver.network_use,
				     lambda self, value: setattr(self.solver, 'network_use', value))

	root_restrictions = property(lambda self: self.solver.root_restrictions,
				     lambda self, value: setattr(self.solver, 'root_restrictions', value))
	
	implementation = property(lambda self: self.solver.selections)

	ready = property(lambda self: self.solver.ready)

	def __init__(self, root, handler = None, src = False):
		"""
		@param root: The URI of the root interface (the program we want to run).
		@param handler: A handler for main-loop integration.
		@type handler: L{zeroinstall.injector.handler.Handler}
		@param src: Whether we are looking for source code.
		@type src: bool
		"""
		self.watchers = []
		self.freshness = 60 * 60 * 24 * 30
		self.src = src				# Root impl must be a "src" machine type
		self.stale_feeds = sets.Set()

		from zeroinstall.injector.solver import DefaultSolver
		self.solver = DefaultSolver(network_full, iface_cache, iface_cache.stores, root_restrictions = [])

		# If we need to download something but can't because we are offline,
		# warn the user. But only the first time.
		self._warned_offline = False

		# (allow self for backwards compat)
		self.handler = handler or self

		debug("Supported systems: '%s'", arch.os_ranks)
		debug("Supported processors: '%s'", arch.machine_ranks)

		path = basedir.load_first_config(config_site, config_prog, 'global')
		if path:
			try:
				config = ConfigParser.ConfigParser()
				config.read(path)
				self.solver.help_with_testing = config.getboolean('global',
								'help_with_testing')
				self.solver.network_use = config.get('global', 'network_use')
				self.freshness = int(config.get('global', 'freshness'))
				assert self.solver.network_use in network_levels
			except Exception, ex:
				warn("Error loading config: %s", ex)

		self.set_root(root)

		# Probably need weakrefs here...
		iface_cache.add_watcher(self)
	
	def set_root(self, root):
		"""Change the root interface URI."""
		assert isinstance(root, (str, unicode))
		self.root = root
		for w in self.watchers: w()

	def save_config(self):
		"""Write global settings."""
		config = ConfigParser.ConfigParser()
		config.add_section('global')

		config.set('global', 'help_with_testing', self.help_with_testing)
		config.set('global', 'network_use', self.network_use)
		config.set('global', 'freshness', self.freshness)

		path = basedir.save_config_path(config_site, config_prog)
		path = os.path.join(path, 'global')
		config.write(file(path + '.new', 'w'))
		os.rename(path + '.new', path)
	
	def recalculate(self, fetch_stale_interfaces = True):
		"""Try to choose a set of implementations.
		This may start downloading more interfaces, but will return immediately.
		@param fetch_stale_interfaces: whether to begin downloading interfaces which are present but haven't
		been checked within the L{freshness} period
		@type fetch_stale_interfaces: bool
		@postcondition: L{ready} indicates whether a possible set of implementations was chosen
		@note: A policy may be ready before all feeds have been downloaded. As new feeds
		arrive, the chosen versions may change.
		@return: a list of tasks which will require a recalculation when complete
		"""

		self.stale_feeds = sets.Set()

		host_arch = arch.get_host_architecture()
		if self.src:
			host_arch = arch.SourceArchitecture(host_arch)
		self.solver.solve(self.root, host_arch)

		for f in self.solver.feeds_used:
			self.get_interface(f)	# May start a download

		tasks = []
		if fetch_stale_interfaces and self.network_use != network_offline:
			for stale in self.stale_feeds:
				info("Checking for updates to stale feed %s", stale)
				tasks.append(self.download_and_import_feed(stale, False))

		for w in self.watchers: w()

		return tasks
	
	def usable_feeds(self, iface):
		"""Generator for C{iface.feeds} that are valid for our architecture.
		@rtype: generator
		@see: L{arch}"""
		if self.src and iface.uri == self.root:
			# Note: when feeds are recursive, we'll need a better test for root here
			machine_ranks = {'src': 1}
		else:
			machine_ranks = arch.machine_ranks
			
		for f in iface.feeds:
			if f.os in arch.os_ranks and f.machine in machine_ranks:
				yield f
			else:
				debug("Skipping '%s'; unsupported architecture %s-%s",
					f, f.os, f.machine)

	def is_stale(self, feed):
		"""Check whether feed needs updating, based on the configured L{freshness}.
		@return: true if feed is stale or missing."""
		if feed.last_modified is None:
			return True		# Don't even have it yet
		now = time.time()
		staleness = now - (feed.last_checked or 0)
		debug("Staleness for %s is %.2f hours", feed, staleness / 3600.0)

		if self.freshness == 0 or staleness < self.freshness:
			return False		# Fresh enough for us

		last_check_attempt = iface_cache.get_last_check_attempt(feed.url)
		if last_check_attempt and last_check_attempt > now - FAILED_CHECK_DELAY:
			debug("Stale, but tried to check recently (%s) so not rechecking now.", time.ctime(last_check_attempt))
			return False

		return True
	
	def get_interface(self, uri):
		"""Get an interface from the L{iface_cache}. If it is missing start a new download.
		If it is present but stale, add it to L{stale_feeds}. This should only be called
		from L{recalculate}.
		@see: iface_cache.iface_cache.get_interface
		@rtype: L{model.Interface}"""
		iface = iface_cache.get_interface(uri)

		if uri in iface_cache.pending:
			# Don't start another download while one is pending
			# TODO: unless the pending version is very old
			return iface

		if not uri.startswith('/'):
			if iface.last_modified is None:
				if self.network_use != network_offline:
					debug("Feed not cached and not off-line. Downloading...")
					self.download_and_import_feed(iface.uri)
				else:
					if self._warned_offline:
						debug("Nothing known about interface, but we are off-line.")
					else:
						if iface.feeds:
							info("Nothing known about interface '%s' and off-line. Trying feeds only.", uri)
						else:
							warn("Nothing known about interface '%s', but we are in off-line mode "
								"(so not fetching).", uri)
							self._warned_offline = True
			elif self.is_stale(iface):
				debug("Adding %s to stale set", iface)
				self.stale_feeds.add(iface)
		#else: debug("Local interface, so not checking staleness.")

		return iface
	
	def download_and_import_feed(self, feed_url, force = False):
		"""Download the feed, download any required keys, confirm trust if needed and import."""
		
		debug("download_and_import_feed %s (force = %d)", feed_url, force)
		assert not feed_url.startswith('/')

		dl = self.handler.get_download(feed_url, force = force)

		def fetch_feed():
			stream = dl.tempfile

			yield dl.downloaded
			tasks.check(dl.downloaded)

			pending = PendingFeed(feed_url, stream)
			iface_cache.add_pending(pending)

			keys_downloaded = tasks.Task(pending.download_keys(self.handler), "download keys for " + feed_url)
			yield keys_downloaded.finished
			tasks.check(keys_downloaded.finished)

			iface = iface_cache.get_interface(pending.url)
			if not iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml):
				blocker = self.handler.confirm_trust_keys(iface, pending.sigs, pending.new_xml)
				if blocker:
					yield blocker
					tasks.check(blocker)
				if not iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml):
					raise SafeException("No signing keys trusted; not importing")

		return tasks.Task(fetch_feed(), "download_and_import_feed " + feed_url).finished
	
	def download_impl(self, impl, retrieval_method, force = False):
		"""Download impl, using retrieval_method. See Task."""
		assert impl
		assert retrieval_method

		from zeroinstall.zerostore import manifest
		alg = impl.id.split('=', 1)[0]
		if alg not in manifest.algorithms:
			raise SafeException("Unknown digest algorithm '%s' for '%s' version %s" %
					(alg, impl.feed.get_name(), impl.get_version()))

		if isinstance(retrieval_method, DownloadSource):
			blocker, stream = self.download_archive(retrieval_method, force = force)
			yield blocker
			tasks.check(blocker)

			stream.seek(0)
			iface_cache.add_to_cache(retrieval_method, stream)
		elif isinstance(retrieval_method, Recipe):
			blocker = tasks.Task(_cook(self, impl.id, retrieval_method, force), "cook").finished
			yield blocker
			tasks.check(blocker)
		else:
			raise Exception("Unknown download type for '%s'" % retrieval_method)

	def download_archive(self, download_source, force = False):
		"""Fetch an archive. You should normally call L{begin_impl_download}
		instead, since it handles other kinds of retrieval method too."""
		from zeroinstall.zerostore import unpack
		mime_type = download_source.type
		if not mime_type:
			mime_type = unpack.type_from_url(download_source.url)
		if not mime_type:
			raise SafeException("No 'type' attribute on archive, and I can't guess from the name (%s)" % download_source.url)
		unpack.check_type_ok(mime_type)
		dl = self.handler.get_download(download_source.url, force = force)
		dl.expected_size = download_source.size + (download_source.start_offset or 0)
		return (dl.downloaded, dl.tempfile)
	
	def download_icon(self, interface, force = False):
		"""Download an icon for this interface and add it to the
		icon cache. If the interface has no icon or we are offline, do nothing.
		@return: the task doing the import, or None
		@rtype: L{tasks.Task}"""
		debug("download_icon %s (force = %d)", interface, force)

		if self.network_use == network_offline:
			info("No icon present for %s, but off-line so not downloading", interface)
			return

		# Find a suitable icon to download
		for icon in interface.get_metadata(XMLNS_IFACE, 'icon'):
			type = icon.getAttribute('type')
			if type != 'image/png':
				debug('Skipping non-PNG icon')
				continue
			source = icon.getAttribute('href')
			if source:
				break
			warn('Missing "href" attribute on <icon> in %s', interface)
		else:
			info('No PNG icons found in %s', interface)
			return

		dl = self.handler.get_download(source, force = force)

		def add_icon():
			stream = dl.tempfile
			yield dl.downloaded
			try:
				tasks.check(dl.downloaded)
				stream.seek(0)
				self.store_icon(interface, stream)
			except Exception, ex:
				self.handler.report_error(ex)

		return tasks.Task(add_icon(), "download_and_import_icon " + source)

	def store_icon(self, interface, stream):
		"""Called when an icon has been successfully downloaded.
		Subclasses may wish to wrap this to repaint the display."""
		from zeroinstall.injector import basedir
		import shutil
		icons_cache = basedir.save_cache_path(config_site, 'interface_icons')
		icon_file = file(os.path.join(icons_cache, escape(interface.uri)), 'w')
		shutil.copyfileobj(stream, icon_file)
	
	def get_implementation_path(self, impl):
		"""Return the local path of impl.
		@rtype: str
		@raise zeroinstall.zerostore.NotStored: if it needs to be added to the cache first."""
		assert isinstance(impl, Implementation)
		if impl.id.startswith('/'):
			return impl.id
		return iface_cache.stores.lookup(impl.id)

	def get_implementation(self, interface):
		"""Get the chosen implementation.
		@type interface: Interface
		@rtype: L{model.Implementation}
		@raise SafeException: if interface has not been fetched or no implementation could be
		chosen."""
		assert isinstance(interface, Interface)

		if not interface.name and not interface.feeds:
			raise SafeException("We don't have enough information to "
					    "run this program yet. "
					    "Need to download:\n%s" % interface.uri)
		try:
			return self.implementation[interface]
		except KeyError, ex:
			if interface.implementations:
				offline = ""
				if self.network_use == network_offline:
					offline = "\nThis may be because 'Network Use' is set to Off-line."
				raise SafeException("No usable implementation found for '%s'.%s" %
						(interface.name, offline))
			raise ex

	def get_cached(self, impl):
		"""Check whether an implementation is available locally.
		@type impl: model.Implementation
		@rtype: bool
		"""
		if isinstance(impl, DistributionImplementation):
			return impl.installed
		if impl.id.startswith('/'):
			return os.path.exists(impl.id)
		else:
			try:
				path = self.get_implementation_path(impl)
				assert path
				return True
			except:
				pass # OK
		return False
	
	def add_to_cache(self, source, data):
		"""Wrapper for L{iface_cache.IfaceCache.add_to_cache}."""
		iface_cache.add_to_cache(source, data)
	
	def get_uncached_implementations(self):
		"""List all chosen implementations which aren't yet available locally.
		@rtype: [(str, model.Implementation)]"""
		uncached = []
		for iface in self.solver.selections:
			impl = self.solver.selections[iface]
			assert impl, self.solver.selections
			if not self.get_cached(impl):
				uncached.append((iface, impl))
		return uncached
	
	def refresh_all(self, force = True):
		"""Start downloading all feeds for all selected interfaces.
		@param force: Whether to restart existing downloads."""
		return tasks.Task(self.solve_with_downloads(force = True), "refresh all")
	
	def get_feed_targets(self, feed_iface_uri):
		"""Return a list of Interfaces for which feed_iface can be a feed.
		This is used by B{0launch --feed}.
		@rtype: [model.Interface]
		@raise SafeException: If there are no known feeds."""
		# TODO: what if it isn't cached yet?
		feed_iface = iface_cache.get_interface(feed_iface_uri)
		if not feed_iface.feed_for:
			if not feed_iface.name:
				raise SafeException("Can't get feed targets for '%s'; failed to load interface." %
						feed_iface_uri)
			raise SafeException("Missing <feed-for> element in '%s'; "
					"this interface can't be used as a feed." % feed_iface_uri)
		feed_targets = feed_iface.feed_for
		debug("Feed targets: %s", feed_targets)
		if not feed_iface.name:
			warn("Warning: unknown interface '%s'" % feed_iface_uri)
		return [iface_cache.get_interface(uri) for uri in feed_targets]
	
	def get_best_source(self, impl):
		"""Return the best download source for this implementation.
		@rtype: L{model.RetrievalMethod}"""
		if impl.download_sources:
			return impl.download_sources[0]
		return None

	def solve_with_downloads(self, force = False):
		"""Run the solver, then download any feeds that are missing or
		that need to be updated. Each time a new feed is imported into
		the cache, the solver is run again, possibly adding new downloads.
		@param force: whether to download even if we're already ready to run
		@return: a generator that can be used to create a L{support.tasks.Task}."""
		
		downloads_finished = set()		# Successful or otherwise
		downloads_in_progress = {}		# URL -> Download

		host_arch = arch.get_host_architecture()
		if self.src:
			host_arch = arch.SourceArchitecture(host_arch)

		while True:
			self.solver.solve(self.root, host_arch)
			for w in self.watchers: w()

			if self.solver.ready and not force:
				break
			else:
				# Once we've starting downloading some things,
				# we might as well get them all.
				force = True

			if not self.network_use == network_offline:
				for f in self.solver.feeds_used:
					if f in downloads_finished or f in downloads_in_progress:
						continue
					if f.startswith('/'):
						continue
					feed = iface_cache.get_interface(f)
					downloads_in_progress[f] = self.download_and_import_feed(f)

			if not downloads_in_progress:
				break

			blockers = downloads_in_progress.values()
			yield blockers
			tasks.check(blockers)

			for f in downloads_in_progress.keys():
				if downloads_in_progress[f].happened:
					del downloads_in_progress[f]
					downloads_finished.add(f)

	def need_download(self):
		"""Decide whether we need to download anything (but don't do it!)
		@return: true if we MUST download something (feeds or implementations)
		@rtype: bool"""
		host_arch = arch.get_host_architecture()
		if self.src:
			host_arch = arch.SourceArchitecture(host_arch)
		self.solver.solve(self.root, host_arch)
		for w in self.watchers: w()

		if not self.solver.ready:
			return True		# Maybe a newer version will work?
		
		if self.get_uncached_implementations():
			return True

		return False
	
	def download_impls(self):
		"""Download all implementations that are missing from the cache."""
		blockers = []

		for iface, impl in self.get_uncached_implementations():
			debug("start_downloading_impls: for %s get %s", iface, impl)
			source = self.get_best_source(impl)
			if not source:
				raise model.SafeException("Implementation " + impl.id + " of "
					"interface " + iface.get_name() + " cannot be "
					"downloaded (no download locations given in "
					"interface!)")
			blockers.append(tasks.Task(self.download_impl(impl, source), "fetch impl %s" % impl).finished)

		while blockers:
			yield blockers
			tasks.check(blockers)

			blockers = [b for b in blockers if not b.happened]
