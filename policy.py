from model import *

class Policy:
	def __init__(self, root):
		assert isinstance(root, Interface)
		self.root = root
	
	def get_implementation(self, iface):
		if iface.implementations:
			return iface.implementations.values()[0]
		return None
