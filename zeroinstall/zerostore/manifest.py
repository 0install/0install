
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


import os, stat
from zeroinstall import SafeException, _
from zeroinstall.zerostore import BadDigest

try:
	import hashlib
	sha1_new = hashlib.sha1
except:
	import sha
	sha1_new = sha.new
	hashlib = None

class Algorithm:
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
				d = sha1_new(file(full).read()).hexdigest()
				if m & 0111:
					yield "X %s %s %s %s" % (d, int(info.st_mtime) ,info.st_size, leaf)
				else:
					yield "F %s %s %s %s" % (d, int(info.st_mtime) ,info.st_size, leaf)
			elif stat.S_ISLNK(m):
				target = os.readlink(full)
				d = sha1_new(target).hexdigest()
				# Note: Can't use utime on symlinks, so skip mtime
				# Note: eCryptfs may report length as zero, so count ourselves instead
				yield "S %s %s %s" % (d, len(target), leaf)
			else:
				raise SafeException(_("Unknown object '%s' (not a file, directory or symlink)") %
						full)
		for x in recurse('/'): yield x
	
	def new_digest(self):
		return sha1_new()

	def getID(self, digest):
		return 'sha1=' + digest.hexdigest()

def get_algorithm(name):
	"""Look-up an L{Algorithm} by name.
	@raise BadDigest: if the name is unknown."""
	try:
		return algorithms[name]
	except KeyError:
		raise BadDigest(_("Unknown algorithm '%s'") % name)

def generate_manifest(root, alg = 'sha1'):
	"""@deprecated: use L{get_algorithm} and L{Algorithm.generate_manifest} instead."""
	return get_algorithm(alg).generate_manifest(root)
	
def add_manifest_file(dir, digest_or_alg):
	"""Writes a .manifest file into 'dir', and returns the digest.
	You should call fixup_permissions before this to ensure that the permissions are correct.
	On exit, dir itself has mode 555. Subdirectories are not changed.
	@param dir: root of the implementation
	@param digest_or_alg: should be an instance of Algorithm. Passing a digest
	here is deprecated."""
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
	digest.update(manifest)

	os.chmod(dir, 0755)
	stream = file(mfile, 'wb')
	os.chmod(dir, 0555)
	stream.write(manifest)
	stream.close()
	os.chmod(mfile, 0444)
	return digest

def splitID(id):
	"""Take an ID in the form 'alg=value' and return a tuple (alg, value),
	where 'alg' is an instance of Algorithm and 'value' is a string.
	@raise BadDigest: if the algorithm isn't known or the ID has the wrong format."""
	parts = id.split('=', 1)
	if len(parts) != 2:
		raise BadDigest(_("Digest '%s' is not in the form 'algorithm=value'") % id)
	return (get_algorithm(parts[0]), parts[1])

def copy_with_verify(src, dest, mode, alg, required_digest):
	"""Copy path src to dest, checking that the contents give the right digest.
	dest must not exist. New file is created with a mode of 'mode & umask'.
	@param src: source filename
	@type src: str
	@param dest: target filename
	@type dest: str
	@param mode: target mode
	@type mode: int
	@param alg: algorithm to generate digest
	@type alg: L{Algorithm}
	@param required_digest: expected digest value
	@type required_digest: str
	@raise BadDigest: the contents of the file don't match required_digest"""
	src_obj = file(src)
	dest_fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
	try:
		digest = alg.new_digest()
		while True:
			data = src_obj.read(256)
			if not data: break
			digest.update(data)
			while data:
				written = os.write(dest_fd, data)
				assert written >= 0
				data = data[written:]
	finally:
		os.close(dest_fd)
		src_obj.close()
	actual = digest.hexdigest()
	if actual == required_digest: return
	os.unlink(dest)
	raise BadDigest(_("Copy failed: file '%(src)s' has wrong digest (may have been tampered with)\n"
			 "Expected: %(required_digest)s\n"
			 "Actual:   %(actual_digest)s") % {'src': src, 'required_digest': required_digest, 'actual_digest': actual})

