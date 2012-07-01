"""
The B{0install digest} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import os, tempfile

from zeroinstall import SafeException, _
from zeroinstall.zerostore import manifest, unpack
from zeroinstall.cmd import UsageError
from zeroinstall import support

syntax = "DIRECTORY | ARCHIVE [EXTRACT]"

def add_options(parser):
	parser.add_option("", "--algorithm", help=_("the hash function to use"), metavar="HASH")

def handle(config, options, args):
	if len(args) == 1:
		extract = None
	elif len(args) == 2:
		extract = args[1]
	else:
		raise UsageError()

	source = args[0]
	alg = manifest.algorithms.get(options.algorithm or 'sha1new', None)
	if alg is None:
		raise SafeException(_('Unknown algorithm "%s"') % alg)

	def do_manifest(d):
		if extract is not None:
			d = os.path.join(d, extract)
		digest = alg.new_digest()
		for line in alg.generate_manifest(d):
			digest.update((line + '\n').encode('utf-8'))
		print(alg.getID(digest))

	if os.path.isdir(source):
		if extract is not None:
			raise SafeException("Can't use extract with a directory")
		do_manifest(source)
	else:
		data = None
		tmpdir = tempfile.mkdtemp()
		try:
			data = open(args[0], 'rb')
			unpack.unpack_archive(source, data, tmpdir, extract)
			do_manifest(tmpdir)
		finally:
			support.ro_rmtree(tmpdir)
			if data:
				data.close()
