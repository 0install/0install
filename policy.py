from model import *
import basedir
from namespaces import *
import ConfigParser
import reader
from logging import debug, info
from download import Download

#from logging import getLogger, DEBUG
#getLogger().setLevel(DEBUG)

_interfaces = {}	# URI -> Interface

class Policy(object):
	__slots__ = ['root', 'implementation', 'watchers',
		     'help_with_testing', 'network_use', 'updates',
		     'ui', 'downloads', 'failed_downloads']

	def __init__(self):
		self.root = None
		self.implementation = {}		# Interface -> Implementation
		self.watchers = []
		self.help_with_testing = False
		self.network_use = network_full
		self.updates = []
		self.downloads = {}		# URI -> Download
		self.failed_downloads = {}	# URI -> True
		self.ui = None

		path = basedir.load_first_config(config_site, config_prog, 'global')
		if path:
			config = ConfigParser.ConfigParser()
			config.read(path)
			self.help_with_testing = config.getboolean('global',
							'help_with_testing')
			self.network_use = config.get('global', 'network_use')
			assert self.network_use in network_levels

	def set_root_interface(self, root, ui):
		assert isinstance(root, (str, unicode))
		assert ui
		self.root = root
		self.ui = ui
		self.recalculate()

	def save_config(self):
		config = ConfigParser.ConfigParser()
		config.add_section('global')

		config.set('global', 'help_with_testing', self.help_with_testing)
		config.set('global', 'network_use', self.network_use)

		path = basedir.save_config_path(config_site, config_prog)
		path = os.path.join(path, 'global')
		config.write(file(path + '.new', 'w'))
		os.rename(path + '.new', path)
	
	def recalculate(self):
		self.implementation = {}
		self.updates = []
		def process(iface):
			impl = self.get_best_implementation(iface)
			if impl:
				self.implementation[iface] = impl
				for d in impl.dependencies.values():
					process(self.get_interface(d.interface))
		process(self.get_interface(self.root))
		for w in self.watchers: w()
	
	def get_best_implementation(self, iface):
		if not iface.implementations:
			return None
		impls = iface.implementations.values()
		best = impls[0]
		for x in impls[1:]:
			if self.compare(iface, x, best) < 0:
				best = x
		if self.is_unusable(best):
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
			r = cmp(a.get_cached(), b.get_cached())
			if r: return r

		# Stability
		policy = interface.stability_policy
		if not policy:
			if self.help_with_testing: policy = testing
			else: policy = stable

		if a_stab >= policy: a_stab = preferred
		if b_stab >= policy: b_stab = preferred

		r = cmp(a_stab, b_stab)
		if r: return r
		
		r = cmp(a.version, b.version)
		if r: return r

		if self.network_use != network_full:
			r = cmp(a.get_cached(), b.get_cached())
			if r: return r

		return cmp(a.path, b.path)
	
	def get_ranked_implementations(self, iface):
		impls = iface.implementations.values()
		impls.sort(lambda a, b: self.compare(iface, a, b))
		return impls
	
	def is_unusable(self, impl):
		if impl.get_stability() <= buggy:
			return True
		if self.network_use == network_offline and not impl.get_cached():
			return True
		return False
	
	def get_interface(self, uri):
		"""Get the interface for uri. If it's in the cache, read that.
		If it's not in the cache or network use is full, start downloading
		the latest version."""
		if type(uri) == str:
			uri = unicode(uri)
		assert isinstance(uri, unicode)

		if uri not in _interfaces:
			# Haven't used this interface so far. Initialise from cache.
			_interfaces[uri] = Interface(uri)
			self.init_interface(_interfaces[uri])

		if self.network_use == network_full and not _interfaces[uri].uptodate:
			self.begin_iface_download(_interfaces[uri])

		return _interfaces[uri]
	
	def init_interface(self, iface):
		"""We've just created a new Interface. Update from disk cache/network."""
		debug("Created " + iface.uri)
		cached = reader.update_from_cache(iface)
		if not cached:
			if self.network_use != network_offline:
				debug("Interface not cached and not off-line. Downloading...")
				self.begin_iface_download(iface)
			else:
				debug("Nothing known about interface, but we are off-line.")
	
	def begin_iface_download(self, interface):
		if interface.uri in self.downloads or interface.uri in self.failed_downloads:
			return

		info("Download %s", interface.uri)
		def done(result):
			assert dl.url in self.downloads
			del self.downloads[dl.url]

			try:
				if isinstance(result, Exception):
					raise result
				data = self.ui.get_signed_data(result)
				self.update_interface_from_network(interface, data)
			except Exception, ex:
				self.failed_downloads[dl.url] = True
				self.ui.report_failed_download(interface, dl, ex)

			self.ui.download_ended(dl)
			self.recalculate()

		dl = Download(interface.uri, done)
		self.downloads[interface.uri] = dl
		self.ui.download_started(dl)
	
	def update_interface_from_network(self, interface, stream):
		debug("Updating '%s' from network" % (interface.name or interface.uri))
		assert interface.uri.startswith('/')

		upstream_dir = basedir.save_config_path(config_site, config_prog, 'interfaces')
		cached = os.path.join(upstream_dir, escape(interface.uri))

		new_xml = stream.read()

		if os.path.exists(cached):
			old_xml = file(cached).read()
			if old_xml == new_xml:
				debug("No change")
			else:
				self.confirm_diff(old_xml, new_xml, interface.uri)

		stream = file(cached + '.new', 'w')
		stream.write(new_xml)
		stream.close()
		reader.update(interface, cached + '.new')
		os.rename(cached + '.new', cached)
		debug("Saved as " + cached)
		
		interface.uptodate = True

		reader.update_user_overrides(interface)

	def walk_interfaces(self):
		def walk(iface):
			yield iface
			impl = self.get_best_implementation(iface)
			if impl:
				for d in impl.dependencies.values():
					for id in walk(self.get_interface(d.interface)):
						yield id
		return walk(self.get_interface(self.root))

	def confirm_diff(self, old, new, uri):
		import difflib
		diff = difflib.unified_diff(old.split('\n'), new.split('\n'), uri, "",
						"", "", 2, "")
		print "Updates:"
		for line in diff:
			print line


# Singleton instance used everywhere...
policy = Policy()
policy.save_config()
