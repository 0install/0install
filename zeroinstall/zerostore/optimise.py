"""Optimise the cache."""

import os
from logging import warn

def _already_linked(a, b):
	ai = os.stat(a)
	bi = os.stat(b)
	return (ai.st_dev, ai.st_ino) == (bi.st_dev, bi.st_ino)

def _byte_identical(a, b):
	af = file(a, 'rb')
	bf = file(b, 'rb')
	while True:
		adata = af.read(100)
		bdata = bf.read(100)
		if adata != bdata:
			return False
		if not adata:
			return True

def _link(a, b, tmpfile):
	"""Keep 'a', delete 'b' and hard-link to 'a'"""
	if not _byte_identical(a, b):
		warn("Files should be identical, but they're not!\n%s\n%s", a, b)

	os.link(a, tmpfile)
	try:
		os.rename(tmpfile, b)
	except:
		os.unlink(tmpfile)
		raise

def optimise(impl_dir):
	"""Scan an implementation cache directory for duplicate files, and
	hard-link any duplicates together to save space.
	@param impl_dir: a $cache/0install.net/implementations directory
	@type impl_dir: str
	@param verbose: display progress messages
	@type verbose: bool
	@return: (unique bytes, duplicated bytes, already_linked)
	@rtype: (int, int, int)"""

	first_copy = {}		# TypeDigest -> Path
	dup_size = uniq_size = already_linked = 0

	import random

	for x in range(10):
		tmpfile = os.path.join(impl_dir, 'optimise-%d' % random.randint(0, 1000000))
		if not os.path.exists(tmpfile):
			break
	else:
		raise Exception("Can't generate unused tempfile name!")

	for impl in os.listdir(impl_dir):
		if impl.startswith('.') or '=' not in impl:
			warn("Skipping non-implementation '%s'", impl)
			continue
		manifest_path = os.path.join(impl_dir, impl, '.manifest')
		try:
			ms = file(manifest_path)
		except OSError, ex:
			warn("Failed to read manifest file '%s': %s", manifest_path, str(ex))
			continue

		alg = impl.split('=', 1)[0]
		if alg == 'sha1': continue

		dir = ""
		for line in ms:
			if line[0] == 'D':
				type, path = line.split(' ', 1)
				assert path.startswith('/')
				dir = path[1:-1]	# Strip slash and newline
				continue

			if line[0] not in "FX": continue

			type, digest, mtime, size, path = line.split(' ', 4)
			path = path[:-1]	# Strip newline
			size = long(size)

			key = (type, digest, mtime, size)
			loc_path = (impl, dir, path)

			first_loc = first_copy.get(key, None)
			if first_loc:
				first_full = os.path.join(impl_dir, *first_loc)
				new_full = os.path.join(impl_dir, *loc_path)
				if _already_linked(first_full, new_full):
					already_linked += size
				else:
					_link(first_full, new_full, tmpfile)
					dup_size += size
			else:
				first_copy[key] = loc_path
				uniq_size += size
	return (uniq_size, dup_size, already_linked)
