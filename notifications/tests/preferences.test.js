const test = require('node:test')
const assert = require('node:assert/strict')
const P = require('../Preferences.js')

test('settings validate integers and booleans without coercion', () => {
  for (const [key,value] of [['keepDays',30],['browserGrouping','hostname'],['compact',false]]) assert.equal(P.valid(key,value),true)
  for (const [key,value] of [['keepDays',0],['keepDays',1.2],['maxItems',49],['compact','false'],['browserGrouping','group'],['normalTimeoutSec',8]]) assert.equal(P.valid(key,value),false)
  assert.equal(P.value({},'compact'),false)
})
test('saving goes through the widget settings IPC', () => {
  assert.deepEqual(P.saveCommand('compact',true), ['omarchy-shell','shell','setBarWidget','quokecola.omardeck','compact',' true','{}'])
  assert.deepEqual(P.saveCommand('normalTimeoutSec',12), [])
})
