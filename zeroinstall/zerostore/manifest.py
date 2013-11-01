
"""Processing of implementation manifests.

A manifest is a string representing a directory tree, with the property
that two trees will generate identical manifest strings if and only if:

 - They have extactly the same set of files, directories and symlinks.
 - For each pair of corresponding directories in the two sets:
   - The mtimes are the same (OldSHA1 only).
 - For each pair of corresponding files in the two sets:
   - The size, executable flag and mtime are the same.
   - The contents have matching secure hash values.
 - For each pair of corresponding symlinks in the two sets:
   - The mtime and size are the same.
   - The targets have matching secure hash values.

The manifest is typically processed with a secure hash itself. So, the idea is that
any significant change to the contents of the tree will change the secure hash value
of the manifest.

A top-level ".manifest" file is ignored.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.


import os, sys, stat, base64
from zeroinstall import SafeException, _
from zeroinstall.zerostore import BadDigest, parse_algorithm_digest_pair, format_algorithm_digest_pair

# unicode compat
if sys.version_info < (3,):
	def _u(s): return s.decode('utf-8')
else:
	def _u(s): return s

import hashlib
sha1_new = hashlib.sha1

class Algorithm(object):
	"""Abstract base class for algorithms.
	An algorithm knows how to generate a manifest from a directory tree.
	@ivar rating: how much we like this algorithm (higher is better)
	@type rating: int
	"""
	def generate_manifest(self, root):
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
	"""@deprecated: Injector versions before 0.20 only supported this algorithm."""

	rating = 10

	def generate_manifest(self, root):
		"""@type root: str"""
		def recurse(sub):
			# To ensure that a line-by-line comparison of the manifests
			# is possible, we require that filenames don't contain newlines.
			# Otherwise, you can name a file so that the part after the \n
			# would be interpreted as another line in the manifest.
			if '\n' in sub: raise BadDigest("Newline in filename '%s'" % sub)
			assert sub.startswith('/')

			if sub == '/.manifest': return

			full = os.path.join(root, sub[1:].replace('/', os.sep))
			info = os.lstat(full)
			
			m = info.st_mode
			if stat.S_ISDIR(m):
				if sub != '/':
					yield "D %s %s" % (int(info.st_mtime), sub)
				items = os.listdir(full)
				items.sort()
				subdir = sub
				if not subdir.endswith('/'):
					subdir += '/'
				for x in items:
					for y in recurse(subdir + x):
						yield y
				return

			assert sub[1:]
			leaf = os.path.basename(sub[1:])
			if stat.S_ISREG(m):
				with open(full, 'rb') as stream:
					d = sha1_new(stream.read()).hexdigest()		# XXX could be very large!
				if m & 0o111:
					yield "X %s %s %s %s" % (d, int(info.st_mtime), info.st_size, leaf)
				else:
					yield "F %s %s %s %s" % (d, int(info.st_mtime), info.st_size, leaf)
			elif stat.S_ISLNK(m):
				target = os.readlink(full).encode('utf-8')
				d = sha1_new(target).hexdigest()
				# Note: Can't use utime on symlinks, so skip mtime
				# Note: eCryptfs may report length as zero, so count ourselves instead
				yield "S %s %s %s" % (d, len(target), leaf)
			else:
				raise SafeException(_("Unknown object '%s' (not a file, directory or symlink)") %
						full)
		for x in recurse(_u('/')): yield x
	
	def new_digest(self):
		return sha1_new()

	def getID(self, digest):
		"""@rtype: str"""
		return 'sha1=' + digest.hexdigest()

def get_algorithm(name):
	"""Look-up an L{Algorithm} by name.
	@type name: str
	@rtype: L{Algorithm}
	@raise BadDigest: if the name is unknown."""
	try:
		return algorithms[name]
	except KeyError:
		raise BadDigest(_("Unknown algorithm '%s'") % name)

def generate_manifest(root, alg = 'sha1'):
	"""@type root: str
	@type alg: str
	@deprecated: use L{get_algorithm} and L{Algorithm.generate_manifest} instead."""
	return get_algorithm(alg).generate_manifest(root)
	
def add_manifest_file(dir, digest_or_alg):
	"""Writes a .manifest file into 'dir', and returns the digest.
	You should call fixup_permissions before this to ensure that the permissions are correct.
	On exit, dir itself has mode 555. Subdirectories are not changed.
	@param dir: root of the implementation
	@type dir: str
	@param digest_or_alg: should be an instance of Algorithm. Passing a digest here is deprecated.
	@type digest_or_alg: L{Algorithm}"""
	mfile = os.path.join(dir, '.manifest')
	if os.path.islink(mfile) or os.path.exists(mfile):
		raise SafeException(_("Directory '%s' already contains a .manifest file!") % dir)
	manifest = ''
	if isinstance(digest_or_alg, Algorithm):
		alg = digest_or_alg
		digest = alg.new_digest()
	else:
		digest = digest_or_alg
		alg = get_algorithm('sha1')
	for line in alg.generate_manifest(dir):
		manifest += line + '\n'
	manifest = manifest.encode('utf-8')
	digest.update(manifest)

	os.chmod(dir, 0o755)
	with open(mfile, 'wb') as stream:
		os.chmod(dir, 0o555)
		stream.write(manifest)
	os.chmod(mfile, 0o444)
	return digest

def _parse_manifest(manifest_data):
	"""Parse a manifest file.
	@param manifest_data: the contents of the manifest file
	@type manifest_data: str
	@return: a mapping from paths to information about that path
	@rtype: {str: tuple}"""
	wanted = {}
	dir = ''
	for line in manifest_data.split('\n'):
		if not line: break
		if line[0] == 'D':
			data = line.split(' ', 1)
			if len(data) != 2: raise BadDigest(_("Bad line '%s'") % line)
			path = data[-1]
			if not path.startswith('/'): raise BadDigest(_("Not absolute: '%s'") % line)
			path = path[1:]
			dir = path
		elif line[0] == 'S':
			data = line.split(' ', 3)
			path = os.path.join(dir, data[-1])
			if len(data) != 4: raise BadDigest(_("Bad line '%s'") % line)
		else:
			data = line.split(' ', 4)
			path = os.path.join(dir, data[-1])
			if len(data) != 5: raise BadDigest(_("Bad line '%s'") % line)
		if path in wanted:
			raise BadDigest(_('Duplicate entry "%s"') % line)
		wanted[path] = data[:-1]
	return wanted

class HashLibAlgorithm(Algorithm):
	new_digest = None		# Constructor for digest objects

	def __init__(self, name, rating, hash_name = None):
		"""@type name: str
		@type rating: int
		@type hash_name: str | None"""
		self.name = name
		self.new_digest = getattr(hashlib, hash_name or name)
		self.rating = rating

	def generate_manifest(self, root):
		"""@type root: str"""
		def recurse(sub):
			# To ensure that a line-by-line comparison of the manifests
			# is possible, we require that filenames don't contain newlines.
			# Otherwise, you can name a file so that the part after the \n
			# would be interpreted as another line in the manifest.
			if '\n' in sub: raise BadDigest(_("Newline in filename '%s'") % sub)
			assert sub.startswith('/')

			full = os.path.join(root, sub[1:])
			info = os.lstat(full)
			new_digest = self.new_digest
			
			m = info.st_mode
			if not stat.S_ISDIR(m): raise Exception(_('Not a directory: "%s"') % full)
			if sub != '/':
				yield "D %s" % sub
			items = os.listdir(full)
			items.sort()
			dirs = []
			for leaf in items:
				path = os.path.join(root, sub[1:], leaf)
				info = os.lstat(path)
				m = info.st_mode

				if stat.S_ISREG(m):
					if leaf == '.manifest': continue

					with open(path, 'rb') as stream:
						d = new_digest(stream.read()).hexdigest()
					if m & 0o111:
						yield "X %s %s %s %s" % (d, int(info.st_mtime), info.st_size, leaf)
					else:
						yield "F %s %s %s %s" % (d, int(info.st_mtime), info.st_size, leaf)
				elif stat.S_ISLNK(m):
					target = os.readlink(path).encode('utf-8')
					d = new_digest(target).hexdigest()
					# Note: Can't use utime on symlinks, so skip mtime
					# Note: eCryptfs may report length as zero, so count ourselves instead
					yield "S %s %s %s" % (d, len(target), leaf)
				elif stat.S_ISDIR(m):
					dirs.append(leaf)
				else:
					raise SafeException(_("Unknown object '%s' (not a file, directory or symlink)") %
							path)

			if not sub.endswith('/'):
				sub += '/'
			for x in dirs:
				# Note: "sub" is always Unix style. Don't use os.path.join here.
				for y in recurse(sub + x): yield y
			return

		for x in recurse(_u('/')): yield x

	def getID(self, digest):
		"""@rtype: str"""
		if self.name in ('sha1new', 'sha256'):
			digest_str = digest.hexdigest()
		else:
			# Base32-encode newer algorithms to make the digest shorter.
			# We can't use base64 as Windows is case insensitive.
			# There's no need for padding (and = characters in paths cause problems for some software).
			digest_str = base64.b32encode(digest.digest()).rstrip(b'=').decode('ascii')
		return format_algorithm_digest_pair(self.name, digest_str)

algorithms = {
	'sha1': OldSHA1(),
	'sha1new': HashLibAlgorithm('sha1new', 50, 'sha1'),
	'sha256': HashLibAlgorithm('sha256', 80),
	'sha256new': HashLibAlgorithm('sha256new', 90, 'sha256'),
}


def fixup_permissions(root):
	"""Set permissions recursively for children of root:
	 - If any X bit is set, they all must be.
	 - World readable, non-writable.
	@type root: str
	@raise Exception: if there are unsafe special bits set (setuid, etc)."""

	for main, dirs, files in os.walk(root):
		for x in ['.'] + files:
			full = os.path.join(main, x)

			raw_mode = os.lstat(full).st_mode
			if stat.S_ISLNK(raw_mode): continue

			mode = stat.S_IMODE(raw_mode)
			if mode & ~0o777:
				raise Exception(_("Unsafe mode: extracted file '%(filename)s' had special bits set in mode '%(mode)s'") % {'filename': full, 'mode': oct(mode)})
			if mode & 0o111:
				os.chmod(full, 0o555)
			else:
				os.chmod(full, 0o444)
