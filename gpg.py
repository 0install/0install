import os
import tempfile
import traceback
from trust import trust_db

class Signature:
	def is_trusted(self):
		return False

class ValidSig(Signature):
	def __init__(self, fingerprint):
		self.fingerprint = fingerprint
	
	def __str__(self):
		return "Valid signature from " + self.fingerprint
	
	def is_trusted(self):
		return trust_db.is_trusted(self.fingerprint)

class BadSig(Signature):
	def __init__(self, keyid):
		self.keyid = keyid

class ErrSig(Signature):
	def __init__(self, keyid):
		self.keyid = keyid

def check_stream(stream):
	"""Pass stream through gpg --decrypt to get the data, the error text,
	and a list of signatures (good or bad).
	Returns (data_stream, errors, [Signatures])."""
	status_r, status_w = os.pipe()

	data = tempfile.TemporaryFile(prefix = 'injector-gpg-')
	errors = tempfile.TemporaryFile(prefix = 'injector-gpg-errors-')

	child = os.fork()

	if child == 0:
		# We are the child
		try:
			try:
				os.close(status_r)
				os.dup2(stream.fileno(), 0)
				os.dup2(data.fileno(), 1)
				os.dup2(errors.fileno(), 2)
				os.execlp('gpg', 'gpg', '--decrypt',
					   '--max-output', str(1024 * 1024),
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
		code = line.split(' ', 1)[0]
		if code == 'VALIDSIG':
			sigs.append(ValidSig(line.split(' ', 2)[1]))
		elif code == 'BADSIG':
			sigs.append(BadSig(line.split(' ', 2)[1]))
		elif code == 'ERRSIG':
			sigs.append(ErrSig(line.split(' ', 2)[1]))

	pid, status = os.waitpid(child, 0)
	assert pid == child

	data.seek(0)
	errors.seek(0)
	return (data, errors.read(), sigs)
