import time
from logging import debug, info

from model import *
import basedir
from namespaces import *
import ConfigParser
import reader
import download
import zerostore

#from logging import getLogger, DEBUG
#getLogger().setLevel(DEBUG)

_interfaces = {}	# URI -> Interface

def pretty_time(t):
	return time.strftime('%Y-%m-%d %H:%M:%S UTC', t)

class Policy(object):
	__slots__ = ['root', 'implementation', 'watchers',
		     'help_with_testing', 'network_use',
		     'freshness', 'store']

	def __init__(self, root):
		assert isinstance(root, (str, unicode))
		self.root = root
		user_store = os.path.expanduser('~/.cache/0install.net/implementations')
		if not os.path.isdir(user_store):
			os.makedirs(user_store)
		self.store = zerostore.Store(user_store)
		self.implementation = {}		# Interface -> Implementation
		self.watchers = []
		self.help_with_testing = False
		self.network_use = network_full
		self.freshness = 60 * 60 * 24 * 7	# Seconds since last update
		self.updates = []

		path = basedir.load_first_config(config_site, config_prog, 'global')
		if path:
			config = ConfigParser.ConfigParser()
			config.read(path)
			self.help_with_testing = config.getboolean('global',
							'help_with_testing')
			self.network_use = config.get('global', 'network_use')
			self.freshness = int(config.get('global', 'freshness'))
			assert self.network_use in network_levels

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
		
		r = cmp(a.version, b.version)
		if r: return r

		if self.network_use != network_full:
			r = cmp(self.get_cached(a), self.get_cached(b))
			if r: return r

		return cmp(a.path, b.path)
	
	def get_ranked_implementations(self, iface):
		impls = iface.implementations.values()
		impls.sort(lambda a, b: self.compare(iface, a, b))
		return impls
	
	def is_unusable(self, impl):
		if impl.get_stability() <= buggy:
			return True
		if self.network_use == network_offline and not self.get_cached(impl):
			return True
		return False
	
	def get_interface(self, uri):
		"""Get the interface for uri. If it's in the cache, read that.
		If it's not in the cache or policy says so, start downloading
		the latest version."""
		if type(uri) == str:
			uri = unicode(uri)
		assert isinstance(uri, unicode)

		if uri not in _interfaces:
			# Haven't used this interface so far. Initialise from cache.
			_interfaces[uri] = Interface(uri)
			self.init_interface(_interfaces[uri])

		staleness = time.time() - (_interfaces[uri].last_checked or 0)
		#print "Staleness for '%s' is %d" % (_interfaces[uri].name, staleness)

		if self.network_use != network_offline and \
		   self.freshness > 0 and staleness > self.freshness:
		   	#print "Updating..."
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
	
	def begin_iface_download(self, interface, force = False):
		dl = download.begin_iface_download(interface, force)
		if not dl:
			assert not force
			return		# Already in progress

		# Calls update_interface_from_network eventually on success
		self.monitor_download(dl)
	
	def monitor_download(self, dl):
		raise NotImplementedError("Abstract method")
	
	def update_interface_from_network(self, interface, new_xml):
		"""xml is the new XML (after the signature has been checked and
		removed)."""
		debug("Updating '%s' from network" % (interface.name or interface.uri))

		self.import_new_interface(interface, new_xml)

		import writer
		interface.last_checked = long(time.time())
		writer.save_interface(interface)

		self.recalculate()
	
	def import_new_interface(self, interface, new_xml):
		upstream_dir = basedir.save_config_path(config_site, config_prog, 'interfaces')
		cached = os.path.join(upstream_dir, escape(interface.uri))

		if os.path.exists(cached):
			old_xml = file(cached).read()
			if old_xml == new_xml:
				debug("No change")
				return
			else:
				self.confirm_diff(old_xml, new_xml, interface.uri)

		stream = file(cached + '.new', 'w')
		stream.write(new_xml)
		stream.close()
		new_mtime = reader.check_readable(interface.uri, cached + '.new')
		assert new_mtime
		if interface.last_modified:
			if new_mtime < interface.last_modified:
				raise SafeException("New interface's modification time is before old "
						    "version!"
						    "\nOld time: " + pretty_time(interface.last_modified) +
						    "\nNew time: " + pretty_time(new_mtime) + 
						    "\nRefusing update (leaving new copy as " +
						    cached + ".new)")
			if new_mtime == interface.last_modified:
				raise SafeException("Interface has changed, but modification time "
						    "hasn't! Refusing update.")
		os.rename(cached + '.new', cached)
		debug("Saved as " + cached)

		reader.update_from_cache(interface)

	def get_implementation_path(self, impl):
		assert isinstance(impl, Implementation)
		if impl.id.startswith('/'):
			return impl.id
		path = self.store.lookup(impl.id)
		if path:
			return path
		raise Exception("Item '%s' not found in cache '%s' (digest is '%s')" % (impl, self.store.dir, impl.id))
		
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
		def walk(iface):
			yield iface
			impl = self.get_best_implementation(iface)
			if impl:
				for d in impl.dependencies.values():
					for idep in walk(self.get_interface(d.interface)):
						yield idep
		return walk(self.get_interface(self.root))

	def walk_implementations(self):
		def walk(iface):
			impl = self.get_best_implementation(iface)
			yield (iface, impl)
			for d in impl.dependencies.values():
				for idep in walk(self.get_interface(d.interface)):
					yield idep
		return walk(self.get_interface(self.root))

	def check_signed_data(self, download, signed_data):
		"""Downloaded data is a GPG-signed message. Check that the signature is trusted
		and call self.update_interface_from_network() when done."""
		import gpg
		data, errors, sigs = gpg.check_stream(signed_data)
		iface_xml = data.read()
		data.close()
		if not self.update_interface_if_trusted(download.interface, sigs, iface_xml):
			self.confirm_trust_keys(download.interface, sigs, iface_xml)

	def update_interface_if_trusted(self, interface, sigs, xml):
		for s in sigs:
			if s.is_trusted():
				self.update_interface_from_network(interface, xml)
				return True
		return False
	
	def confirm_trust_keys(self, interface, sigs, iface_xml):
		"""We don't trust any of the signatures yet. Ask the user.
		When done, call update_interface_if_trusted()."""
		import gpg
		valid_sigs = [s for s in sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			raise SafeException('No valid signatures found')

		print "\nInterface:", interface.uri
		print "The interface is correctly signed with the following keys:"
		for x in valid_sigs:
			print "-", x
		print "Do you want to trust all of these keys to sign interfaces?"
		while True:
			i = raw_input("Trust all [Y/N] ")
			if not i: continue
			if i in 'Nn':
				raise SafeException('Not signed with a trusted key')
			if i in 'Yy':
				break
		from trust import trust_db
		for key in valid_sigs:
			print "Trusting", key.fingerprint
			trust_db.trust_key(key.fingerprint)

		if not self.update_interface_if_trusted(interface, sigs, iface_xml):
			raise Exception('Bug: still not trusted!!')

	def confirm_diff(self, old, new, uri):
		import difflib
		diff = difflib.unified_diff(old.split('\n'), new.split('\n'), uri, "",
						"", "", 2, "")
		print "Updates:"
		for line in diff:
			print line

	def get_cached(self, impl):
		impl._cached = False
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
		assert isinstance(source, DownloadSource)
		required_digest = source.implementation.id
		self.store.add_tgz_to_cache(required_digest, data, source.extract)
	
	def get_uncached_implementations(self):
		uncached = []
		for iface, impl in self.walk_implementations():
			if not self.get_cached(impl):
				uncached.append((iface, impl))
		return uncached
