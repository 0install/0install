# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
import shutil
import traceback
from tempfile import mkdtemp, mkstemp
import sha
import re
from logging import debug, info, warn
from zeroinstall import SafeException

_recent_gnu_tar = None
def recent_gnu_tar():
	global _recent_gnu_tar
	if _recent_gnu_tar is None:
		_recent_gnu_tar = False
		version = os.popen('tar --version 2>&1').next()
		if '(GNU tar)' in version:
			try:
				version = version.split(')', 1)[1].strip()
				assert version
				version = map(int, version.split('.'))
				_recent_gnu_tar = version > [1, 13, 92]
			except:
				warn("Failed to extract GNU tar version number")
		debug("Recent GNU tar = %s", _recent_gnu_tar)
	return _recent_gnu_tar

def _find_in_path(prog):
	for d in os.environ['PATH'].split(':'):
		path = os.path.join(d, prog)
		if os.path.isfile(path):
			return path
	return None
_pola_run = _find_in_path('pola-run')
if _pola_run:
	info('Found pola-run: %s', _pola_run)
else:
	info('pola-run not found; archive extraction will not be sandboxed')

def type_from_url(url):
	"""Guess the MIME type for this resource based on its URL. Returns None if we don't know what it is."""
	url = url.lower()
	if url.endswith('.rpm'): return 'application/x-rpm'
	if url.endswith('.deb'): return 'application/x-deb'
	if url.endswith('.tar.bz2'): return 'application/x-bzip-compressed-tar'
	if url.endswith('.tar.gz'): return 'application/x-compressed-tar'
	if url.endswith('.tgz'): return 'application/x-compressed-tar'
	if url.endswith('.zip'): return 'application/zip'
	return None

def check_type_ok(mime_type):
	"""Check we have the needed software to extract from an archive of the given type. Raise an exception if not."""
	assert mime_type
	if mime_type == 'application/x-rpm':
		if not _find_in_path('rpm2cpio'):
			raise SafeException("The URL '%s' looks like an RPM, but you don't have the rpm2cpio command "
					"I need to extract it. Install the 'rpm' package first (this works even if "
					"you're on a non-RPM-based distribution such as Debian)." % url)
	elif mime_type == 'application/x-deb':
		if not _find_in_path('ar'):
			raise SafeException("The URL '%s' looks like a Debian package, but you don't have the 'ar' command "
					"I need to extract it. Install the package containing it (sometimes called 'binutils') "
					"first. This works even if you're on a non-Debian-based distribution such as Red Hat)."
					% url)
	elif mime_type == 'application/x-bzip-compressed-tar':
		if not _find_in_path('bunzip2'):
			raise SafeException("The URL '%s' looks like a bzip2-compressed package, but you don't have the 'bunzip2' command "
					"I need to extract it. Install the package containing it (it's probably called 'bzip2') "
					"first."
					% url)
	elif mime_type == 'application/zip':
		if not _find_in_path('unzip'):
			raise SafeException("The URL '%s' looks like a zip-compressed archive, but you don't have the 'unzip' command "
					"I need to extract it. Install the package containing it first."
					% url)
	elif mime_type in 'application/x-compressed-tar':
		pass
	else:
		from zeroinstall import version
		raise SafeException("Unsupported archive type '%s' (for injector version %s)" % (mime_type, version))

def _exec_maybe_sandboxed(writable, prog, *args):
	"""execlp prog, with (only) the 'writable' directory writable if sandboxing is available.
	If no sandbox is available, run without a sandbox."""
	prog_path = _find_in_path(prog)
	if _pola_run is None:
		os.execlp(prog_path, prog_path, *args)
	# We have pola-shell :-)
	pola_args = ['--prog', prog_path, '-f', '/']
	for a in args:
		pola_args += ['-a', a]
	if writable:
		pola_args += ['-fw', writable]
	os.execl(_pola_run, _pola_run, *pola_args)

def unpack_archive(url, data, destdir, extract = None, type = None, start_offset = 0):
	"""Unpack stream 'data' into directory 'destdir'. If extract is given, extract just
	that sub-directory from the archive. Works out the format from the name."""
	if type is None: type = type_from_url(url)
	if type is None: raise SafeException("Unknown extension (and no MIME type given) in '%s'" % url)
	if type == 'application/x-bzip-compressed-tar':
		extract_tar(data, destdir, extract, '--bzip2', start_offset)
	elif type == 'application/x-deb':
		extract_deb(data, destdir, extract, start_offset)
	elif type == 'application/x-rpm':
		extract_rpm(data, destdir, extract, start_offset)
	elif type == 'application/zip':
		extract_zip(data, destdir, extract, start_offset)
	elif type == 'application/x-compressed-tar':
		extract_tar(data, destdir, extract, '-z', start_offset)
	else:
		raise SafeException('Unknown MIME type "%s" for "%s"' % (type, url))

