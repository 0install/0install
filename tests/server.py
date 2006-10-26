#!/usr/bin/env python
import os, sys
import BaseHTTPServer
import traceback

next_step = None

class MyHandler(BaseHTTPServer.BaseHTTPRequestHandler):
	def do_GET(self):
		leaf = os.path.basename(self.path)
		if leaf not in next_step:
			self.send_error(404, "Expected %s; got %s" % (next_step, leaf))
			
		if os.path.exists(leaf):
			self.send_response(200)
			self.end_headers()
			self.wfile.write(file(leaf).read())
			self.wfile.close()
		else:
			self.send_error(404, "Missing: %s" % leaf)

def handle_requests(*script):
	server_address = ('localhost', 8000)
	httpd = BaseHTTPServer.HTTPServer(server_address, MyHandler)
	child = os.fork()
	if child:
		return child
	# We are the child
	try:
		sys.stderr = sys.stdout
		print "Waiting for request"
		global next_step
		for next_step in script:
			if type(next_step) != tuple: next_step = (next_step,)
			for x in next_step:
				httpd.handle_request()
		print "Done"
		os._exit(0)
	except:
		traceback.print_exc()
		os._exit(1)
