from model import *

class Policy:
	def __init__(self, root):
		assert isinstance(root, Interface)
		self.root = root
	
	def get_implementation(self, iface):
		return None
