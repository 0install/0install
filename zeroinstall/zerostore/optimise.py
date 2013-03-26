"""Optimise the cache."""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _, logger
import os, sys

def _already_linked(a, b):
	"""@type a: str
	@type b: str
	@rtype: bool"""
	ai = os.stat(a)
	bi = os.stat(b)
	return (ai.st_dev, ai.st_ino) == (bi.st_dev, bi.st_ino)

def _byte_identical(a, b):
	"""@type a: str
	@type b: str
	@rtype: bool"""
	with open(a, 'rb') as af:
		with open(b, 'rb') as bf:
			while True:
				adata = af.read(100)
				bdata = bf.read(100)
				if adata != bdata:
					return False
				if not adata:
					return True

def _link(a, b, tmpfile):
	"""Keep 'a', delete 'b' and hard-link to 'a'
	@type a: str
	@type b: str
	@type tmpfile: str"""
	if not _byte_identical(a, b):
		logger.warning(_("Files should be identical, but they're not!\n%(file_a)s\n%(file_b)s"), {'file_a': a, 'file_b': b})

	b_dir = os.path.dirname(b)
	old_mode = os.lstat(b_dir).st_mode
	os.chmod(b_dir, old_mode | 0o200)	# Need write access briefly
	try:
		os.link(a, tmpfile)
		try:
			os.rename(tmpfile, b)
		except:
			os.unlink(tmpfile)
			raise
	finally:
		os.chmod(b_dir, old_mode)

def optimise(impl_dir):
	"""Scan an implementation cache directory for duplicate files, and
	hard-link any duplicates together to save space.
	@param impl_dir: a $cache/0install.net/implementations directory
	@type impl_dir: str
	@return: (unique bytes, duplicated bytes, already linked, manifest size)
	@rtype: (int, int, int, int)"""

	first_copy = {}		# TypeDigest -> Path
	dup_size = uniq_size = already_linked = man_size = 0

	import random
	from zeroinstall.zerostore import BadDigest, parse_algorithm_digest_pair

	for x in range(10):
		tmpfile = os.path.join(impl_dir, 'optimise-%d' % random.randint(0, 1000000))
		if not os.path.exists(tmpfile):
			break
	else:
		raise Exception(_("Can't generate unused tempfile name!"))

	dirs = os.listdir(impl_dir)
	total = len(dirs)
	msg = ""
	def clear():
		print("\r" + (" " * len(msg)) + "\r", end='')
	for i, impl in enumerate(dirs):
		clear()
		msg = _("[%(done)d / %(total)d] Reading manifests...") % {'done': i, 'total': total}
		print(msg, end='')
		sys.stdout.flush()

		try:
			alg, manifest_digest = parse_algorithm_digest_pair(impl)
		except BadDigest:
			logger.warning(_("Skipping non-implementation '%s'"), impl)
			continue
		manifest_path = os.path.join(impl_dir, impl, '.manifest')
		try:
			ms = open(manifest_path, 'rt')
		except OSError as ex:
			logger.warning(_("Failed to read manifest file '%(manifest_path)s': %(exception)s"), {'manifest': manifest_path, 'exception': str(ex)})
			continue

		if alg == 'sha1':
			ms.close()
			continue

		man_size += os.path.getsize(manifest_path)

		dir = ""
		for line in ms:
			if line[0] == 'D':
				itype, path = line.split(' ', 1)
				assert path.startswith('/')
				dir = path[1:-1]	# Strip slash and newline
				continue

			if line[0] == "S":
				itype, digest, size, rest = line.split(' ', 3)
				uniq_size += int(size)
				continue

			assert line[0] in "FX"

			itype, digest, mtime, size, path = line.split(' ', 4)
			path = path[:-1]	# Strip newline
			size = int(size)

			key = (itype, digest, mtime, size)
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

		ms.close()
	clear()
	return (uniq_size, dup_size, already_linked, man_size)
