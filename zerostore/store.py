import os

class Store:
	def __init__(self, dir):
		self.dir = dir
	
	def lookup_sha1(self, sha1):
		assert '/' not in sha1
		int(sha1, 16)		# Check valid format
		dir = os.path.join(self.dir, sha1)
		if os.path.isdir(dir):
			return dir
		return None
