import sys, os
from zeroinstall.zerostore.manifest import generate_manifest
from zeroinstall import zerostore

stores = zerostore.Stores()

def manifest(args):
	"""manifest DIRECTORY"""
	if len(args) != 1:
		print >>sys.stderr, "usage: " + manifest.__doc__
		sys.exit(1)
	import sha
	digest = sha.new()
	for line in generate_manifest(args[0]):
		print line
		digest.update(line + '\n')
	print "sha1=" + digest.hexdigest()
	sys.exit(0)

def clean():
	"""clean INTERFACE"""

def store():
	"""store DIGEST DIRECTORY"""

def delete():
	"""delete (DIGEST | DIRECTORY)"""

def verify(args):
	"""verify (DIGEST | DIRECTORY)"""
	if len(args) != 1:
		print >>sys.stderr, "usage: " + verify.__doc__
		sys.exit(1)
	root = get_stored(args[0])

	print "Verifying", root

def get_stored(dir_or_digest):
	if os.path.isdir(dir_or_digest):
		root = args[0]
	else:
		try:
			return stores.lookup(dir_or_digest)
		except zerostore.BadDigest, ex:
			print >>sys.stderr, ex
		except zerostore.NotStored, ex:
			print >>sys.stderr, ex
		sys.exit(1)

#"usage: %prog clean [interface]\n"
#"       %prog verify [directory]\n"
#"       %prog import [digest] [directory]\n"
#"       %prog manifest [directory]")

#commands = [clean, verify, store, manifest]
commands = [clean, manifest, delete, store, verify]
