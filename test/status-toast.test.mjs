import test, { beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

import { showToast } from '../src/components/status.js';

let activeDocument = null;

class FakeClassList {
  constructor(owner) {
    this.owner = owner;
    this.tokens = new Set();
  }

  setFromString(value) {
    this.tokens = new Set(String(value || '').split(/\s+/).filter(Boolean));
    this.sync();
  }

  add(...names) {
    names.filter(Boolean).forEach(name => this.tokens.add(name));
    this.sync();
  }

  remove(...names) {
    names.forEach(name => this.tokens.delete(name));
    this.sync();
  }

  contains(name) {
    return this.tokens.has(name);
  }

  sync() {
    this.owner._className = [...this.tokens].join(' ');
  }
}

class FakeElement {
  constructor(tagName, ownerDocument) {
    this.tagName = String(tagName || 'div').toUpperCase();
    this.ownerDocument = ownerDocument;
    this.children = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.classList = new FakeClassList(this);
    this._className = '';
    this.textContent = '';
    this.type = '';
    this.onclick = null;
    this._connected = false;
  }

  get className() {
    return this._className;
  }

  set className(value) {
    this.classList.setFromString(value);
  }

  get isConnected() {
    if (this === this.ownerDocument.body) return this._connected;
    return Boolean(this.parentNode && this.parentNode.isConnected);
  }

  set innerHTML(value) {
    this.children.forEach(child => {
      child.parentNode = null;
      child._connected = false;
    });
    this.children = [];
    this.textContent = String(value || '');
  }

  appendChild(child) {
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  remove() {
    if (!this.parentNode) return;
    const siblings = this.parentNode.children;
    const index = siblings.indexOf(this);
    if (index >= 0) siblings.splice(index, 1);
    this.parentNode = null;
    this._connected = false;
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.get(name) || null;
  }

  querySelector(selector) {
    return querySelectorFrom(this, selector);
  }

  querySelectorAll(selector) {
    return querySelectorAllFrom(this, selector);
  }
}

function matchesSelector(node, selector) {
  if (!node) return false;
  if (selector.startsWith('.')) return node.classList.contains(selector.slice(1));
  return node.tagName.toLowerCase() === selector.toLowerCase();
}

function walk(node, visitor) {
  for (const child of node.children) {
    if (visitor(child)) return child;
    const nested = walk(child, visitor);
    if (nested) return nested;
  }
  return null;
}

function collect(node, selector, out = []) {
  for (const child of node.children) {
    if (matchesSelector(child, selector)) out.push(child);
    collect(child, selector, out);
  }
  return out;
}

function querySelectorFrom(node, selector) {
  return walk(node, child => matchesSelector(child, selector));
}

function querySelectorAllFrom(node, selector) {
  return collect(node, selector);
}

function installFakeDocument() {
  if (activeDocument?.body) activeDocument.body._connected = false;
  const doc = {
    body: null,
    createElement(tagName) {
      return new FakeElement(tagName, doc);
    },
    querySelector(selector) {
      if (matchesSelector(doc.body, selector)) return doc.body;
      return doc.body.querySelector(selector);
    },
    querySelectorAll(selector) {
      const all = matchesSelector(doc.body, selector) ? [doc.body] : [];
      return all.concat(doc.body.querySelectorAll(selector));
    }
  };
  doc.body = new FakeElement('body', doc);
  doc.body._connected = true;
  activeDocument = doc;
  globalThis.document = doc;
  globalThis.requestAnimationFrame = (callback) => {
    callback();
    return 1;
  };
}

beforeEach(() => {
  installFakeDocument();
});

afterEach(() => {
  if (activeDocument?.body) activeDocument.body._connected = false;
  delete globalThis.document;
  delete globalThis.requestAnimationFrame;
});

test('showToast 会创建全局 root 并显示 message', () => {
  showToast('已加入今日计划', { duration: Infinity });

  const root = document.querySelector('.km-toast-root');
  const toast = document.querySelector('.km-toast');
  const message = document.querySelector('.km-toast-message');

  assert.ok(root);
  assert.ok(toast);
  assert.equal(message.textContent, '已加入今日计划');
});

test('多次 showToast 不会创建多个 root，且新 Toast 会替换旧 Toast', () => {
  showToast('第一条', { duration: Infinity });
  showToast('第二条', { duration: Infinity });

  assert.equal(document.querySelectorAll('.km-toast-root').length, 1);
  assert.equal(document.querySelectorAll('.km-toast').length, 1);
  assert.equal(document.querySelector('.km-toast-message').textContent, '第二条');
});

test('showToast 支持 success / info / warning / error tone class', () => {
  for (const tone of ['success', 'info', 'warning', 'error']) {
    showToast(`${tone} message`, { tone, duration: Infinity });
    assert.ok(document.querySelector('.km-toast').classList.contains(`is-${tone}`));
  }
});

