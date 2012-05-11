"""Convenience functions for handling XML.
@since: 1.8
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from xml.dom import Node
		
def _compare_children(a, b):
	ac = a.childNodes
	bc = b.childNodes

	if ac.length != bc.length:
		return False
	
	for i in range(ac.length):
		if not nodes_equal(ac[i], bc[i]):
			return False

	return True

def nodes_equal(a, b):
	"""Compare two DOM nodes.
	Warning: only supports documents containing elements, text nodes and attributes (will crash on comments, etc).
	"""
	if a.nodeType != b.nodeType:
		return False

	if a.nodeType == Node.ELEMENT_NODE:
		if a.namespaceURI != b.namespaceURI:
			return False

		if a.nodeName != b.nodeName:
			return False
		
		a_attrs = set([(name, value) for name, value in a.attributes.itemsNS()])
		b_attrs = set([(name, value) for name, value in b.attributes.itemsNS()])

		if a_attrs != b_attrs:
			#print "%s != %s" % (a_attrs, b_attrs)
			return False

		return _compare_children(a, b)
	elif a.nodeType in (Node.TEXT_NODE, Node.CDATA_SECTION_NODE):
		return a.wholeText == b.wholeText
	elif a.nodeType == Node.DOCUMENT_NODE:
		return _compare_children(a, b)
	else:
		assert 0, ("Unknown node type", a)
