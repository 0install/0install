# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import generators
import os, stat
from sets import Set
import sha
from zeroinstall import SafeException
from zeroinstall.zerostore import BadDigest

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
			if '\n' in sub: raise BadDigest("Newline in filename '%s'" % sub)
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
	try:
		return algorithms[name]
	except KeyError:
		raise BadDigest("Unknown algorithm '%s'" % name)

def generate_manifest(root, alg = 'sha1'):
	return get_algorithm(alg).generate_manifest(root)
	
def add_manifest_file(dir, digest_or_alg):
	"""Writes a .manifest file into 'dir', and returns the digest.
	Second argument should be an instance of Algorithm. Passing a digest
	here is deprecated."""
	mfile = os.path.join(dir, '.manifest')
	if os.path.islink(mfile) or os.path.exists(mfile):
		raise SafeException("Directory '%s' already contains a .manifest file!" % dir)
	manifest = ''
	if isinstance(digest_or_alg, Algorithm):
		alg = digest_or_alg
		digest = alg.new_digest()
	else:
		digest = digest_or_alg
		alg = get_algorithm('sha1')
	for line in alg.generate_manifest(dir):
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
		raise BadDigest("Digest '%s' is not in the form 'algorithm=value'" % id)
	return (get_algorithm(parts[0]), parts[1])

def copy_with_verify(src, dest, mode, alg, required_digest):
	"""Copy path src to dest, checking that the contents give the right digest.
	dest must not exist. New file is created with a mode of 'mode & umask'."""
	src_obj = file(src)
	dest_fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
	digest = alg.new_digest()
	while True:
		data = src_obj.read(256)
		if not data: break
		digest.update(data)
		while data:
			written = os.write(dest_fd, data)
			assert written >= 0
			data = data[written:]
	actual = digest.hexdigest()
	if actual == required_digest: return
	os.unlink(dest)
	raise BadDigest(("Copy failed: file '%s' has wrong digest (may have been tampered with)\n"
			 "Excepted: %s\n"
			 "Actual:   %s") % (src, required_digest, actual))

def verify(root, required_digest = None):
	"""Ensure that directory 'dir' generates the given digest.
	Raises BadDigest if not. For a non-error return:
	- Dir's name must be a digest (in the form "alg=value")
	- The calculated digest of the contents must match this name.
	- If there is a .manifest file, then its digest must also match."""
	if required_digest is None:
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

# XXX: Be more careful about the source tree changing under us. In particular, what happens if:
# - A regualar file suddenly turns into a symlink?
# - We find a device file (users can hard-link them if on the same device)
def copy_tree_with_verify(source, target, manifest_data, required_digest):
	"""Copy directory source to be a subdirectory of target if it matches the required_digest.
	manifest_data is normally source/.manifest. source and manifest_data are not trusted
	(will typically be under the control of another user).
	The copy is first done to a temporary directory in target, then renamed to the final name
	only if correct. Therefore, an invalid 'target/required_digest' will never exist.
	A successful return means than target/required_digest now exists (whether we created it or not)."""
	import tempfile, shutil
	from logging import info

	alg, digest_value = splitID(required_digest)

	if isinstance(alg, OldSHA1):
		raise SafeException("Sorry, the 'sha1' algorithm does not support copying.")

	digest = alg.new_digest()
	digest.update(manifest_data)
	manifest_digest = alg.getID(digest)

	if manifest_digest != required_digest:
		raise zerostore.BadDigest("Manifest has been tampered with!\n"
				"Manifest digest: " + manifest_digest + "\n"
				"Directory name : " + required_digest)

	target_impl = os.path.join(target, required_digest)
	if os.path.isdir(target_impl):
		info("Target directory '%s' already exists", target_impl)
		return

	# We've checked that the source's manifest matches required_digest, so it
	# is what we want. Make a list of all the files we need to copy...

	wanted = _parse_manifest(manifest_data)

	tmpdir = tempfile.mkdtemp(prefix = 'tmp-copy-', dir = target)

	try:
		_copy_files(alg, wanted, source, tmpdir)

		if wanted:
			raise SafeException('Copy failed; files missing from source:\n- ' +
					    '\n- '.join(wanted.keys()))

		# Check that the copy is correct
		actual_digest = alg.getID(add_manifest_file(tmpdir, alg))
		if actual_digest != required_digest:
			raise SafeException(("Copy failed; double-check of target gave the wrong digest.\n"
					     "Unless the target was modified during the copy, this is a BUG\n"
					     "in 0store and should be reported.\n"
					     "Expected: %s\n"
					     "Actual:   %s") % (required_digest, actual_digest)) 
		os.rename(tmpdir, target_impl)
		# TODO: catch already-exists, delete tmpdir and return success
	except:
		info("Deleting tmpdir '%s'" % tmpdir)
		shutil.rmtree(tmpdir)
		raise

