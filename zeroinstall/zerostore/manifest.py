# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import generators
import os, stat
from sets import Set
import sha
from zeroinstall import SafeException

try:
	import hashlib
except:
	hashlib = None

"""A manifest is a string representing a directory tree, with the property
that two trees will generate identical manifest strings if and only if:

- They have extactly the same set of files, directories and symlinks.
- For each pair of corresponding directories in the two sets:
  - The mtimes are the same.
- For each pair of corresponding files in the two sets:
  - The size, executable flag and mtime are the same.
  - The contents have matching SHA1 sums.
- For each pair of corresponding symlinks in the two sets:
  - The mtime and size are the same.
  - The targets have matching SHA1 sums.

The manifest is typically processed with SHA1 itself. So, the idea is that
any significant change to the contents of the tree will change the SHA1 sum
of the manifest.

A top-level ".manifest" file is ignored.
"""

class Algorithm:
	def generate_manifest(root):
		"""Returns an iterator that yields each line of the manifest for the directory
		tree rooted at 'root'."""
		raise Exception('Abstract')

	def new_digest(self):
		"""Create a new digest. Call update() on the returned object to digest the data.
		Call getID() to turn it into a full ID string."""
		raise Exception('Abstract')

	def getID(self, digest):
		"""Convert a digest (from new_digest) to a full ID."""
		raise Exception('Abstract')

class OldSHA1(Algorithm):
	def generate_manifest(self, root):
		def recurse(sub):
			# To ensure that a line-by-line comparison of the manifests
			# is possible, we require that filenames don't contain newlines.
			# Otherwise, you can name a file so that the part after the \n
			# would be interpreted as another line in the manifest.
			assert '\n' not in sub
			assert sub.startswith('/')

			if sub == '/.manifest': return

			full = os.path.join(root, sub[1:])
			info = os.lstat(full)
			
			m = info.st_mode
			if stat.S_ISDIR(m):
				if sub != '/':
					yield "D %s %s" % (info.st_mtime, sub)
				items = os.listdir(full)
				items.sort()
				for x in items:
					for y in recurse(os.path.join(sub, x)):
						yield y
				return

			assert sub[1:]
			leaf = os.path.basename(sub[1:])
			if stat.S_ISREG(m):
				d = sha.new(file(full).read()).hexdigest()
				if m & 0111:
					yield "X %s %s %s %s" % (d, info.st_mtime,info.st_size, leaf)
				else:
					yield "F %s %s %s %s" % (d, info.st_mtime,info.st_size, leaf)
			elif stat.S_ISLNK(m):
				d = sha.new(os.readlink(full)).hexdigest()
				# Note: Can't use utime on symlinks, so skip mtime
				yield "S %s %s %s" % (d, info.st_size, leaf)
			else:
				raise SafeException("Unknown object '%s' (not a file, directory or symlink)" %
						full)
		for x in recurse('/'): yield x
	
	def new_digest(self):
		return sha.new()

	def getID(self, digest):
		return 'sha1=' + digest.hexdigest()

def get_algorithm(name):
	from zeroinstall.zerostore import BadDigest
	try:
		return algorithms[name]
	except KeyError:
		raise BadDigest("Unknown algorithm '%s'" % name)

def generate_manifest(root, alg = 'sha1'):
	return get_algorithm(alg).generate_manifest(root)
	
def add_manifest_file(dir, digest, alg = 'sha1'):
	"""Writes a .manifest file into 'dir', and updates digest."""
	mfile = os.path.join(dir, '.manifest')
	if os.path.islink(mfile) or os.path.exists(mfile):
		raise Exception('Archive contains a .manifest file!')
	manifest = ''
	for line in get_algorithm(alg).generate_manifest(dir):
		manifest += line + '\n'
	digest.update(manifest)
	stream = file(mfile, 'w')
	stream.write(manifest)
	stream.close()
	return digest

def splitID(id):
	"""Take an ID in the form 'alg=value' and return a tuple (alg, value),
	where 'alg' is an instance of Algorithm and 'value' is a string. If the
	algorithm isn't known or the ID has the wrong format, raise KeyError."""
	parts = id.split('=', 1)
	if len(parts) != 2:
		raise BadDigest("Digest '%s' is not in the form 'algorithm=value'")
	return (get_algorithm(parts[0]), parts[1])

