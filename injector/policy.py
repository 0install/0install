from model import *
import basedir
from namespaces import *
import ConfigParser
import reader

class Policy(object):
	__slots__ = ['root', 'implementation', 'watchers',
		     'help_with_testing', 'network_use', 'updates']

	def __init__(self):
		self.root = None
		self.implementation = {}		# Interface -> Implementation
		self.watchers = []
		self.help_with_testing = False
		self.network_use = network_minimal
		self.updates = []

		path = basedir.load_first_config(config_site, config_prog, 'global')
		if path:
			config = ConfigParser.ConfigParser()
			config.read(path)
			self.help_with_testing = config.getboolean('global',
							'help_with_testing')
			self.network_use = config.get('global', 'network_use')
			assert self.network_use in network_levels

	def set_root_iterface(self, root):
		assert isinstance(root, Interface)
		self.root = root
	
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
			if not iface.uptodate:
				reader.update_from_cache(iface)
				assert iface.uptodate
			impl = self.get_best_implementation(iface)
			if impl:
				self.implementation[iface] = impl
				for d in impl.dependencies.values():
					process(d.get_interface())
		process(self.root)
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
	
	def walk_interfaces(self):
		def walk(iface):
			yield iface
			impl = self.get_best_implementation(iface)
			if impl:
				for d in impl.dependencies.values():
					for id in walk(d.get_interface()):
						yield id
		return walk(self.root)

# Singleton instance used everywhere...
policy = Policy()
policy.save_config()
