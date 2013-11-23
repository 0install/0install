"""
Python interface to GnuPG.

This module is used to invoke GnuPG to check the digital signatures on interfaces.

@see: L{iface_cache.PendingFeed}
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import subprocess
import os
import tempfile

from zeroinstall.support import find_in_path, basedir
from zeroinstall.injector.trust import trust_db
from zeroinstall.injector.model import SafeException

_gnupg_options = None
def _run_gpg(args, **kwargs):
	"""@type args: [str]
	@rtype: subprocess.Popen"""
	global _gnupg_options
	if _gnupg_options is None:
		gpg_path = os.environ.get('ZEROINSTALL_GPG') or find_in_path('gpg') or find_in_path('gpg2') or 'gpg'
		_gnupg_options = [gpg_path, '--no-secmem-warning']

		if hasattr(os, 'geteuid') and os.geteuid() == 0 and 'GNUPGHOME' not in os.environ:
			_gnupg_options += ['--homedir', os.path.join(basedir.home, '.gnupg')]
			logger.info(_("Running as root, so setting GnuPG home to %s"), _gnupg_options[-1])

	return subprocess.Popen(_gnupg_options + args, universal_newlines = True, **kwargs)

class Signature(object):
	"""Abstract base class for signature check results.
	@ivar status: the raw data returned by GPG
	@ivar messages: any messages printed by GPG which may be relevant to this signature
	"""
	status = None
	messages = None

	def __init__(self, status):
		"""@type status: [str]"""
		self.status = status

	def is_trusted(self, domain = None):
		"""Whether this signature is trusted by the user.
		@rtype: bool"""
		return False
	
	def need_key(self):
		"""Returns the ID of the key that must be downloaded to check this signature."""
		return None

class ValidSig(Signature):
	"""A valid signature check result."""
	FINGERPRINT = 0
	TIMESTAMP = 2

	def __str__(self):
		"""@rtype: str"""
		return "Valid signature from " + self.status[self.FINGERPRINT]
	
	def is_trusted(self, domain = None):
		"""Asks the L{trust.trust_db}.
		@type domain: str | None
		@rtype: bool"""
		return trust_db.is_trusted(self.status[self.FINGERPRINT], domain)
	
	def get_timestamp(self):
		"""Get the time this signature was made.
		@rtype: int"""
		return int(self.status[self.TIMESTAMP])

	fingerprint = property(lambda self: self.status[self.FINGERPRINT])

	def get_details(self):
		"""Call 'gpg --list-keys' and return the results split into lines and columns.
		@rtype: [[str]]"""
		# Note: GnuPG 2 always uses --fixed-list-mode
		child = _run_gpg(['--fixed-list-mode', '--with-colons', '--list-keys', self.fingerprint], stdout = subprocess.PIPE)
		cout, unused = child.communicate()
		if child.returncode:
			logger.info(_("GPG exited with code %d") % child.returncode)
		details = []
		for line in cout.split('\n'):
			details.append(line.split(':'))
		return details

class Key(object):
	"""A GPG key.
	@since: 0.27
	@ivar fingerprint: the fingerprint of the key
	@type fingerprint: str
	@ivar name: a short name for the key, extracted from the full name
	@type name: str
	"""
	def __init__(self, fingerprint):
		"""@type fingerprint: str"""
		self.fingerprint = fingerprint
		self.name = '(unknown)'
	
	def get_short_name(self):
		return self.name.split(' (', 1)[0].split(' <', 1)[0]

def load_keys(fingerprints):
	"""Load a set of keys at once.
	This is much more efficient than making individual calls to L{load_key}.
	@type fingerprints: [str]
	@return: a list of loaded keys, indexed by fingerprint
	@rtype: {str: L{Key}}
	@since: 0.27"""
	import codecs

	keys = {}

	# Otherwise GnuPG returns everything...
	if not fingerprints: return keys

	for fp in fingerprints:
		keys[fp] = Key(fp)

	current_fpr = None
	current_uid = None

	child = _run_gpg(['--fixed-list-mode', '--with-colons', '--list-keys',
				'--with-fingerprint', '--with-fingerprint'] + fingerprints, stdout = subprocess.PIPE)
	try:
		for line in child.stdout:
			if line.startswith('pub:'):
				current_fpr = None
				current_uid = None
			if line.startswith('fpr:'):
				current_fpr = line.split(':')[9]
				if current_fpr in keys and current_uid:
					# This is probably a subordinate key, where the fingerprint
					# comes after the uid, not before. Note: we assume the subkey is
					# cross-certified, as recent always ones are.
					try:
						keys[current_fpr].name = codecs.decode(current_uid, 'utf-8')
					except:
						logger.warning("Not UTF-8: %s", current_uid)
						keys[current_fpr].name = current_uid
			if line.startswith('uid:'):
				assert current_fpr is not None
				# Only take primary UID
				if current_uid: continue
				parts = line.split(':')
				current_uid = parts[9]
				if current_fpr in keys:
					keys[current_fpr].name = current_uid
	finally:
		child.stdout.close()

		if child.wait():
			logger.warning(_("gpg --list-keys failed with exit code %d") % child.returncode)

	return keys

def load_key(fingerprint):
	"""Query gpg for information about this key.
	@return: a new key
	@rtype: L{Key}
	@since: 0.27"""
	return load_keys([fingerprint])[fingerprint]
