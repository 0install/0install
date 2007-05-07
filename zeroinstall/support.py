"""
Useful support routines (for internal use).

These functions aren't really Zero Install specific; they're things we might
wish were in the standard library.

@since: 0.27
"""

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, logging

def find_in_path(prog):
	"""Search $PATH for prog.
	If prog is an absolute path, return it unmodified.
	@param prog: name of executable to find
	@return: the full path of prog, or None if not found
	@since: 0.27
	"""
	if os.path.isabs(prog): return prog
	for d in os.environ['PATH'].split(':'):
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
		got = os.read(fd, min(256, nbytes))
		if not got:
			if null_ok and not data:
				return None
			raise Exception("Unexpected end-of-stream. Data so far %s; expecting %d bytes more."
					% (repr(data), nbytes))
		data += got
		nbytes -= len(got)
	logging.debug("Message received: %s" % repr(data))
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
		return '%d bytes' % size
	size = float(size)
	for unit in ('Kb', 'Mb', 'Gb', 'Tb'):
		size /= 1024
		if size < 2048:
			break
	return '%.1f %s' % (size, unit)
