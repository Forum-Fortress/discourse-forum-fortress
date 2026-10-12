'use strict';

// Forum Fortress security backport, MIT licensed like the upstream package.
// Bound every recursive traversal independently of caller-supplied options.
const MAX_DEPTH = 128;

const checkDepth = depth => {
  if (depth > MAX_DEPTH) {
    const error = new SyntaxError(`Brace structure exceeds maximum depth (${MAX_DEPTH})`);
    error.code = 'ERR_BRACES_MAX_DEPTH';
    throw error;
  }
};

const checkNode = node => {
  if (!node || typeof node !== 'object' || Array.isArray(node)) {
    throw new TypeError('Expected an AST node');
  }
  if (node.value !== undefined && typeof node.value !== 'string') {
    throw new TypeError('Expected a string AST node value');
  }
  if (node.nodes !== undefined && !Array.isArray(node.nodes)) {
    throw new TypeError('Expected an AST node array');
  }
};

module.exports = { MAX_DEPTH, checkDepth, checkNode };
