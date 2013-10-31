"""Code for the B{0store} command-line interface."""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _
import os
from zeroinstall import zerostore, SafeException, support

stores = None

def init_stores():
	global stores
	assert stores is None
	if stores is None:
		stores = zerostore.Stores()

class UsageError(SafeException): pass

def do_optimise(args):
	"""optimise [ CACHE ]"""
	if len(args) == 1:
		cache_dir = args[0]
	else:
		global stores
		stores = zerostore.Stores()
		cache_dir = stores.stores[0].dir
	
	cache_dir = os.path.realpath(cache_dir)

	import stat
	info = os.stat(cache_dir)
	if not stat.S_ISDIR(info.st_mode):
		raise UsageError(_("Not a directory: '%s'") % cache_dir)

	impl_name = os.path.basename(cache_dir)
	if impl_name != 'implementations':
		raise UsageError(_("Cache directory should be named 'implementations', not\n"
				"'%(name)s' (in '%(cache_dir)s')") % {'name': impl_name, 'cache_dir': cache_dir})

	print(_("Optimising"), cache_dir)

	from . import optimise
	uniq_size, dup_size, already_linked, man_size = optimise.optimise(cache_dir)
	print(_("Original size  : %(size)s (excluding the %(manifest_size)s of manifests)") % {'size': support.pretty_size(uniq_size + dup_size), 'manifest_size': support.pretty_size(man_size)})
	print(_("Already saved  : %s") % support.pretty_size(already_linked))
	if dup_size == 0:
		print(_("No duplicates found; no changes made."))
	else:
		print(_("Optimised size : %s") % support.pretty_size(uniq_size))
		perc = (100 * float(dup_size)) / (uniq_size + dup_size)
		print(_("Space freed up : %(size)s (%(percentage).2f%%)") % {'size': support.pretty_size(dup_size), 'percentage': perc})
	print(_("Optimisation complete."))
