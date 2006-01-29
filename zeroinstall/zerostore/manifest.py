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
