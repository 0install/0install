import os
import shutil
import traceback
from tempfile import mkdtemp
import sha
import re

import manifest

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
	
	def add_tgz_to_cache(self, required_digest, data, extract = None):
		"""Data is a .tgz compressed archive. Extract it somewhere, check that
		the digest is correct, and add it to the store.
		extract is the name of a directory within the archive to extract, rather
		than extracting the whole archive. This is most useful to remove an extra
		top-level directory."""
		assert required_digest.startswith('sha1=')
		print "Adding impl with digest:", required_digest

		if self.lookup(required_digest):
			print "Not adding", required_digest, "as it already exists!"
			return

		args = ['tar', 'xz', '--no-same-owner', '--no-same-permissions']
		if extract:
			# Limit the characters we accept, to avoid sending dodgy
			# strings to tar
			if not re.match('^[a-zA-Z0-9][-_a-zA-Z0-9.]*$', extract):
				raise Exception('Illegal character in extract attribute')
			args.append(extract)

		tmp = self.extract(data, args)
		if extract:
			extracted = os.path.join(tmp, extract)
			if not os.path.isdir(extracted):
				raise Exception('Directory %s not found in archive' % extract)
		else:
			extracted = tmp

		sha1 = 'sha1=' + manifest.add_manifest_file(extracted, sha.new()).hexdigest()
		if sha1 != required_digest:
			raise Exception('Incorrect manifest -- archive is corrupted.\n'
					'Required digest: %s\n'
					'Actual digest: %s\n'
					'Leaving invalid archive as: %s' %
					(required_digest, sha1, extracted))

		if extract:
			os.rename(os.path.join(tmp, extract),
				  os.path.join(self.dir, required_digest))
			os.rmdir(tmp)
		else:
			os.rename(tmp, os.path.join(self.dir, required_digest))

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
		return tmp