def verify(root):
	"""Ensure that directory 'dir' generates the given digest.
	Raises BadDigest if not. For a non-error return:
	- Dir's name must be a digest (in the form "alg=value")
	- The calculated digest of the contents must match this name.
	- If there is a .manifest file, then its digest must also match."""
	from zeroinstall.zerostore import BadDigest
	
	required_digest = os.path.basename(root)
	alg = splitID(required_digest)[0]

	digest = alg.new_digest()
	lines = []
	for line in alg.generate_manifest(root):
		line += '\n'
		digest.update(line)
		lines.append(line)
	actual_digest = alg.getID(digest)

	manifest_file = os.path.join(root, '.manifest')
	if os.path.isfile(manifest_file):
		digest = alg.new_digest()
		digest.update(file(manifest_file).read())
		manifest_digest = alg.getID(digest)
	else:
		manifest_digest = None

	if required_digest == actual_digest == manifest_digest:
		return

	error = BadDigest("Cached item does NOT verify.")
	
	error.detail = " Expected digest: " + required_digest + "\n" + \
		       "   Actual digest: " + actual_digest + "\n" + \
		       ".manifest digest: " + (manifest_digest or 'No .manifest file') + "\n\n"

	if manifest_digest is None:
		error.detail += "No .manifest, so no further details available."
	elif manifest_digest == actual_digest:
		error.detail += "The .manifest file matches the actual contents. Very strange!"
	elif manifest_digest == required_digest:
		import difflib
		diff = difflib.unified_diff(file(manifest_file).readlines(), lines,
					    'Recorded', 'Actual')
		error.detail += "The .manifest file matches the directory name.\n" \
				"The contents of the directory have changed:\n" + \
				''.join(diff)
	elif required_digest == actual_digest:
		error.detail += "The directory contents are correct, but the .manifest file is wrong!"
	else:
		error.detail += "The .manifest file matches neither of the other digests. Odd."
	raise error

class HashLibAlgorithm(Algorithm):
	new_digest = None		# Constructor for digest objects

	def __init__(self, name):
		self.name = name
		if name == 'sha1':
			import sha
			self.new_digest = sha.new
		else:
			self.new_digest = getattr(hashlib, name)

	def generate_manifest(self, root):
		def recurse(sub):
			# To ensure that a line-by-line comparison of the manifests
			# is possible, we require that filenames don't contain newlines.
			# Otherwise, you can name a file so that the part after the \n
			# would be interpreted as another line in the manifest.
			assert '\n' not in sub
			assert sub.startswith('/')

			if sub == '/.manifest': return

			full = os.path.join(root, sub[1:])
			info = os.lstat(full)
			new_digest = self.new_digest
			
			m = info.st_mode
			assert stat.S_ISDIR(m)
			if sub != '/':
				yield "D %s" % sub
			items = os.listdir(full)
			items.sort()
			dirs = []
			for leaf in items:
				path = os.path.join(root, sub[1:], leaf)
				if os.path.isdir(path):
					dirs.append(leaf)
				else:
					info = os.lstat(path)
					m = info.st_mode
					if stat.S_ISREG(m):
						d = new_digest(file(path).read()).hexdigest()
						if m & 0111:
							yield "X %s %s %s %s" % (d, info.st_mtime,info.st_size, leaf)
						else:
							yield "F %s %s %s %s" % (d, info.st_mtime,info.st_size, leaf)
					elif stat.S_ISLNK(m):
						d = new_digest(os.readlink(path)).hexdigest()
						# Note: Can't use utime on symlinks, so skip mtime
						yield "S %s %s %s" % (d, info.st_size, leaf)
					else:
						raise SafeException("Unknown object '%s' (not a file, directory or symlink)" %
								path)
			for x in dirs:
				for y in recurse(os.path.join(sub, x)): yield y
			return

		for x in recurse('/'): yield x

	def getID(self, digest):
		return self.name + '=' + digest.hexdigest()

algorithms = {
	'sha1': OldSHA1(),
	'sha1new': HashLibAlgorithm('sha1'),
}

if hashlib is not None:
	algorithms['sha256'] = HashLibAlgorithm('sha256')
