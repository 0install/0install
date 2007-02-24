"""Unpacking archives of various formats."""

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

_cpio_version = None
def _get_cpio_version():
	global _cpio_version
	if _cpio_version is None:
		_cpio_version = os.popen('cpio --version 2>&1').next()
		debug("cpio version = %s", _cpio_version)
	return _cpio_version

def _gnu_cpio():
	gnu_cpio = '(GNU cpio)' in _get_cpio_version()
	debug("Is GNU cpio = %s", gnu_cpio)
	return gnu_cpio

_tar_version = None
def _get_tar_version():
	global _tar_version
	if _tar_version is None:
		_tar_version = os.popen('tar --version 2>&1').next()
		debug("tar version = %s", _tar_version)
	return _tar_version

def _gnu_tar():
	gnu_tar = '(GNU tar)' in _get_tar_version()
	debug("Is GNU tar = %s", gnu_tar)
	return gnu_tar

def recent_gnu_tar():
	"""@deprecated: should be private"""
	recent_gnu_tar = False
	if _gnu_tar():
		version = _get_tar_version()
		try:
			version = version.split(')', 1)[1].strip()
			assert version
			version = map(int, version.split('.'))
			recent_gnu_tar = version > [1, 13, 92]
		except:
			warn("Failed to extract GNU tar version number")
	debug("Recent GNU tar = %s", recent_gnu_tar)
	return recent_gnu_tar

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
	if url.endswith('.tar.lzma'): return 'application/x-lzma-compressed-tar'	# XXX: No registered MIME type!
	if url.endswith('.tgz'): return 'application/x-compressed-tar'
	if url.endswith('.tar'): return 'application/x-tar'
	if url.endswith('.zip'): return 'application/zip'
	if url.endswith('.cab'): return 'application/vnd.ms-cab-compressed'
	return None

def check_type_ok(mime_type):
	"""Check we have the needed software to extract from an archive of the given type.
	@raise SafeException: if the needed software is not available"""
	assert mime_type
	if mime_type == 'application/x-rpm':
		if not _find_in_path('rpm2cpio'):
			raise SafeException("This package looks like an RPM, but you don't have the rpm2cpio command "
					"I need to extract it. Install the 'rpm' package first (this works even if "
					"you're on a non-RPM-based distribution such as Debian).")
	elif mime_type == 'application/x-deb':
		if not _find_in_path('ar'):
			raise SafeException("This package looks like a Debian package, but you don't have the 'ar' command "
					"I need to extract it. Install the package containing it (sometimes called 'binutils') "
					"first. This works even if you're on a non-Debian-based distribution such as Red Hat).")
	elif mime_type == 'application/x-bzip-compressed-tar':
		if not _find_in_path('bunzip2'):
			raise SafeException("This package looks like a bzip2-compressed package, but you don't have the 'bunzip2' command "
					"I need to extract it. Install the package containing it (it's probably called 'bzip2') "
					"first.")
	elif mime_type == 'application/zip':
		if not _find_in_path('unzip'):
			raise SafeException("This package looks like a zip-compressed archive, but you don't have the 'unzip' command "
					"I need to extract it. Install the package containing it first.")
	elif mime_type == 'application/vnd.ms-cab-compressed':
		if not _find_in_path('cabextract'):
			raise SafeException("This package looks like a Microsoft Cabinet archive, but you don't have the 'cabextract' command "
					"I need to extract it. Install the package containing it first.")
	elif mime_type == 'application/x-lzma-compressed-tar':
		if not _find_in_path('unlzma'):
			raise SafeException("This package looks like an LZMA archive, but you don't have the 'unlzma' command "
					"I need to extract it. Install the package containing it (it's probably called 'lzma') first.")
	elif mime_type in ('application/x-compressed-tar', 'application/x-tar'):
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
		extract_tar(data, destdir, extract, 'bzip2', start_offset)
	elif type == 'application/x-deb':
		extract_deb(data, destdir, extract, start_offset)
	elif type == 'application/x-rpm':
		extract_rpm(data, destdir, extract, start_offset)
	elif type == 'application/zip':
		extract_zip(data, destdir, extract, start_offset)
	elif type == 'application/x-tar':
		extract_tar(data, destdir, extract, None, start_offset)
	elif type == 'application/x-lzma-compressed-tar':
		extract_tar(data, destdir, extract, 'lzma', start_offset)
	elif type == 'application/x-compressed-tar':
		extract_tar(data, destdir, extract, 'gzip', start_offset)
	elif type == 'application/vnd.ms-cab-compressed':
		extract_cab(data, destdir, extract, start_offset)
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
	extract_tar(data_stream, destdir, None, 'gzip')

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

		args = ['cpio', '-mid']
		if _gnu_cpio():
			args.append('--quiet')

		_extract(file(cpiopath), destdir, args)
		# Set the mtime of every directory under 'tmp' to 0, since cpio doesn't
		# preserve directory mtimes.
		os.path.walk(destdir, lambda arg, dirname, names: os.utime(dirname, (0, 0)), None)
	finally:
		if fd is not None:
			os.close(fd)
		os.unlink(cpiopath)

