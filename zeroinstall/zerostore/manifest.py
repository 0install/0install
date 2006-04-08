# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import generators
import os, stat
from sets import Set
import sha
from zeroinstall import SafeException

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

def generate_manifest(root):
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
	
def add_manifest_file(dir, digest):
	"""Writes a .manifest file into 'dir', and updates digest."""
	mfile = os.path.join(dir, '.manifest')
	if os.path.islink(mfile) or os.path.exists(mfile):
		raise Exception('Archive contains a .manifest file!')
	manifest = ''
	for line in generate_manifest(dir):
		manifest += line + '\n'
	digest.update(manifest)
	stream = file(mfile, 'w')
	stream.write(manifest)
	stream.close()
	return digest

def verify(root):
	"""Ensure that directory 'dir' generates the given digest.
	Raises BadDigest if not. For a non-error return:
	- Dir's name must be a digest (in the form "alg=value")
	- The calculated digest of the contents must match this name.
	- If there is a .manifest file, then its digest must also match."""
	import sha
	from zeroinstall.zerostore import BadDigest
	
	required_digest = os.path.basename(root)
	if not required_digest.startswith('sha1='):
		raise BadDigest("Directory name '%s' does not start with 'sha1='" %
			required_digest)

	digest = sha.new()
	lines = []
	for line in generate_manifest(root):
		line += '\n'
		digest.update(line)
		lines.append(line)
	actual_digest = 'sha1=' + digest.hexdigest()

	manifest_file = os.path.join(root, '.manifest')
	if os.path.isfile(manifest_file):
		digest = sha.new()
		digest.update(file(manifest_file).read())
		manifest_digest = 'sha1=' + digest.hexdigest()
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

