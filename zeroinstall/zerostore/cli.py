import sys, os, sha
from zeroinstall.zerostore.manifest import generate_manifest
from zeroinstall import zerostore

stores = None

def init_stores():
	global stores
	assert stores is None
	if stores is None:
		stores = zerostore.Stores()

class UsageError(Exception): pass

def do_manifest(args):
	"""manifest DIRECTORY"""
	if len(args) != 1: raise UsageError("Wrong number of arguments")
	import sha
	digest = sha.new()
	for line in generate_manifest(args[0]):
		print line
		digest.update(line + '\n')
	print "sha1=" + digest.hexdigest()
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

	required_digest = os.path.basename(args[0])
	if not required_digest.startswith('sha1='):
		raise zerostore.BadDigest("Directory name '%s' does not start with 'sha1='" %
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

	print
	if required_digest == actual_digest == manifest_digest:
		print "OK"
		return

	print "Cached item does NOT verify:\n" + \
			" Expected digest: " + required_digest + "\n" + \
			"   Actual digest: " + actual_digest + "\n" + \
			".manifest digest: " + (manifest_digest or 'No .manifest file')

	print
	if manifest_digest is None:
		print "No .manifest, so no further details available."
	elif manifest_digest == actual_digest:
		print "The .manifest file matches the actual contents."
		print "Very strange!"
	elif manifest_digest == required_digest:
		print "The .manifest file matches directory name. The "
		print "contents of the directory have changed:"
		show_changes(lines, file(manifest_file).readlines())
	elif required_digest == actual_digest:
		print "The directory contents are correct, but the .manifest file is "
		print "wrong!"
	else:
		print "The .manifest file matches neither of the other digests."
		print "Odd."
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
