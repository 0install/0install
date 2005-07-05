#!/usr/bin/env python
import os
import BaseHTTPServer
from time import sleep

sleep_time = 0
day = 0

class MyHandler(BaseHTTPServer.BaseHTTPRequestHandler):
	def do_GET(self):
		if self.path.startswith('http://config/'):
			return self.config()
		leaf = os.path.basename(self.path)
		sleep(sleep_time)
		if os.path.exists(leaf):
			self.send_response(200)
			self.end_headers()
			self.wfile.write(file(leaf).read())
			self.wfile.close()
		else:
			self.send_error(404)
	
	def config(self):
		print "Config", self.path
		setting = os.path.basename(self.path)
		key, value = setting.split('=')
		if key == 'sleep':
			global sleep_time
			sleep_time = int(value)
		else:
			self.send_error(404)
			return
		self.send_response(200)

server_address = ('localhost', 8000)
print "To use:"
print "export http_proxy=http://localhost:8000"
httpd = BaseHTTPServer.HTTPServer(server_address, MyHandler)
httpd.serve_forever()
