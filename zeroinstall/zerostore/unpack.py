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

def unpack_archive(url, data, destdir, extract = None):
	"""Unpack stream 'data' into directory 'destdir'. If extract is given, extract just
	that sub-directory from the archive. Works out the format from the name."""
	url = url.lower()
	if url.endswith('.tar.bz2'):
		extract_tar(data, destdir, extract, '--bzip2')
	elif url.endswith('.rpm'):
		extract_rpm(data, destdir, extract)
	elif url.endswith('.tar.gz') or url.endswith('.tgz'):
		extract_tar(data, destdir, extract, '-z')
	else:
		raise SafeException('Unknown extension on "%s"; I only know .tgz, .tar.bz2 and .rpm' % url)

def extract_rpm(stream, destdir, extract = None):
	if extract:
		raise SafeException('Sorry, but the "extract" attribute is not yet supported for RPMs')
	fd, cpiopath = mkstemp('-rpm-tmp')
	try:
		child = os.fork()
		if child == 0:
			try:
				try:
					os.dup2(stream.fileno(), 0)
					os.dup2(fd, 1)
					os.execlp('rpm2cpio', 'rpm2cpio', '-')
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

def extract_tar(stream, destdir, extract, decompress):
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

	_extract(stream, destdir, args)
	
def _extract(stream, destdir, command):
	"""Run execvp('command') inside destdir in a child process, with a
	rewound stream as stdin."""
	child = os.fork()
	if child == 0:
		try:
			try:
				os.chdir(destdir)
				stream.seek(0)
				os.dup2(stream.fileno(), 0)
				os.execvp(command[0], command)
			except:
				traceback.print_exc()
		finally:
			os._exit(1)
	id, status = os.waitpid(child, 0)
	assert id == child
	if status != 0:
		raise SafeException('Failed to extract archive; exit code %d' % status)
