import os
import tempfile
import traceback
from trust import trust_db
from model import SafeException

class Signature:
	status = None

	def __init__(self, status):
		self.status = status

	def is_trusted(self):
		return False
	
	def need_key(self):
		"""Returns the ID of the key that must be downloaded to check this signature."""
		return None

class ValidSig(Signature):
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
	KEYID = 0

	def __str__(self):
		return "BAD signature by " + self.status[self.KEYID] + \
			" (the message has been tampered with)"

class ErrSig(Signature):
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

def check_stream(stream):
	"""Pass stream through gpg --decrypt to get the data, the error text,
	and a list of signatures (good or bad).
	Returns (data_stream, [Signatures])."""
	status_r, status_w = os.pipe()

	data = tempfile.TemporaryFile()	# Python2.2 does not support 'prefix'
	errors = tempfile.TemporaryFile()

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

	data.seek(0)
	errors.seek(0)

	error_messages = errors.read().strip()
	errors.close()

	if error_messages and not sigs:
		raise SafeException("No signatures found. Errors from GPG:\n%s" % error_messages)
	
	return (data, sigs)
