from model import *

class Policy:
	root = None
	implementation = {}		# Interface -> Implementation

	def set_root_iterface(self, root):
		assert isinstance(root, Interface)
		self.root = root
	
	def recalculate(self):
		self.implementation = {}
		def process(iface):
			impl = self.get_best_implementation(iface)
			self.implementation[iface] = impl
			if impl:
				for d in impl.dependencies.values():
					process(d.get_interface())
		process(self.root)
	
	def get_best_implementation(self, iface):
		if not iface.implementations:
			return None
		impls = iface.implementations.values()
		best = impls[0]
		for x in impls[1:]:
			if self.compare(iface, x, best) < 0:
				best = x
		return best
	
	def compare(self, interface, b, a):
		a_stab = a.stability
		b_stab = b.stability

		# Usable ones come first
		a_usable = a_stab != buggy
		b_usable = b_stab != buggy
		r = cmp(a_usable, b_usable)
		if r: return r

		# Prefer

		# Stability
		policy = interface.stability_policy
		if a_stab >= policy: a_stab = stable
		if b_stab >= policy: b_stab = stable

		r = cmp(a_stab, b_stab)
		if r: return r
		
		return cmp(a.version, b.version)
	
	def get_ranked_implementations(self, iface):
		impls = iface.implementations.values()
		impls.sort(lambda a, b: self.compare(iface, a, b))
		return impls

# Singleton instance used everywhere...
policy = Policy()