def _parse_manifest(manifest_data):
	wanted = {}	# Path -> (manifest line tuple)
	dir = ''
	for line in manifest_data.split('\n'):
		if not line: break
		if line[0] == 'D':
			data = line.split(' ', 1)
			if len(data) != 2: raise zerostore.BadDigest("Bad line '%s'" % line)
			path = data[-1]
			if not path.startswith('/'): raise zerostore.BadDigest("Not absolute: '%s'" % line)
			path = path[1:]
			dir = path
		elif line[0] == 'S':
			data = line.split(' ', 3)
			path = os.path.join(dir, data[-1])
			if len(data) != 4: raise zerostore.BadDigest("Bad line '%s'" % line)
		else:
			data = line.split(' ', 4)
			path = os.path.join(dir, data[-1])
			if len(data) != 5: raise zerostore.BadDigest("Bad line '%s'" % line)
		if path in wanted:
			raise zerostore.BadDigest('Duplicate entry "%s"' % line)
		wanted[path] = data[:-1]
	return wanted

def _copy_files(alg, wanted, source, target):
	"""Scan for files under 'source'. For each one:
	If it is in wanted and has the right details (or they can be fixed; e.g. mtime),
	then copy it into 'target'.
	If it's not in wanted, warn and skip it.
	On exit, wanted contains only files that were not found."""
	from logging import warn
	dir = ''
	for line in alg.generate_manifest(source):
		if line[0] == 'D':
			type, name = line.split(' ', 1)
			assert name.startswith('/')
			dir = name[1:]
			path = dir
		elif line[0] == 'S':
			type, actual_digest, actual_size, name = line.split(' ', 3)
			path = os.path.join(dir, name)
		else:
			assert line[0] in 'XF'
			type, actual_digest, actual_mtime, actual_size, name = line.split(' ', 4)
			path = os.path.join(dir, name)
		try:
			required_details = wanted.pop(path)
		except KeyError:
			warn("Skipping file not in manifest: '%s'", path)
			continue
		if required_details[0] != type:
			raise zerostore.BadDigest("Item '%s' has wrong type!" % path)
		if type == 'D':
			os.mkdir(os.path.join(target, path))
		elif type in 'XF':
			required_type, required_digest, required_mtime, required_size = required_details
			if required_size != actual_size:
				raise SafeException("File '%s' has wrong size (%s bytes, but should be "
						    "%s according to manifest)" %
						    (path, actual_size, required_size))
			required_mtime = int(required_mtime)
			dest_path = os.path.join(target, path)
			if type == 'X':
				mode = 0555
			else:
				mode = 0444
			copy_with_verify(os.path.join(source, path),
					dest_path,
					mode,
					alg,
					required_digest)
			os.utime(dest_path, (required_mtime, required_mtime))
		elif type == 'S':
			required_type, required_digest, required_size = required_details
			if required_size != actual_size:
				raise SafeException("Symlink '%s' has wrong size (%s bytes, but should be "
						    "%s according to manifest)" %
						    (path, actual_size, required_size))
			symlink_target = os.readlink(os.path.join(source, path))
			symlink_digest = alg.new_digest()
			symlink_digest.update(symlink_target)
			if symlink_digest.hexdigest() != required_digest:
				raise SafeException("Symlink '%s' has wrong target (digest should be "
						"%s according to manifest)" % (path, required_digest))
			dest_path = os.path.join(target, path)
			os.symlink(symlink_target, dest_path)
		else:
			raise SafeException("Unknown manifest type %s for '%s'" % (type, path))

class HashLibAlgorithm(Algorithm):
	new_digest = None		# Constructor for digest objects

	def __init__(self, name):
		if name == 'sha1':
			import sha
			self.new_digest = sha.new
			self.name = 'sha1new'
		else:
			self.new_digest = getattr(hashlib, name)
			self.name = name

	def generate_manifest(self, root):
		def recurse(sub):
			# To ensure that a line-by-line comparison of the manifests
			# is possible, we require that filenames don't contain newlines.
			# Otherwise, you can name a file so that the part after the \n
			# would be interpreted as another line in the manifest.
			if '\n' in sub: raise BadDigest("Newline in filename '%s'" % sub)
			assert sub.startswith('/')

			full = os.path.join(root, sub[1:])
			info = os.lstat(full)
			new_digest = self.new_digest
			
			m = info.st_mode
			if not stat.S_ISDIR(m): raise Exception('Not a directory: "%s"' % full)
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

					d = new_digest(file(path).read()).hexdigest()
					if m & 0111:
						yield "X %s %s %s %s" % (d, info.st_mtime,info.st_size, leaf)
					else:
						yield "F %s %s %s %s" % (d, info.st_mtime,info.st_size, leaf)
				elif stat.S_ISLNK(m):
					d = new_digest(os.readlink(path)).hexdigest()
					# Note: Can't use utime on symlinks, so skip mtime
					yield "S %s %s %s" % (d, info.st_size, leaf)
				elif stat.S_ISDIR(m):
					dirs.append(leaf)
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
