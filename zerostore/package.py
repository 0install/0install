from __future__ import generators
import os, stat

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
of the manifest."""

def generate_manifest(root, sub = '/'):
	# To ensure that a line-by-line comparison of the manifests
	# is possible, we require that filenames don't contain newlines.
	# Otherwise, you can name a file so that the part after the \n
	# would be interpreted as another line in the manifest.
	assert '\n' not in sub
	assert sub.startswith('/')

	full = os.path.join(root, sub[1:])
	info = os.lstat(full)
	
	m = info.st_mode
	if stat.S_ISDIR(m):
		yield "D %s %s" % (info.st_mtime, sub)
		items = os.listdir(full)
		items.sort()
		for x in items:
			for y in generate_manifest(root, os.path.join(sub, x)):
				yield y
		return

	assert sub[1:]
	leaf = os.path.basename(sub[1:])
	if stat.S_ISREG(m):
		if m & 0111:
			yield "X %s %s %s" % (info.st_mtime,info.st_size, leaf)
		else:
			yield "F %s %s %s" % (info.st_mtime,info.st_size, leaf)
	else:
		print "Unknown object", full


for line in generate_manifest('/home/talex/tmp/lazyfs-linux-0.1.24'):
	print line
