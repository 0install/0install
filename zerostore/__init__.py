import os
import shutil
import traceback
from tempfile import mkdtemp

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

		self.extract(data, ('tar', 'xz'))

	def extract(self, stream, command):
		tmp = mkdtemp(dir = self.dir, prefix = 'tmp-')
		try:
			child = os.fork()
			if child == 0:
				try:
					try:
						os.chdir(tmp)
						stream.seek(0)
						os.dup2(stream.fileno(), 0)
						os.execvp(command[0], command)
					except:
						traceback.print_exc()
				finally:
					os._exit(1)
			id, status = os.waitpid(child, 0)
			assert id == child
			if status != 0:
				raise Exception('Failed to extract archive; exit code %d' % status)
		except:
			shutil.rmtree(tmp)
			raise