def extract_deb(stream, destdir, extract = None, start_offset = 0):
	if extract:
		raise SafeException('Sorry, but the "extract" attribute is not yet supported for Debs')

	stream.seek(start_offset)
	# ar can't read from stdin, so make a copy...
	deb_copy_name = os.path.join(destdir, 'archive.deb')
	deb_copy = file(deb_copy_name, 'w')
	shutil.copyfileobj(stream, deb_copy)
	deb_copy.close()
	_extract(stream, destdir, ('ar', 'x', 'archive.deb', 'data.tar.gz'))
	os.unlink(deb_copy_name)
	data_name = os.path.join(destdir, 'data.tar.gz')
	data_stream = file(data_name)
	os.unlink(data_name)
	_extract(data_stream, destdir, ('tar', 'xzf', '-'))

def extract_rpm(stream, destdir, extract = None, start_offset = 0):
	if extract:
		raise SafeException('Sorry, but the "extract" attribute is not yet supported for RPMs')
	fd, cpiopath = mkstemp('-rpm-tmp')
	try:
		child = os.fork()
		if child == 0:
			try:
				try:
					os.dup2(stream.fileno(), 0)
					os.lseek(0, start_offset, 0)
					os.dup2(fd, 1)
					_exec_maybe_sandboxed(None, 'rpm2cpio', '-')
				except:
					traceback.print_exc()
			finally:
				os._exit(1)
		id, status = os.waitpid(child, 0)
		assert id == child
		if status != 0:
			raise SafeException("rpm2cpio failed; can't unpack RPM archive; exit code %d" % status)
		os.close(fd)
		fd = None
		args = ['cpio', '-mid', '--quiet']
		_extract(file(cpiopath), destdir, args)
		# Set the mtime of every directory under 'tmp' to 0, since cpio doesn't
		# preserve directory mtimes.
		os.path.walk(destdir, lambda arg, dirname, names: os.utime(dirname, (0, 0)), None)
	finally:
		if fd is not None:
			os.close(fd)
		os.unlink(cpiopath)

def extract_zip(stream, destdir, extract, start_offset = 0):
	if extract:
		# Limit the characters we accept, to avoid sending dodgy
		# strings to zip
		if not re.match('^[a-zA-Z0-9][- _a-zA-Z0-9.]*$', extract):
			raise SafeException('Illegal character in extract attribute')

	stream.seek(start_offset)
	# unzip can't read from stdin, so make a copy...
	zip_copy_name = os.path.join(destdir, 'archive.zip')
	zip_copy = file(zip_copy_name, 'w')
	shutil.copyfileobj(stream, zip_copy)
	zip_copy.close()

	args = ['unzip', '-q', '-o']

	if extract:
		args.append(extract)

	_extract(stream, destdir, args + ['archive.zip'])
	os.unlink(zip_copy_name)
	
def extract_tar(stream, destdir, extract, decompress, start_offset = 0):
	if extract:
		# Limit the characters we accept, to avoid sending dodgy
		# strings to tar
		if not re.match('^[a-zA-Z0-9][- _a-zA-Z0-9.]*$', extract):
			raise SafeException('Illegal character in extract attribute')

	if recent_gnu_tar():
		args = ['tar', decompress, '-x', '--no-same-owner', '--no-same-permissions']
	else:
		args = ['tar', decompress, '-xf', '-']

	if extract:
		args.append(extract)

	_extract(stream, destdir, args, start_offset)
	
def _extract(stream, destdir, command, start_offset = 0):
	"""Run execvp('command') inside destdir in a child process, with
	stream seeked to 'start_offset' as stdin."""
	child = os.fork()
	if child == 0:
		try:
			try:
				os.chdir(destdir)
				stream.seek(start_offset)
				os.dup2(stream.fileno(), 0)
				_exec_maybe_sandboxed(destdir, *command)
			except:
				traceback.print_exc()
		finally:
			os._exit(1)
	id, status = os.waitpid(child, 0)
	assert id == child
	if status != 0:
		raise SafeException('Failed to extract archive; exit code %d' % status)
