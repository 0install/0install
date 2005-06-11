import os
import shutil
import traceback
from tempfile import mkdtemp
import sha
import re
from logging import debug, info, warn

import manifest

class BadDigest(Exception): pass
class NotStored(Exception): pass

def copytree2(src, dst):
	names = os.listdir(src)
	assert os.path.isdir(dst)
	errors = []
	for name in names:
		srcname = os.path.join(src, name)
		dstname = os.path.join(dst, name)
		if os.path.islink(srcname):
			linkto = os.readlink(srcname)
			os.symlink(linkto, dstname)
		elif os.path.isdir(srcname):
			os.mkdir(dstname)
			mtime = os.lstat(srcname).st_mtime
			copytree2(srcname, dstname)
			os.utime(dstname, (mtime, mtime))
		else:
			shutil.copy2(srcname, dstname)

class Store:
	def __init__(self, dir):
		self.dir = dir
	
	def lookup(self, digest):
		alg, value = digest.split('=', 1)
		assert alg == 'sha1'
		assert '/' not in value
		int(value, 16)		# Check valid format
		dir = os.path.join(self.dir, digest)
		if os.path.isdir(dir):
			return dir
		return None
	
	def add_archive_to_cache(self, required_digest, data, url, extract = None):
		if url.endswith('.tar.bz2'):
			self.add_tbz_to_cache(required_digest, data, extract)
		else:
			if not (url.endswith('.tar.gz') or url.endswith('.tgz')):
				warn('Unknown extension on "%s"; assuming tar.gz format' % url)
			self.add_tgz_to_cache(required_digest, data, extract)
	
	def add_tbz_to_cache(self, required_digest, data, extract = None):
		self.add_tar_to_cache(required_digest, data, extract, '--bzip2')

	def add_tgz_to_cache(self, required_digest, data, extract = None):
		self.add_tar_to_cache(required_digest, data, extract, '-z')

	def add_tar_to_cache(self, required_digest, data, extract, decompress):
		"""Data is a .tgz compressed archive. Extract it somewhere, check that
		the digest is correct, and add it to the store.
		extract is the name of a directory within the archive to extract, rather
		than extracting the whole archive. This is most useful to remove an extra
		top-level directory."""
		assert required_digest.startswith('sha1=')
		info("Caching new implementation (digest %s)", required_digest)

		if self.lookup(required_digest):
			info("Not adding %s as it already exists!", required_digest)
			return

		if 'GNU tar' in os.popen('tar --version 2>&1').read():
			args = ['tar', decompress, '-x', '--no-same-owner', '--no-same-permissions']
		else:
			args = ['tar', decompress, '-xf', '-']

		if extract:
			# Limit the characters we accept, to avoid sending dodgy
			# strings to tar
			if not re.match('^[a-zA-Z0-9][-_a-zA-Z0-9.]*$', extract):
				raise Exception('Illegal character in extract attribute')
			args.append(extract)

		tmp = self.extract(data, args)
		try:
			self.check_manifest_and_rename(required_digest, tmp, extract)
		except Exception, ex:
			warn("Leaving extracted directory as %s", tmp)
			raise
	
	def add_dir_to_cache(self, required_digest, path):
		if self.lookup(required_digest):
			info("Not adding %s as it already exists!", required_digest)
			return

		tmp = mkdtemp(dir = self.dir, prefix = 'tmp-')
		copytree2(path, tmp)
		try:
			self.check_manifest_and_rename(required_digest, tmp)
		except:
			warn("Error importing directory.")
			warn("Deleting %s", tmp)
			#shutil.rmtree(tmp)
			raise

	def check_manifest_and_rename(self, required_digest, tmp, extract = None):
		if extract:
			extracted = os.path.join(tmp, extract)
			if not os.path.isdir(extracted):
				raise Exception('Directory %s not found in archive' % extract)
		else:
			extracted = tmp

		sha1 = 'sha1=' + manifest.add_manifest_file(extracted, sha.new()).hexdigest()
		if sha1 != required_digest:
			raise BadDigest('Incorrect manifest -- archive is corrupted.\n'
					'Required digest: %s\n'
					'Actual digest: %s\n' %
					(required_digest, sha1))

		final_name = os.path.join(self.dir, required_digest)
		if os.path.isdir(final_name):
			raise Exception("Item %s already stored." % final_name)
		if extract:
			os.rename(os.path.join(tmp, extract), final_name)
			os.rmdir(tmp)
		else:
			os.rename(tmp, final_name)

	def extract(self, stream, command):
		tmp = mkdtemp(dir = self.dir, prefix = 'tmp-')
		try:
			child = os.fork()
			if child == 0:
				try:
					try:
						os.chdir(tmp)
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
				raise Exception('Failed to extract archive; exit code %d' % status)
		except:
			shutil.rmtree(tmp)
			raise
		return tmp

class Stores(object):
	__slots__ = ['stores']

	def __init__(self):
		user_store = os.path.expanduser('~/.cache/0install.net/implementations')
		if not os.path.isdir(user_store):
			os.makedirs(user_store)
		self.stores = [Store(user_store)]

	def lookup(self, digest):
		"""Search for digest in all stores."""
		assert digest
		if '/' in digest or '=' not in digest:
			raise BadDigest('Syntax error in digest (use ALG=VALUE)')
		for store in self.stores:
			path = store.lookup(digest)
			if path:
				return path
		raise NotStored("Item with digest '%s' not found in stores. Searched:\n- %s" %
			(digest, '\n- '.join([s.dir for s in self.stores])))

	def add_dir_to_cache(self, required_digest, dir):
		self.stores[0].add_dir_to_cache(required_digest, dir)

	def add_archive_to_cache(self, required_digest, data, url, extract = None):
		self.stores[0].add_archive_to_cache(required_digest, data, url, extract)
