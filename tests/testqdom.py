#!/usr/bin/env python2.5
from basetest import BaseTest
import sys
from StringIO import StringIO
import unittest

sys.path.insert(0, '..')

from zeroinstall.injector import qdom

def parseString(s):
	return qdom.parse(StringIO(s))

class TestQDom(BaseTest):
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
		assert root.childNodes == []

	def testNS(self):
		root = parseString('<?xml version="1.0"?>' +
			'<x:root xmlns:x="http://myns.com/foo"/>')
		assert root.name == 'root'
		assert root.uri == 'http://myns.com/foo'
		assert root.content == ''
		assert root.childNodes == []

	def testAttrs(self):
		root = parseString('<?xml version="1.0"?>' +
			'<root x:foo="bar" bar="baz" xmlns:x="http://myns.com/foo"/>')
		assert root.name == 'root'
		assert root.uri == None
		assert root.content == ''
		assert root.childNodes == []

		assert root.attrs.get('http://myns.com/foo foo') == 'bar'
		assert root.attrs.get('bar') == 'baz'

	def testNested(self):
		root = parseString('<?xml version="1.0"?><root>' +
			'<name>Bob</name><age>3</age></root>')
		assert root.name == 'root'
		assert root.uri == None
		assert root.content == ''
		assert len(root.childNodes) == 2

		assert root.childNodes[0].name == 'name'
		assert root.childNodes[0].uri == None
		assert root.childNodes[0].content == 'Bob'
		assert root.childNodes[0].childNodes == []

		assert root.childNodes[1].name == 'age'
		assert root.childNodes[1].uri == None
		assert root.childNodes[1].content == '3'
		assert root.childNodes[1].childNodes == []
	
	def testStr(self):
		root = parseString('<?xml version="1.0"?><root>' +
			'<sub x="2">hi</sub><empty/></root>')
		assert 'root' in str(root)

suite = unittest.makeSuite(TestQDom)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
