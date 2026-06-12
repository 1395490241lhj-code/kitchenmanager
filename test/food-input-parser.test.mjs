// test/food-input-parser.test.mjs
// 「每行一个食材」轻量解析回归。纯函数，零网络/零 localStorage/零 DOM。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseFoodLines } from '../src/utils/food-input-parser.js';

test('名称 + 数量 + 单位（有无空格都支持）', () => {
  assert.deepEqual(parseFoodLines('鸡蛋 6个'), [{ name: '鸡蛋', qty: 6, unit: '个' }]);
  assert.deepEqual(parseFoodLines('鸡蛋 6 个'), [{ name: '鸡蛋', qty: 6, unit: '个' }]);
  assert.deepEqual(parseFoodLines('鸡蛋6个'), [{ name: '鸡蛋', qty: 6, unit: '个' }]);
});

test('只有数量没有单位 → unit 留空（由调用方推断）', () => {
  assert.deepEqual(parseFoodLines('鸡蛋 6'), [{ name: '鸡蛋', qty: 6, unit: '' }]);
});

test('只写名字 → qty=1，unit 留空', () => {
  assert.deepEqual(parseFoodLines('土豆'), [{ name: '土豆', qty: 1, unit: '' }]);
});

test('多行混合 + 空行忽略', () => {
  assert.deepEqual(parseFoodLines('鸡蛋 6个\n\n番茄 3个\n土豆\n   \n豆腐 1盒'), [
    { name: '鸡蛋', qty: 6, unit: '个' },
    { name: '番茄', qty: 3, unit: '个' },
    { name: '土豆', qty: 1, unit: '' },
    { name: '豆腐', qty: 1, unit: '盒' }
  ]);
});

test('小数数量', () => {
  assert.deepEqual(parseFoodLines('牛肉 1.5斤'), [{ name: '牛肉', qty: 1.5, unit: '斤' }]);
});

test('空字符串 / null / undefined → []', () => {
  assert.deepEqual(parseFoodLines(''), []);
  assert.deepEqual(parseFoodLines('   '), []);
  assert.deepEqual(parseFoodLines(null), []);
  assert.deepEqual(parseFoodLines(undefined), []);
});

test('中文数字 + 单位：行尾数量能被拆出来', () => {
  assert.deepEqual(parseFoodLines('鸡肉一份'), [{ name: '鸡肉', qty: 1, unit: '份' }]);
  assert.deepEqual(parseFoodLines('牛肉两份'), [{ name: '牛肉', qty: 2, unit: '份' }]);
  assert.deepEqual(parseFoodLines('鸡蛋三个'), [{ name: '鸡蛋', qty: 3, unit: '个' }]);
  assert.deepEqual(parseFoodLines('土豆两个'), [{ name: '土豆', qty: 2, unit: '个' }]);
  assert.deepEqual(parseFoodLines('白菜一颗'), [{ name: '白菜', qty: 1, unit: '颗' }]);
  assert.deepEqual(parseFoodLines('香菜一把'), [{ name: '香菜', qty: 1, unit: '把' }]);
  assert.deepEqual(parseFoodLines('豆腐一盒'), [{ name: '豆腐', qty: 1, unit: '盒' }]);
  assert.deepEqual(parseFoodLines('牛奶两瓶'), [{ name: '牛奶', qty: 2, unit: '瓶' }]);
  assert.deepEqual(parseFoodLines('木耳一包'), [{ name: '木耳', qty: 1, unit: '包' }]);
});

test('中文数字 + 单位：中间有空格也支持', () => {
  assert.deepEqual(parseFoodLines('鸡肉 一份'), [{ name: '鸡肉', qty: 1, unit: '份' }]);
  assert.deepEqual(parseFoodLines('鸡蛋 三个'), [{ name: '鸡蛋', qty: 3, unit: '个' }]);
});

test('中文数字 + 单位：半和十位数', () => {
  assert.deepEqual(parseFoodLines('牛肉半斤'), [{ name: '牛肉', qty: 0.5, unit: '斤' }]);
  assert.deepEqual(parseFoodLines('肉末半份'), [{ name: '肉末', qty: 0.5, unit: '份' }]);
  assert.deepEqual(parseFoodLines('鸡蛋十个'), [{ name: '鸡蛋', qty: 10, unit: '个' }]);
  assert.deepEqual(parseFoodLines('鸡蛋十二个'), [{ name: '鸡蛋', qty: 12, unit: '个' }]);
  assert.deepEqual(parseFoodLines('鸡蛋二十一个'), [{ name: '鸡蛋', qty: 21, unit: '个' }]);
});

test('中文数字防误解析：食材名里的数字不拆', () => {
  assert.deepEqual(parseFoodLines('二荆条'), [{ name: '二荆条', qty: 1, unit: '' }]);
  assert.deepEqual(parseFoodLines('十三香'), [{ name: '十三香', qty: 1, unit: '' }]);
  assert.deepEqual(parseFoodLines('三黄鸡'), [{ name: '三黄鸡', qty: 1, unit: '' }]);
  assert.deepEqual(parseFoodLines('五花肉'), [{ name: '五花肉', qty: 1, unit: '' }]);
  assert.deepEqual(parseFoodLines('八角'), [{ name: '八角', qty: 1, unit: '' }]);
});
