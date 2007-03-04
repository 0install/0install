"""Code for the B{0store} command-line interface."""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys, os
from zeroinstall.zerostore.manifest import generate_manifest, verify, get_algorithm, copy_tree_with_verify
from zeroinstall import zerostore, SafeException

stores = None

def init_stores():
	global stores
	assert stores is None
	if stores is None:
		stores = zerostore.Stores()

class UsageError(SafeException): pass

def do_manifest(args):
	"""manifest DIRECTORY [ALGORITHM]"""
	if len(args) < 1 or len(args) > 2: raise UsageError("Wrong number of arguments")
	if len(args) == 2:
		alg = get_algorithm(args[1])
	else:
		# If no algorithm was given, guess from the directory name
		name = os.path.basename(args[0])
		if '=' in name:
			alg = get_algorithm(name.split('=', 1)[0])
		else:
			alg = get_algorithm('sha1')
	digest = alg.new_digest()
	for line in alg.generate_manifest(args[0]):
		print line
		digest.update(line + '\n')
	print alg.getID(digest)
	sys.exit(0)

def do_find(args):
	"""find DIGEST"""
	if len(args) != 1: raise UsageError("Wrong number of arguments")
	try:
		print stores.lookup(args[0])
		sys.exit(0)
	except zerostore.BadDigest, ex:
		print >>sys.stderr, ex
	except zerostore.NotStored, ex:
		print >>sys.stderr, ex
	sys.exit(1)

def do_add(args):
	"""add DIGEST (DIRECTORY | (ARCHIVE [EXTRACT]))"""
	from zeroinstall.zerostore import unpack
	if len(args) < 2: raise UsageError("Missing arguments")
	digest = args[0]
	if os.path.isdir(args[1]):
		if len(args) > 2: raise UsageError("Too many arguments")
		stores.add_dir_to_cache(digest, args[1])
	elif os.path.isfile(args[1]):
		if len(args) > 3: raise UsageError("Too many arguments")
		if len(args) > 2:
			extract = args[2]
		else:
			extract = None

		type = unpack.type_from_url(args[1])
		if not type:
			raise SafeException("Unknown extension in '%s' - can't guess MIME type" % args[1])
		unpack.check_type_ok(type)

		stores.add_archive_to_cache(digest, file(args[1]), args[1], extract, type = type)
	else:
		try:
			os.stat(args[1])
		except OSError, ex:
			if ex.errno != 2:			# No such file or directory
				raise UsageError(str(ex))	# E.g. permission denied
		raise UsageError("No such file or directory '%s'" % args[1])

def do_optimise(args):
	"""optimise [ CACHE ]"""
	if len(args) == 1:
		cache_dir = args[0]
	else:
		cache_dir = stores.stores[0].dir
	
	cache_dir = os.path.realpath(cache_dir)

	import stat
	info = os.stat(cache_dir)
	if not stat.S_ISDIR(info.st_mode):
		raise UsageError("Not a directory: '%s'" % cache_dir)

	impl_name = os.path.basename(cache_dir)
	if impl_name != 'implementations':
		raise UsageError("Cache directory should be named 'implementations', not\n"
				"'%s' (in '%s')" % (impl_name, cache_dir))

	print "Optimising", cache_dir

	def _pretty_size(size):
		if size is None:
			return '?'
		if size < 2048:
			return '%d bytes' % size
		size = float(size)
		for unit in ('Kb', 'Mb', 'Gb', 'Tb'):
			size /= 1024
			if size < 2048:
				break
		return '%.1f %s' % (size, unit)

	import optimise
	uniq_size, dup_size, already_linked, man_size = optimise.optimise(cache_dir)
	print "Original size  :", _pretty_size(uniq_size + dup_size) + " (excluding the %s of manifests)" % _pretty_size(man_size)
	print "Already saved  :", _pretty_size(already_linked)
	if dup_size == 0:
		print "No duplicates found; no changes made."
	else:
		print "Optimised size :", _pretty_size(uniq_size)
		perc = (100 * float(dup_size)) / (uniq_size + dup_size)
		print "Space freed up :", _pretty_size(dup_size), "(%.2f%%)" % perc
	print "Optimisation complete."

def do_verify(args):
	"""verify (DIGEST | (DIRECTORY [DIGEST])"""
	if len(args) == 2:
		required_digest = args[1]
		root = args[0]
	elif len(args) == 1:
		root = get_stored(args[0])
		required_digest = None		# Get from name
	else:
	     raise UsageError("Missing DIGEST or DIRECTORY")

	print "Verifying", root
	try:
		verify(root, required_digest)
		print "OK"
	except zerostore.BadDigest, ex:
		print str(ex)
		if ex.detail:
			print
			print ex.detail
			sys.exit(1)

def show_changes(actual, saved):
	import difflib
	for line in difflib.unified_diff(saved, actual, 'Recorded', 'Actual'):
		print line,

def do_list(args):
	"""list"""
	if args: raise UsageError("List takes no arguments")
	print "User store (writable) : " + stores.stores[0].dir
	for s in stores.stores[1:]:
		print "System store          : " + s.dir
	if len(stores.stores) < 2:
		print "No system stores."

def get_stored(dir_or_digest):
	if os.path.isdir(dir_or_digest):
		return dir_or_digest
	else:
		try:
			return stores.lookup(dir_or_digest)
		except zerostore.NotStored, ex:
			print >>sys.stderr, ex
		sys.exit(1)

def do_copy(args):
	"""copy SOURCE [ TARGET ]"""
	if len(args) == 2:
		source, target = args
	elif len(args) == 1:
		source = args[0]
		target = stores.stores[0].dir
	else:
		raise UsageError("Wrong number of arguments.")

	if not os.path.isdir(source):
		raise UsageError("Source directory '%s' not found" % source)
	if not os.path.isdir(target):
		raise UsageError("Target directory '%s' not found" % target)
	manifest_path = os.path.join(source, '.manifest')
	if not os.path.isfile(manifest_path):
		raise UsageError("Source manifest '%s' not found" % manifest_path)
	required_digest = os.path.basename(source)
	manifest_data = file(manifest_path).read()

	copy_tree_with_verify(source, target, manifest_data, required_digest)

commands = [do_add, do_copy, do_find, do_list, do_manifest, do_optimise, do_verify]
