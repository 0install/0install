#!/usr/bin/env python

from __future__ import print_function

import os, sys
import traceback

if sys.version_info[0] > 2:
	from urllib import parse as urlparse	# Python 3
	from http import server
	import pickle
else:
	import urlparse
	import BaseHTTPServer as server
	import cPickle as pickle

next_step = None

class Give404:
	def __init__(self, path):
		self.path = path

	def __str__(self):
		return self.path

	def __repr__(self):
		return "404 on " + self.path

request_log = []

class MyHandler(server.BaseHTTPRequestHandler):
	def __init__(self, *args):
		server.BaseHTTPRequestHandler.__init__(self, *args)

	def do_GET(self):
		request_log.append(self.path)

		parsed = urlparse.urlparse(self.path)

		print(parsed)
		if parsed.path.startswith('/redirect/'):
			self.send_response(302)
			self.send_header('Location', '/' + parsed.path[1:].split('/', 1)[1])
			self.end_headers()
			return

		leaf = os.path.basename(parsed.path)

		acceptable = dict([(str(x), x) for x in next_step])

		resp = acceptable.get(parsed.path, None) or \
		       acceptable.get(leaf, None) or \
		       acceptable.get('*', None)

		if parsed.path == '/0mirror/search/':
			q = self.path.split('?q=', 1)[1]
			leaf = 'search-' + q + '.xml'

		# (don't use a symlink as they don't work on Windows)
		if leaf == 'latest.xml':
			leaf = 'Hello.xml'
		elif parsed.path == '/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz':
			leaf = 'HelloWorld.tgz'
		elif parsed.path == '/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a':
			leaf = 'HelloWorld.tar.bz2'

		if not resp:
			self.send_error(404, "Expected %s; got %s" % (next_step, request_log))
		elif parsed.path.startswith('/key-info/'):
			self.send_response(200)
			self.end_headers()
			self.wfile.write(b'<key-lookup><item vote="good">Approved for testing</item></key-lookup>')
			self.wfile.close()
		elif os.path.exists(leaf) and not isinstance(resp, Give404):
			self.send_response(200)
			self.end_headers()
			with open(leaf, 'rb') as stream:
				self.wfile.write(stream.read())
			self.wfile.close()
		elif leaf == 'chunked':
			self.send_response(200)
			self.send_header('Transfer-Encoding', 'chunked')
			self.end_headers()
			self.wfile.write(
					b'a\r\n'
					b'hello worl\r\n'
					b'1\r\n'
					b'd\r\n'
                        )
			self.wfile.close()
		else:
			self.send_error(404, "Missing: %s" % leaf)

def handle_requests(*script):
	from subprocess import Popen, PIPE

	# Pass the script on the command line as a pickle.
	child = Popen(
		[sys.executable, __file__, repr(pickle.dumps(script)) ],
		stdout=PIPE, universal_newlines=True)

	# Make sure the server is actually running before we try to
	# interact with it.
	l = child.stdout.readline()
	assert l == 'Waiting for request\n', l
	return child

def main():
	# Grab the script that was passed on the command line from the parent
	script = pickle.loads(eval(sys.argv[1]))
	server_address = ('localhost', 8000)
	httpd = server.HTTPServer(server_address, MyHandler)
	try:
		sys.stderr = sys.stdout
		#sys.stdout = sys.stderr
		print("Waiting for request")
		sys.stdout.flush() # Make sure the "Waiting..." message is seen by the parent
		global next_step
		for next_step in script:
			if type(next_step) != tuple: next_step = (next_step,)
			for x in next_step:
				httpd.handle_request()
		print("Done")
		os._exit(0)
	except:
		traceback.print_exc()
		os._exit(1)

if __name__ == '__main__':
	# This is the child process.  We have to import ourself and
	# run the main routine there, or the pickled Give404 instances
	# passed from the parent won't be recognized as having the
	# same class (server.Give404).
	import server
	server.main()
