import os
import tempfile
import traceback

class BadSignature(Exception):
	pass

def check_stream(stream):
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

	good_sig = False

	for line in os.fdopen(status_r):
		assert line.endswith('\n')
		assert line.startswith('[GNUPG:] ')
		line = line[9:-1]
		code = line.split(' ', 1)[0]
		if code == 'GOODSIG':
			good_sig = True

	pid, status = os.waitpid(child, 0)
	assert pid == child

	if good_sig:
		data.seek(0)
		return data
	
	errors.seek(0)
	raise BadSignature('No good signatures found:\n%s' % errors.read())
