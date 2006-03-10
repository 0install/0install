#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
from StringIO import StringIO
import unittest

sys.path.insert(0, '..')

from zeroinstall.injector import qdom

def parseString(s):
	return qdom.parse(StringIO(s))

class TestQDom(unittest.TestCase):
	def testSimple(self):
		root = parseString('<?xml version="1.0"?><root/>')
		assert root.name == 'root'
		assert root.uri == None
		assert root.content == ''

	def testText(self):
		root = parseString('<?xml version="1.0"?><root> Hi </root>')
		assert root.name == 'root'
		assert root.uri == None
		assert root.content == 'Hi'
		assert root.children == []

	def testNS(self):
		root = parseString('<?xml version="1.0"?>' +
			'<x:root xmlns:x="http://myns.com/foo"/>')
		assert root.name == 'root'
		assert root.uri == 'http://myns.com/foo'
		assert root.content == ''
		assert root.children == []

	def testAttrs(self):
		root = parseString('<?xml version="1.0"?>' +
			'<root x:foo="bar" bar="baz" xmlns:x="http://myns.com/foo"/>')
		assert root.name == 'root'
		assert root.uri == None
		assert root.content == ''
		assert root.children == []

		assert root.attrs.get('http://myns.com/foo foo') == 'bar'
		assert root.attrs.get('bar') == 'baz'

	def testNested(self):
		root = parseString('<?xml version="1.0"?><root>' +
			'<name>Bob</name><age>3</age></root>')
		assert root.name == 'root'
		assert root.uri == None
		assert root.content == ''
		assert len(root.children) == 2

		assert root.children[0].name == 'name'
		assert root.children[0].uri == None
		assert root.children[0].content == 'Bob'
		assert root.children[0].children == []

		assert root.children[1].name == 'age'
		assert root.children[1].uri == None
		assert root.children[1].content == '3'
		assert root.children[1].children == []
	
	def testStr(self):
		"Mainly, this is for coverage."
		root = parseString('<?xml version="1.0"?><root>' +
			'<sub x="2">hi</sub><empty/></root>')
		assert 'root' in str(root)

suite = unittest.makeSuite(TestQDom)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
