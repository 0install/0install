from interface import Interface, Implementation

class Selection:
	implementation = None	# Interface -> Implementation
	constraints = None	# Path -> [Constraints]

	def __init__(self, parent, new_implementation):
		"""Create a Selection with all the choices of parent, plus
		implementation. If this violates a constraint, throw an exception."""

		self.implementation = {}

		if new_implementation is not None:
			assert isinstance(new_implementation, Implementation)
			assert parent is not None

			self.implementation[new_implementation.interface] = \
						new_implementation
			self.implementation.update(parent.implementation)
		else:
			assert parent is None
	
	def __getitem__(self, iface):
		assert isinstance(iface, Interface)
		return self.implementation[iface]
		
	def __iter__(self):
		return iter(self.implementation)

	def setup_bindings(self):
		"""Set environment variables to run this selection."""
		for iface in self:
			for d in self[iface].dependancies:
				d.setup_bindings(self)
	
class Policy:
	def choose_best(self, interface):
		x = self.search(Selection(None, None), interface)
		if not x:
			raise Exception('No possible selections found')
		return x
	
	def search(self, decided, next):
		#print "Trying to find implementation of", next
		if next in decided:
			# Two programs want the same interface. Can't have two
			# different implementations of it, so just choose the
			# one we already selected.
			return decided

		# Try each possible implementation in turn and see
		# what works...
		for x in next.implementations:
			new_decided = Selection(decided, x)
			for dep in x.dependancies:
				found = self.search(new_decided, dep.get_interface())
				if not found:
					# TODO: backtrack?
					break	# Nothing to meet this found
				new_decided = found
			else:
				return new_decided	# Everything matched
		# No implementation was suitable
		return None
