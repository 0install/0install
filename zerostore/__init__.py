import os

class Store:
	def __init__(self, dir):
		self.dir = dir
	
	def lookup(self, digest):
		alg, value = digest.split('=', 1)
		assert alg == 'sha1'
		assert '/' not in value
		int(value, 16)		# Check valid format
		dir = os.path.join(self.dir, digest)
		if os.path.isdir(dir):
			return dir
		return None
	
	def add_tgz_to_cache(self, required_digest, data):
		"""Data is a .tgz compressed archive. Extract it somewhere, check that
		the digest is correct, and add it to the store."""
		print "Adding impl with digest:", required_digest
