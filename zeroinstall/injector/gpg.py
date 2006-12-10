"""
Python interface to GnuPG.

This module is used to invoke GnuPG to check the digital signatures on interfaces.

@see: L{iface_cache.PendingFeed}
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import base64, re
import os
import tempfile
import traceback
from trust import trust_db
from model import SafeException

class Signature:
	"""Abstract base class for signature check results."""
	status = None

	def __init__(self, status):
		self.status = status

	def is_trusted(self):
		return False
	
	def need_key(self):
		"""Returns the ID of the key that must be downloaded to check this signature."""
		return None

class ValidSig(Signature):
	"""A valid signature check result."""
	FINGERPRINT = 0
	TIMESTAMP = 2

	def __str__(self):
		return "Valid signature from " + self.status[self.FINGERPRINT]
	
	def is_trusted(self):
		return trust_db.is_trusted(self.status[self.FINGERPRINT])
	
	def get_timestamp(self):
		return int(self.status[self.TIMESTAMP])

	fingerprint = property(lambda self: self.status[self.FINGERPRINT])

	def get_details(self):
		cin, cout = os.popen2(('gpg', '--with-colons', '--no-secmem-warning', '--list-keys', self.fingerprint))
		cin.close()
		details = []
		for line in cout:
			details.append(line.split(':'))
		cout.close()
		return details

class BadSig(Signature):
	"""A bad signature (doesn't match the message)."""
	KEYID = 0

	def __str__(self):
		return "BAD signature by " + self.status[self.KEYID] + \
			" (the message has been tampered with)"

class ErrSig(Signature):
	"""Error while checking a signature."""
	KEYID = 0
	ALG = 1
	RC = -1

	def __str__(self):
		msg = "ERROR signature by %s: " % self.status[self.KEYID]
		rc = int(self.status[self.RC])
		if rc == 4:
			msg += "Unknown or unsupported algorithm '%s'" % self.status[self.ALG]
		elif rc == 9:
			msg += "Unknown key. Try 'gpg --recv-key %s'" % self.status[self.KEYID]
		else:
			msg += "Unknown reason code %d" % rc
		return msg

	def need_key(self):
		rc = int(self.status[self.RC])
		if rc == 9:
			return self.status[self.KEYID]
		return None

def import_key(stream):
	"""Run C{gpg --import} with this stream as stdin."""
	errors = tempfile.TemporaryFile()

	child = os.fork()
	if child == 0:
		# We are the child
		try:
			try:
				os.dup2(stream.fileno(), 0)
				os.dup2(errors.fileno(), 2)
				os.execlp('gpg', 'gpg', '--no-secmem-warning', '--quiet', '--import')
			except:
				traceback.print_exc()
		finally:
			os._exit(1)
		assert False

	pid, status = os.waitpid(child, 0)
	assert pid == child

	errors.seek(0)
	error_messages = errors.read().strip()
	errors.close()

	if error_messages:
		raise SafeException("Errors from 'gpg --import':\n%s" % error_messages)

def _check_plain_stream(stream):
	data = tempfile.TemporaryFile()	# Python2.2 does not support 'prefix'
	errors = tempfile.TemporaryFile()

	status_r, status_w = os.pipe()

	child = os.fork()

	if child == 0:
		# We are the child
		try:
			try:
				os.close(status_r)
				os.dup2(stream.fileno(), 0)
				os.dup2(data.fileno(), 1)
				os.dup2(errors.fileno(), 2)
				os.execlp('gpg', 'gpg', '--no-secmem-warning', '--decrypt',
					   # Not all versions support this:
					   #'--max-output', str(1024 * 1024),
					   '--batch',
					   '--status-fd', str(status_w))
			except:
				traceback.print_exc()
		finally:
			os._exit(1)
		assert False
	
	# We are the parent
	os.close(status_w)

	try:
		sigs = _get_sigs_from_gpg_status_stream(status_r, child, errors)
	finally:
		data.seek(0)
	return (data, sigs)

def _check_xml_stream(stream):
	xml_comment_start = '<!-- Base64 Signature'

	data_to_check = stream.read()

	last_comment = data_to_check.rfind('\n' + xml_comment_start)
	if last_comment < 0:
		raise SafeException("No signature block in XML. Maybe this file isn't signed?")
	last_comment += 1	# Include new-line in data
	
	data = tempfile.TemporaryFile()
	data.write(data_to_check[:last_comment])
	data.flush()
	os.lseek(data.fileno(), 0, 0)

	errors = tempfile.TemporaryFile()

	sig_lines = data_to_check[last_comment:].split('\n')
	if sig_lines[0].strip() != xml_comment_start:
		raise SafeException('Bad signature block: extra data on comment line')
	while sig_lines and not sig_lines[-1].strip():
		del sig_lines[-1]
	if sig_lines[-1].strip() != '-->':
		raise SafeException('Bad signature block: last line is not end-of-comment')
	sig_data = '\n'.join(sig_lines[1:-1])

	if re.match('^[ A-Za-z0-9+/=\n]+$', sig_data) is None:
		raise SafeException("Invalid characters found in base 64 encoded signature")
	try:
		sig_data = base64.decodestring(sig_data) # (b64decode is Python 2.4)
	except Exception, ex:
		raise SafeException("Invalid base 64 encoded signature: " + str(ex))

	sig_fd, sig_name = tempfile.mkstemp(prefix = 'injector-sig-')
	try:
		sig_file = os.fdopen(sig_fd, 'w')
		sig_file.write(sig_data)
		sig_file.close()

		status_r, status_w = os.pipe()

		child = os.fork()

		if child == 0:
			# We are the child
			try:
				try:
					os.close(status_r)
					os.dup2(data.fileno(), 0)
					os.dup2(errors.fileno(), 2)
					os.execlp('gpg', 'gpg', '--no-secmem-warning',
						   # Not all versions support this:
						   #'--max-output', str(1024 * 1024),
						   '--batch',
						   '--status-fd', str(status_w),
						   '--verify', sig_name, '-')
				except:
					traceback.print_exc()
			finally:
				os._exit(1)
			assert False
		
		# We are the parent
		os.close(status_w)

		try:
			sigs = _get_sigs_from_gpg_status_stream(status_r, child, errors)
		finally:
			os.lseek(stream.fileno(), 0, 0)
			stream.seek(0)
	finally:
		os.unlink(sig_name)
	return (stream, sigs)

def _find_in_path(prog):
	for d in os.environ['PATH'].split(':'):
		path = os.path.join(d, prog)
		if os.path.isfile(path):
			return path
	return None

def check_stream(stream):
	"""Pass stream through gpg --decrypt to get the data, the error text,
	and a list of signatures (good or bad). If stream starts with "<?xml "
	then get the signature from a comment at the end instead (and the returned
	data is the original stream). stream must be seekable.
	@return: (data_stream, [Signatures])"""
	if not _find_in_path('gpg'):
		raise SafeException("GnuPG is not installed ('gpg' not in $PATH). See http://gnupg.org")

	stream.seek(0)
	all = stream.read()
	stream.seek(0)

	start = stream.read(6)
	stream.seek(0)
	if start == "<?xml ":
		return _check_xml_stream(stream)
	else:
		os.lseek(stream.fileno(), 0, 0)
		return _check_plain_stream(stream)

def _get_sigs_from_gpg_status_stream(status_r, child, errors):
	"""Read messages from status_r and collect signatures from it.
	When done, reap 'child'.
	If there are no signatures, throw SafeException (using errors
	for the error message if non-empty)."""
	sigs = []

	# Should we error out on bad signatures, even if there's a good
	# signature too?

	for line in os.fdopen(status_r):
		assert line.endswith('\n')
		assert line.startswith('[GNUPG:] ')
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

	pid, status = os.waitpid(child, 0)
	assert pid == child

	errors.seek(0)

	error_messages = errors.read().strip()
	errors.close()

	if not sigs:
		if error_messages:
			raise SafeException("No signatures found. Errors from GPG:\n%s" % error_messages)
		else:
			raise SafeException("No signatures found. No error messages from GPG.")
	
	return sigs
