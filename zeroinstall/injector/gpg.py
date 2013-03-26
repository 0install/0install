"""
Python interface to GnuPG.

This module is used to invoke GnuPG to check the digital signatures on interfaces.

@see: L{iface_cache.PendingFeed}
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import subprocess
import base64, re
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

class BadSig(Signature):
	"""A bad signature (doesn't match the message)."""
	KEYID = 0

	def __str__(self):
		"""@rtype: str"""
		return _("BAD signature by %s (the message has been tampered with)") \
			% self.status[self.KEYID]

class ErrSig(Signature):
	"""Error while checking a signature."""
	KEYID = 0
	ALG = 1
	RC = -1

	def __str__(self):
		"""@rtype: str"""
		msg = _("ERROR signature by %s: ") % self.status[self.KEYID]
		rc = int(self.status[self.RC])
		if rc == 4:
			msg += _("Unknown or unsupported algorithm '%s'") % self.status[self.ALG]
		elif rc == 9:
			msg += _("Unknown key. Try 'gpg --recv-key %s'") % self.status[self.KEYID]
		else:
			msg += _("Unknown reason code %d") % rc
		return msg

	def need_key(self):
		"""@rtype: str | None"""
		rc = int(self.status[self.RC])
		if rc == 9:
			return self.status[self.KEYID]
		return None

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

def import_key(stream):
	"""Run C{gpg --import} with this stream as stdin.
	@type stream: file"""
	with tempfile.TemporaryFile(mode = 'w+t') as errors:
		child = _run_gpg(['--quiet', '--import', '--batch'],
					stdin = stream, stderr = errors)

		status = child.wait()

		errors.seek(0)
		error_messages = errors.read().strip()

	if status != 0:
		if error_messages:
			raise SafeException(_("Errors from 'gpg --import':\n%s") % error_messages)
		else:
			raise SafeException(_("Non-zero exit code %d from 'gpg --import'") % status)
	elif error_messages:
		logger.warning(_("Warnings from 'gpg --import':\n%s") % error_messages)

def _check_xml_stream(stream):
	"""@type stream: file
	@rtype: (file, [L{Signature}])"""
	xml_comment_start = b'<!-- Base64 Signature'

	data_to_check = stream.read()

	last_comment = data_to_check.rfind(b'\n' + xml_comment_start)
	if last_comment < 0:
		raise SafeException(_("No signature block in XML. Maybe this file isn't signed?"))
	last_comment += 1	# Include new-line in data
	
	# Copy the file to 'data', without the signature
	# Copy the signature to 'sig'

	with tempfile.TemporaryFile(mode = 'w+b') as data:
		data.write(data_to_check[:last_comment])
		data.flush()
		os.lseek(data.fileno(), 0, 0)

		with tempfile.TemporaryFile('w+t') as errors:
			sig_lines = data_to_check[last_comment:].split(b'\n')
			if sig_lines[0].strip() != xml_comment_start:
				raise SafeException(_('Bad signature block: extra data on comment line'))
			while sig_lines and not sig_lines[-1].strip():
				del sig_lines[-1]
			if sig_lines[-1].strip() != b'-->':
				raise SafeException(_('Bad signature block: last line is not end-of-comment'))
			sig_data = b'\n'.join(sig_lines[1:-1])

			if re.match(b'^[ A-Za-z0-9+/=\n]+$', sig_data) is None:
				raise SafeException(_("Invalid characters found in base 64 encoded signature"))
			try:
				if hasattr(base64, 'decodebytes'):
					sig_data = base64.decodebytes(sig_data) # Python 3
				else:
					sig_data = base64.decodestring(sig_data) # Python 2
			except Exception as ex:
				raise SafeException(_("Invalid base 64 encoded signature: %s") % str(ex))

			with tempfile.NamedTemporaryFile(prefix = 'injector-sig-', mode = 'wb', delete = False) as sig_file:
				sig_file.write(sig_data)

			try:
				# Note: Should ideally close status_r in the child, but we want to support Windows too
				child = _run_gpg([# Not all versions support this:
						  #'--max-output', str(1024 * 1024),
						  '--batch',
						  # Windows GPG can only cope with "1" here
						  '--status-fd', '1',
						  # Don't try to download missing keys; we'll do that
						  '--keyserver-options', 'no-auto-key-retrieve',
						  '--verify', sig_file.name, '-'],
					   stdin = data,
					   stdout = subprocess.PIPE,
					   stderr = errors)

				try:
					sigs = _get_sigs_from_gpg_status_stream(child.stdout, child, errors)
				finally:
					os.lseek(stream.fileno(), 0, 0)
					errors.close()
					child.stdout.close()
					child.wait()
					stream.seek(0)
			finally:
				os.unlink(sig_file.name)
			return (stream, sigs)

def check_stream(stream):
	"""Verify the GPG signature at the end of stream.
	stream must be seekable.
	@type stream: file
	@return: (stream, [Signatures])
	@rtype: (file, [L{Signature}])"""

	stream.seek(0)

	start = stream.read(6)
	stream.seek(0)
	if start == b"<?xml ":
		return _check_xml_stream(stream)
	elif start == b'-----B':
		raise SafeException(_("Plain GPG-signed feeds no longer supported"))
	else:
		raise SafeException(_("This is not a Zero Install feed! It should be an XML document, but it starts:\n%s") % repr(stream.read(120)))

def _get_sigs_from_gpg_status_stream(status_r, child, errors):
	"""Read messages from status_r and collect signatures from it.
	When done, reap 'child'.
	If there are no signatures, throw SafeException (using errors
	for the error message if non-empty).
	@type status_r: file
	@type child: L{subprocess.Popen}
	@type errors: file
	@rtype: [L{Signature}]"""
	sigs = []

	# Should we error out on bad signatures, even if there's a good
	# signature too?

	for line in status_r:
		assert line.endswith('\n')
		if not line.startswith('[GNUPG:] '):
			# The docs says every line starts with this, but if auto-key-retrieve
			# is on then they might not. See bug #3420548
			logger.warning("Invalid output from GnuPG: %r", line)
			continue

		line = line[9:-1]
		split_line = line.split(' ')
		code = split_line[0]
		args = split_line[1:]
		if code == 'VALIDSIG':
			sigs.append(ValidSig(args))
		elif code == 'BADSIG':
			sigs.append(BadSig(args))
		elif code == 'ERRSIG':
			sigs.append(ErrSig(args))

	errors.seek(0)

	error_messages = errors.read().strip()

	if not sigs:
		if error_messages:
			raise SafeException(_("No signatures found. Errors from GPG:\n%s") % error_messages)
		else:
			raise SafeException(_("No signatures found. No error messages from GPG."))
	elif error_messages:
		# Attach the warnings to all the signatures, in case they're useful.
		for s in sigs:
			s.messages = error_messages

	return sigs
