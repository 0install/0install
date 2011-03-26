"""A quick DOM implementation.

Python's xml.dom is very slow. The xml.sax module is also slow (as it imports urllib2).
This is our light-weight version.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from xml.parsers import expat

class Element(object):
	"""An XML element.
	@ivar uri: the element's namespace
	@type uri: str
	@ivar name: the element's localName
	@type name: str
	@ivar attrs: the element's attributes (key is in the form [namespace " "] localName)
	@type attrs: {str: str}
	@ivar childNodes: children
	@type childNodes: [L{Element}]
	@ivar content: the text content
	@type content: str"""
	__slots__ = ['uri', 'name', 'attrs', 'childNodes', 'content']
	def __init__(self, uri, name, attrs):
		self.uri = uri
		self.name = name
		self.attrs = attrs.copy()
		self.content = None
		self.childNodes = []
	
	def __str__(self):
		attrs = [n + '=' + self.attrs[n] for n in self.attrs]
		start = '<{%s}%s %s' % (self.uri, self.name, ' '.join(attrs))
		if self.childNodes:
			return start + '>' + '\n'.join(map(str, self.childNodes)) + ('</%s>' % (self.name))
		elif self.content:
			return start + '>' + self.content + ('</%s>' % (self.name))
		else:
			return start + '/>'
	
	def getAttribute(self, name):
		return self.attrs.get(name, None)

	def toDOM(self, doc, prefixes):
		"""Create a DOM Element for this qdom.Element.
		@param doc: document to use to create the element
		@return: the new element
		"""
		elem = prefixes.createElementNS(doc, self.uri, self.name)

		for fullname, value in self.attrs.iteritems():
			if ' ' in fullname:
				ns, localName = fullname.split(' ', 1)
			else:
				ns, localName = None, fullname
			prefixes.setAttributeNS(elem, ns, localName, value)
		for child in self.childNodes:
			elem.appendChild(child.toDOM(doc, prefixes))
		if self.content:
			elem.appendChild(doc.createTextNode(self.content))
		return elem

class QSAXhandler:
	"""SAXHandler that builds a tree of L{Element}s"""
	def __init__(self):
		self.stack = []
	
	def startElementNS(self, fullname, attrs):
		split = fullname.split(' ', 1)
		if len(split) == 2:
			self.stack.append(Element(split[0], split[1], attrs))
		else:
			self.stack.append(Element(None, fullname, attrs))
		self.contents = ''
	
	def characters(self, data):
		self.contents += data
	
	def endElementNS(self, name):
		contents = self.contents.strip()
		self.stack[-1].content = contents
		self.contents = ''
		new = self.stack.pop()
		if self.stack:
			self.stack[-1].childNodes.append(new)
		else:
			self.doc = new

def parse(source):
	"""Parse an XML stream into a tree of L{Element}s.
	@param source: data to parse
	@type source: file
	@return: the root
	@rtype: L{Element}"""
	handler = QSAXhandler()
	parser = expat.ParserCreate(namespace_separator = ' ')

	parser.StartElementHandler = handler.startElementNS
	parser.EndElementHandler = handler.endElementNS
	parser.CharacterDataHandler = handler.characters

	parser.ParseFile(source)
	return handler.doc

class Prefixes:
	"""Keep track of namespace prefixes. Used when serialising a document.
	@since: 0.54
	"""
	def __init__(self, default_ns):
		self.prefixes = {}
		self.default_ns = default_ns

	def get(self, ns):
		prefix = self.prefixes.get(ns, None)
		if prefix:
			return prefix
		prefix = 'ns%d' % len(self.prefixes)
		self.prefixes[ns] = prefix
		return prefix

	def setAttributeNS(self, elem, uri, localName, value):
		if uri is None:
			elem.setAttributeNS(None, localName, value)
		else:
			elem.setAttributeNS(uri, self.get(uri) + ':' + localName, value)
	
	def createElementNS(self, doc, uri, localName):
		if uri == self.default_ns:
			return doc.createElementNS(uri, localName)
		else:
			return doc.createElementNS(uri, self.get(uri) + ':' + localName)