def extract_cab(stream, destdir, extract, start_offset = 0):
	"@since: 0.24"
	if extract:
		raise SafeException('Sorry, but the "extract" attribute is not yet supported for Cabinet files')

	stream.seek(start_offset)
	# cabextract can't read from stdin, so make a copy...
	cab_copy_name = os.path.join(destdir, 'archive.cab')
	cab_copy = file(cab_copy_name, 'w')
	shutil.copyfileobj(stream, cab_copy)
	cab_copy.close()

	_extract(stream, destdir, ['cabextract', '-s', '-q', 'archive.cab'])
	os.unlink(cab_copy_name)
	
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

	assert decompress in [None, 'bzip2', 'gzip', 'lzma']

	if _gnu_tar():
		ext_cmd = ['tar']
		if decompress:
			if decompress == 'bzip2':
				ext_cmd.append('--bzip2')
			elif decompress == 'gzip':
				ext_cmd.append('-z')
			elif decompress == 'lzma':
				ext_cmd.append('--use-compress-program=unlzma')

		if recent_gnu_tar():
			ext_cmd.extend(('-x', '--no-same-owner', '--no-same-permissions'))
		else:
			ext_cmd.extend(('xf', '-'))

		if extract:
			ext_cmd.append(extract)

		_extract(stream, destdir, ext_cmd, start_offset)
	else:
		# Since we don't have GNU tar, use python's tarfile module. This will probably
		# be a lot slower and we do not support lzma; however, it is portable.
		if decompress is None:
			rmode = 'r|'
		elif decompress == 'bzip2':
			rmode = 'r|bz2'
		elif decompress == 'gzip':
			rmode = 'r|gz'
		else:
			raise SafeException('GNU tar unavailable; unsupported compression format: ' + decompress)

		import tarfile
		try:
			stream.seek(start_offset)
			tar = tarfile.open(mode = rmode, fileobj = stream)

			ext_dirs = []
			if extract is None:
				for tarinfo in tar:
					if tarinfo.isdir():
						ext_dirs.append(tarinfo)

					tar.extract(tarinfo, destdir)
			else:
				# First try to extract specified item as a file
				tarinfo = None
				is_dir = False
				try:
					tarinfo = tar.getmember(extract)
				except:
					tarinfo = None

				# If we didn't get it, the item must be a directory
				if tarinfo is None:
					try:
						tarinfo = tar.getmember(extract + '/')
						is_dir = True
					except:
						tarinfo = None

				if tarinfo is None:
					raise SafeException('Unable to find specified file = %s in archive' % extract)

				# Random access isn't permitted with tarfile objects, so we have to
				# restart once getmember is succcessful.
				tar.close()
				stream.seek(start_offset)
				tar = tarfile.open(mode = rmode, fileobj = stream)

				if is_dir:
					for tarinfo in tar:
						if tarinfo.name.startswith(extract):
							if tarinfo.isdir():
								ext_dirs.append(tarinfo)

							tar.extract(tarinfo, destdir)
				else:
					ext_dirs = [tarinfo]
					tar.extract(tarinfo, destdir)

			# Due to a bug in tarfile (python versions < 2.5), I have to manually set the mtime
			# of each directory that I extract after I have finished extracting everything.
			# Additionally, we don't want the original permissions on directories, so we need
			# to set the mode to match the user's umask.
			current_umask = os.umask(0)
			os.umask(current_umask)

			for tarinfo in ext_dirs:
				dirname = os.path.join(destdir, tarinfo.name)
				mode = os.stat(dirname).st_mode & ~current_umask
				os.chmod(dirname, mode)
				os.utime(dirname, (tarinfo.mtime, tarinfo.mtime))

			tar.close()
		except:
			raise SafeException('Failed to extract archive; destdir = %s' % destdir)
	
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