def verify(root, required_digest = None):
	"""Ensure that directory 'dir' generates the given digest.
	For a non-error return:
	 - Dir's name must be a digest (in the form "alg=value")
	 - The calculated digest of the contents must match this name.
	 - If there is a .manifest file, then its digest must also match.
	@raise BadDigest: if verification fails."""
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
		digest.update(file(manifest_file, 'rb').read())
		manifest_digest = alg.getID(digest)
	else:
		manifest_digest = None

	if required_digest == actual_digest == manifest_digest:
		return

	error = BadDigest(_("Cached item does NOT verify."))
	
	error.detail = _(" Expected: %(required_digest)s\n"
					 "   Actual: %(actual_digest)s\n"
					 ".manifest digest: %(manifest_digest)s\n\n") \
					 % {'required_digest': required_digest, 'actual_digest': actual_digest, 'manifest_digest': manifest_digest or _('No .manifest file')}

	if manifest_digest is None:
		error.detail += _("No .manifest, so no further details available.")
	elif manifest_digest == actual_digest:
		error.detail += _("The .manifest file matches the actual contents. Very strange!")
	elif manifest_digest == required_digest:
		import difflib
		diff = difflib.unified_diff(file(manifest_file, 'rb').readlines(), lines,
					    'Recorded', 'Actual')
		error.detail += _("The .manifest file matches the directory name.\n" \
				"The contents of the directory have changed:\n") + \
				''.join(diff)
	elif required_digest == actual_digest:
		error.detail += _("The directory contents are correct, but the .manifest file is wrong!")
	else:
		error.detail += _("The .manifest file matches neither of the other digests. Odd.")
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
	import tempfile
	from logging import info

	alg, digest_value = splitID(required_digest)

	if isinstance(alg, OldSHA1):
		raise SafeException(_("Sorry, the 'sha1' algorithm does not support copying."))

	digest = alg.new_digest()
	digest.update(manifest_data)
	manifest_digest = alg.getID(digest)

	if manifest_digest != required_digest:
		raise BadDigest(_("Manifest has been tampered with!\n"
						  "Manifest digest: %(actual_digest)s\n"
						  "Directory name : %(required_digest)s")
						% {'actual_digest': manifest_digest, 'required_digest': required_digest})

	target_impl = os.path.join(target, required_digest)
	if os.path.isdir(target_impl):
		info(_("Target directory '%s' already exists"), target_impl)
		return

	# We've checked that the source's manifest matches required_digest, so it
	# is what we want. Make a list of all the files we need to copy...

	wanted = _parse_manifest(manifest_data)

	tmpdir = tempfile.mkdtemp(prefix = 'tmp-copy-', dir = target)
	try:
		_copy_files(alg, wanted, source, tmpdir)

		if wanted:
			raise SafeException(_('Copy failed; files missing from source:') + '\n- ' +
					    '\n- '.join(wanted.keys()))

		# Make directories read-only (files are already RO)
		for root, dirs, files in os.walk(tmpdir):
			for d in dirs:
				path = os.path.join(root, d)
				mode = os.stat(path).st_mode
				os.chmod(path, mode & 0555)

		# Check that the copy is correct
		actual_digest = alg.getID(add_manifest_file(tmpdir, alg))
		if actual_digest != required_digest:
			raise SafeException(_("Copy failed; double-check of target gave the wrong digest.\n"
					     "Unless the target was modified during the copy, this is a BUG\n"
					     "in 0store and should be reported.\n"
					     "Expected: %(required_digest)s\n"
					     "Actual:   %(actual_digest)s") % {'required_digest': required_digest, 'actual_digest': actual_digest})
		os.rename(tmpdir, target_impl)
		# TODO: catch already-exists, delete tmpdir and return success
	except:
		info(_("Deleting tmpdir '%s'") % tmpdir)
		from zeroinstall.support import ro_rmtree
		ro_rmtree(tmpdir)
		raise

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
			warn(_("Skipping file not in manifest: '%s'"), path)
			continue
		if required_details[0] != type:
			raise BadDigest(_("Item '%s' has wrong type!") % path)
		if type == 'D':
			os.mkdir(os.path.join(target, path))
		elif type in 'XF':
			required_type, required_digest, required_mtime, required_size = required_details
			if required_size != actual_size:
				raise SafeException(_("File '%(path)s' has wrong size (%(actual_size)s bytes, but should be "
						    "%(required_size)s according to manifest)") %
						    {'path': path, 'actual_size': actual_size, 'required_size': required_size})
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
				raise SafeException(_("Symlink '%(path)s' has wrong size (%(actual_size)s bytes, but should be "
						    "%(required_size)s according to manifest)") %
						    {'path': path, 'actual_size': actual_size, 'required_size': required_size})
			symlink_target = os.readlink(os.path.join(source, path))
			symlink_digest = alg.new_digest()
			symlink_digest.update(symlink_target)
			if symlink_digest.hexdigest() != required_digest:
				raise SafeException(_("Symlink '%(path)s' has wrong target (digest should be "
						"%(digest)s according to manifest)") % {'path': path, 'digest': required_digest})
			dest_path = os.path.join(target, path)
			os.symlink(symlink_target, dest_path)
		else:
			raise SafeException(_("Unknown manifest type %(type)s for '%(path)s'") % {'type': type, 'path': path})

class HashLibAlgorithm(Algorithm):
	new_digest = None		# Constructor for digest objects

	def __init__(self, name, rating):
		if name == 'sha1':
			self.new_digest = sha1_new
			self.name = 'sha1new'
		else:
			self.new_digest = getattr(hashlib, name)
			self.name = name
		self.rating = rating

	def generate_manifest(self, root):
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

					d = new_digest(file(path).read()).hexdigest()
					if m & 0111:
						yield "X %s %s %s %s" % (d, int(info.st_mtime), info.st_size, leaf)
					else:
						yield "F %s %s %s %s" % (d, int(info.st_mtime), info.st_size, leaf)
				elif stat.S_ISLNK(m):
					target = os.readlink(path)
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

		for x in recurse('/'): yield x

	def getID(self, digest):
		return self.name + '=' + digest.hexdigest()

algorithms = {
	'sha1': OldSHA1(),
	'sha1new': HashLibAlgorithm('sha1', 50),
}

if hashlib is not None:
	algorithms['sha256'] = HashLibAlgorithm('sha256', 80)

def fixup_permissions(root):
	"""Set permissions recursively for children of root:
	 - If any X bit is set, they all must be.
	 - World readable, non-writable.
	@raise Exception: if there are unsafe special bits set (setuid, etc)."""

	for main, dirs, files in os.walk(root):
		for x in ['.'] + files:
			full = os.path.join(main, x)

			raw_mode = os.lstat(full).st_mode
			if stat.S_ISLNK(raw_mode): continue

			mode = stat.S_IMODE(raw_mode)
			if mode & ~0777:
				raise Exception(_("Unsafe mode: extracted file '%(filename)s' had special bits set in mode '%(mode)s'") % {'filename': full, 'mode': oct(mode)})
			if mode & 0111:
				os.chmod(full, 0555)
			else:
				os.chmod(full, 0444)
