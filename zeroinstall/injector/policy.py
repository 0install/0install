import time
import sys
from logging import info, debug
from cStringIO import StringIO
import arch

from model import *
import basedir
from namespaces import *
import ConfigParser
import reader
import download
from iface_cache import iface_cache

class Policy(object):
	__slots__ = ['root', 'implementation', 'watchers',
		     'help_with_testing', 'network_use',
		     'freshness', 'ready', 'handler']

	def __init__(self, root, handler = None):
		self.watchers = []
		self.help_with_testing = False
		self.network_use = network_full
		self.freshness = 60 * 60 * 24 * 7	# Seconds allowed since last update

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
		def process(iface):
			debug("recalculate: considering interface %s", iface)
			if iface in self.implementation:
				debug("cycle; skipping")
				return
			impl = self._get_best_implementation(iface)
			self.implementation[iface] = impl
			if impl:
				debug("Will use implementation %s (version %s)", impl, impl.get_version())
				for d in impl.dependencies.values():
					process(self.get_interface(d.interface))
			else:
				debug("No implementation chould be chosen yet");
				self.ready = False
		process(self.get_interface(self.root))
		for w in self.watchers: w()
	
	# Only to be called from recalculate, as it is quite slow.
	# Use the results stored in self.implementation instead.
	def _get_best_implementation(self, iface):
		if not iface.implementations:
			info("Interface %s has no implementations!", iface)
			return None
		impls = iface.implementations.values()
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
	
	def get_ranked_implementations(self, iface):
		impls = iface.implementations.values()
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
		new, iface = iface_cache.get_interface(uri)
		if new and iface.last_modified is None:
			if self.network_use != network_offline:
				debug("Interface not cached and not off-line. Downloading...")
				self.begin_iface_download(iface)
			else:
				debug("Nothing known about interface, but we are off-line.")
		elif not uri.startswith('/'):
			staleness = time.time() - (iface.last_checked or 0)
			debug("Staleness for %s is %.2f hours", iface, staleness / 3600.0)

			if self.network_use != network_offline and self.freshness > 0 and staleness > self.freshness:
				debug("Updating %s", iface)
				self.begin_iface_download(iface, False)
		else:
			debug("Local interface, so not checking staleness.")
		return iface
	
	def begin_iface_download(self, interface, force = False):
		debug("begin_iface_download %s (force = %d)", interface, force)
		if interface.uri.startswith('/'):
			return
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

		if not interface.name:
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
	
	def interface_changed(self, interface):
		debug("interface_changed(%s): recalculating", interface)
		self.recalculate()
