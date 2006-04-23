# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys, os, sha, tempfile, shutil
from logging import warn
from zeroinstall.zerostore.manifest import generate_manifest, verify
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
		alg = get_algorithm(args[2])
	else:
		# If no algorithm was given, guess from the directory name
		name = os.path.basename(args[0])
		if '=' in name:
			alg = get_algorithm(name.split('=', 1)[0])
		else:
			alg = get_algorithm('sha1')
	digest = alg.new_digest()
	for line in generate_manifest(args[0]):
		print line
		digest.update(line + '\n')
	print alg.toID(digest)
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
	"""add DIGEST (DIRECTORY | (ARCHIVE [EXTRACT])"""
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
		stores.add_archive_to_cache(digest, file(args[1]), args[1], extract)
	else:
		raise UsageError("No such file or directory '%s'" % args[1])

def do_verify(args):
	"""verify (DIGEST | DIRECTORY)"""
	if len(args) != 1: raise UsageError("Missing DIGEST or DIRECTORY")
	root = get_stored(args[0])

	print "Verifying", root
	try:
		verify(root)
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

commands = [do_add, do_find, do_list, do_manifest, do_verify]
