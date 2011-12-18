"""
Useful support routines (for internal use).

These functions aren't really Zero Install specific; they're things we might
wish were in the standard library.

@since: 0.27
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, logging

def find_in_path(prog):
	"""Search $PATH for prog.
	If prog is an absolute path, return it unmodified.
	@param prog: name of executable to find
	@return: the full path of prog, or None if not found
	@since: 0.27
	"""
	if os.path.isabs(prog): return prog
	if os.name == "nt":
		prog += '.exe'
	for d in os.environ.get('PATH', '/bin:/usr/bin').split(os.pathsep):
		path = os.path.join(d, prog)
		if os.path.isfile(path):
			return path
	return None

def read_bytes(fd, nbytes, null_ok = False):
	"""Read exactly nbytes from fd.
	@param fd: file descriptor to read from
	@param nbytes: number of bytes to read
	@param null_ok: if True, it's OK to receive EOF immediately (we then return None)
	@return: the bytes read
	@raise Exception: if we received less than nbytes of data
	"""
	data = ''
	while nbytes:
		got = os.read(fd, nbytes)
		if not got:
			if null_ok and not data:
				return None
			raise Exception(_("Unexpected end-of-stream. Data so far %(data)s; expecting %(bytes)d bytes more.")
					% {'data': repr(data), 'bytes': nbytes})
		data += got
		nbytes -= len(got)
	logging.debug(_("Message received: %s") % repr(data))
	return data

def pretty_size(size):
	"""Format a size for printing.
	@param size: the size in bytes
	@type size: int (or None)
	@return: the formatted size
	@rtype: str
	@since: 0.27"""
	if size is None:
		return '?'
	if size < 2048:
		return _('%d bytes') % size
	size = float(size)
	for unit in (_('KB'), _('MB'), _('GB'), _('TB')):
		size /= 1024
		if size < 2048:
			break
	return _('%(size).1f %(unit)s') % {'size': size, 'unit': unit}

def ro_rmtree(root):
	"""Like shutil.rmtree, except that we also delete read-only items.
	@param root: the root of the subtree to remove
	@type root: str
	@since: 0.28"""
	import shutil
	import platform
	if platform.system() == 'Windows':
		for main, dirs, files in os.walk(root):
			for i in files + dirs:
				os.chmod(os.path.join(main, i), 0o700)
		os.chmod(root, 0o700)
	else:
		for main, dirs, files in os.walk(root):
			os.chmod(main, 0o700)
	shutil.rmtree(root)

def raise_with_traceback(ex, tb):
	if hasattr(ex, 'with_traceback'):
		raise ex.with_traceback(tb)			# Python 3
	exec("raise ex, None, tb", {'ex': ex, 'tb': tb})	# Python 2
	assert 0
