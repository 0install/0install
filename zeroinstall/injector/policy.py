# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import time
import sys
from logging import info, debug, warn
import arch

from model import *
import basedir
from namespaces import *
import ConfigParser
import reader
from iface_cache import iface_cache
from zeroinstall import NeedDownload

class Policy(object):
	__slots__ = ['root', 'implementation', 'watchers',
		     'help_with_testing', 'network_use',
		     'freshness', 'ready', 'handler', 'warned_offline']

	def __init__(self, root, handler = None):
		self.watchers = []
		self.help_with_testing = False
		self.network_use = network_full
		self.freshness = 60 * 60 * 24 * 30	# Seconds allowed since last update (1 month)
		self.ready = False

		# If we need to download something but can't because we are offline,
		# warn the user. But only the first time.
		self.warned_offline = False

		# (allow self for backwards compat)
		self.handler = handler or self

		debug("Supported systems: '%s'", arch.os_ranks)
		debug("Supported processors: '%s'", arch.machine_ranks)

		path = basedir.load_first_config(config_site, config_prog, 'global')
		if path:
			try:
				config = ConfigParser.ConfigParser()
				config.read(path)
				self.help_with_testing = config.getboolean('global',
								'help_with_testing')
				self.network_use = config.get('global', 'network_use')
				self.freshness = int(config.get('global', 'freshness'))
				assert self.network_use in network_levels
			except Exception, ex:
				print >>sys.stderr, "Error loading config:", ex

		self.set_root(root)

		iface_cache.add_watcher(self)
	
	def set_root(self, root):
		assert isinstance(root, (str, unicode))
		self.root = root
		self.implementation = {}		# Interface -> [Implementation | None]

	def save_config(self):
		config = ConfigParser.ConfigParser()
		config.add_section('global')

		config.set('global', 'help_with_testing', self.help_with_testing)
		config.set('global', 'network_use', self.network_use)
		config.set('global', 'freshness', self.freshness)

		path = basedir.save_config_path(config_site, config_prog)
		path = os.path.join(path, 'global')
		config.write(file(path + '.new', 'w'))
		os.rename(path + '.new', path)
	
	def recalculate(self):
		self.implementation = {}
		self.ready = True
		debug("Recalculate! root = %s", self.root)
		def process(iface):
			if iface in self.implementation:
				debug("cycle; skipping second %s", iface)
				return
			self.implementation[iface] = None	# Avoid cycles

			impl = self._get_best_implementation(iface)
			if impl:
				debug("Will use implementation %s (version %s)", impl, impl.get_version())
				self.implementation[iface] = impl
				for d in impl.dependencies.values():
					debug("Considering dependency %s", d)
					process(self.get_interface(d.interface))
			else:
				debug("No implementation chould be chosen yet");
				self.ready = False
		process(self.get_interface(self.root))
		for w in self.watchers: w()
	
	# Only to be called from recalculate, as it is quite slow.
	# Use the results stored in self.implementation instead.
	def _get_best_implementation(self, iface):
		impls = iface.implementations.values()
		for f in self.usable_feeds(iface):
			debug("Processing feed %s", f)
			try:
				feed_iface = self.get_interface(f.uri)
				if feed_iface.name and iface.uri not in feed_iface.feed_for:
					warn("Missing <feed-for> for '%s' in '%s'",
						iface.uri, f.uri)
				if feed_iface.implementations:
					impls.extend(feed_iface.implementations.values())
			except NeedDownload, ex:
				raise ex
			except Exception, ex:
				warn("Failed to load feed %s for %s: %s",
					f, iface, str(ex))

		debug("get_best_implementation(%s), with feeds: %s", iface, iface.feeds)

		if not impls:
			info("Interface %s has no implementations!", iface)
			return None
		best = impls[0]
		for x in impls[1:]:
			if self.compare(iface, x, best) < 0:
				best = x
		if self.is_unusable(best):
			info("Best implementation of %s is %s, but unusable (%s)", iface, best,
							self.get_unusable_reason(best))
			return None
		return best
	
	def compare(self, interface, b, a):
		a_stab = a.get_stability()
		b_stab = b.get_stability()

		# Usable ones come first
		r = cmp(self.is_unusable(b), self.is_unusable(a))
		if r: return r

		# Preferred versions come first
		r = cmp(a_stab == preferred, b_stab == preferred)
		if r: return r

		if self.network_use != network_full:
			r = cmp(self.get_cached(a), self.get_cached(b))
			if r: return r

		# Stability
		stab_policy = interface.stability_policy
		if not stab_policy:
			if self.help_with_testing: stab_policy = testing
			else: stab_policy = stable

		if a_stab >= stab_policy: a_stab = preferred
		if b_stab >= stab_policy: b_stab = preferred

		r = cmp(a_stab, b_stab)
		if r: return r
		
		# Newer versions come before older ones
		r = cmp(a.version, b.version)
		if r: return r

		# Get best OS
		r = cmp(arch.os_ranks.get(a.os, None),
			arch.os_ranks.get(b.os, None))
		if r: return r

		# Get best machine
		r = cmp(arch.machine_ranks.get(a.machine, None),
			arch.machine_ranks.get(b.machine, None))
		if r: return r

		# Slightly prefer cached versions
		if self.network_use == network_full:
			r = cmp(self.get_cached(a), self.get_cached(b))
			if r: return r

		return cmp(a.id, b.id)
	
	def usable_feeds(self, iface):
		"""Generator for iface.feeds that are valid for our architecture."""
		for f in iface.feeds:
			if f.os in arch.os_ranks and f.machine in arch.machine_ranks:
				yield f
			else:
				debug("Skipping '%s'; unsupported architecture %s-%s",
					f, f.os, f.machine)
	
	def get_ranked_implementations(self, iface):
		impls = iface.implementations.values()
		for f in self.usable_feeds(iface):
			feed_iface = self.get_interface(f.uri)
			if feed_iface.implementations:
				impls.extend(feed_iface.implementations.values())
		impls.sort(lambda a, b: self.compare(iface, a, b))
		return impls
	
	def is_unusable(self, impl):
		return self.get_unusable_reason(impl) != None

	def get_unusable_reason(self, impl):
		"""Returns the reason why this impl is unusable, or None if it's OK"""
		stability = impl.get_stability()
		if stability <= buggy:
			return stability.name
		if self.network_use == network_offline and not self.get_cached(impl):
			return "Not cached and we are off-line"
		if impl.os not in arch.os_ranks:
			return "Unsupported OS"
		if impl.machine not in arch.machine_ranks:
			return "Unsupported machine type"
		return None

	def get_interface(self, uri):
		iface = iface_cache.get_interface(uri)

		if iface.last_modified is None:
			if self.network_use != network_offline:
				debug("Interface not cached and not off-line. Downloading...")
				self.begin_iface_download(iface)
			else:
				if self.warned_offline:
					debug("Nothing known about interface, but we are off-line.")
				else:
					if iface.feeds:
						info("Nothing known about interface '%s' and off-line. Trying feeds only.", uri)
					else:
						warn("Nothing known about interface '%s', but we are in off-line mode "
							"(so not fetching).", uri)
						self.warned_offline = True
		elif not uri.startswith('/'):
			staleness = time.time() - (iface.last_checked or 0)
			debug("Staleness for %s is %.2f hours", iface, staleness / 3600.0)

			if self.network_use != network_offline and self.freshness > 0 and staleness > self.freshness:
				debug("Updating %s", iface)
				self.begin_iface_download(iface, False)
		#else: debug("Local interface, so not checking staleness.")

		return iface
	
	def begin_iface_download(self, interface, force = False):
		debug("begin_iface_download %s (force = %d)", interface, force)
		if interface.uri.startswith('/'):
			return
		from zeroinstall.injector import download
		dl = download.begin_iface_download(interface, force)
		if not dl:
			assert not force
			debug("Already in progress")
			return

		debug("Need to download")
		# Calls update_interface_from_network eventually on success
		self.handler.monitor_download(dl)
	
	def get_implementation_path(self, impl):
		assert isinstance(impl, Implementation)
		if impl.id.startswith('/'):
			return impl.id
		return iface_cache.stores.lookup(impl.id)

	def get_implementation(self, interface):
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

	def walk_interfaces(self):
		# Deprecated
		return iter(self.implementation)

	def check_signed_data(self, download, signed_data):
		iface_cache.check_signed_data(download.interface, signed_data, self.handler)
	
	def get_cached(self, impl):
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
		iface_cache.add_to_cache(source, data)
	
	def get_uncached_implementations(self):
		uncached = []
		for iface in self.implementation:
			impl = self.implementation[iface]
			assert impl
			if not self.get_cached(impl):
				uncached.append((iface, impl))
		return uncached
	
	def refresh_all(self, force = True):
		for x in self.walk_interfaces():
			self.begin_iface_download(x, force)
			for f in self.usable_feeds(x):
				feed_iface = self.get_interface(f.uri)
				self.begin_iface_download(feed_iface, force)
	
	def interface_changed(self, interface):
		debug("interface_changed(%s): recalculating", interface)
		self.recalculate()
	
	def get_feed_targets(self, feed_iface_uri):
		"""Return a list of Interfaces for which feed_iface can be a feed.
		This is used by --feed. If there are no interfaces, raises SafeException."""
		feed_iface = self.get_interface(feed_iface_uri)
		if not feed_iface.feed_for:
			if not feed_iface.name:
				raise SafeException("Can't get feed targets for '%s'; failed to load interface." %
						feed_iface_uri)
			raise SafeException("Missing <feed-for> element in '%s'; "
					"this interface can't be used as a feed." % feed_iface_uri)
		feed_targets = feed_iface.feed_for
		if not feed_iface.name:
			warn("Warning: unknown interface '%s'" % feed_iface_uri)
		return [self.get_interface(uri) for uri in feed_targets]
