const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const test = require('node:test')
const source = fs.readFileSync(path.join(__dirname, '../Service.qml'), 'utf8')
function handler() {
  const start = source.indexOf('    function remove(keysCsv: string): string {')
  assert.notEqual(start,-1)
  const end = source.indexOf('\n    }',start)+6
  const calls=[]
  const context=vm.createContext({root:{removeMany(keys){calls.push(Array.from(keys))}}})
  vm.runInContext(source.slice(start,end).replace('(keysCsv: string): string','(keysCsv)'),context)
  return {calls,remove:context.remove}
}
test('public remove IPC accepts only bounded exact notification keys',()=>{
  const h=handler()
  for (const value of ['','../file','null',Array(101).fill('1000-1').join(',')]) assert.match(h.remove(value),/^error:/)
  assert.equal(h.calls.length,0)
  assert.equal(h.remove('1000-1,1001-2'),'ok')
  assert.deepEqual(h.calls,[['1000-1','1001-2']])
})

test('store commands cannot shadow panel open and close controls',()=>{
 assert.match(source,/target: "quokecola.omardeck.notifications.store"/)
 assert.doesNotMatch(source,/target: "quokecola.omardeck.notifications"/)
 const panel=fs.readFileSync(path.join(__dirname,'../Panel.qml'),'utf8')
 assert.match(panel,/ipcTarget: "quokecola.omardeck.notifications"/)
})
