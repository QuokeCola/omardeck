const assert = require("node:assert/strict")
const Model = require("../Model.js")

assert.deepEqual(Model.unreadState([
  { timestamp: 300, urgency: 1 },
  { timestamp: 200, urgency: 0 },
  { timestamp: 100, urgency: 2 }
], 150), {
  unread: 2,
  hasCriticalUnread: false
})

assert.deepEqual(Model.unreadState([
  { timestamp: 300, urgency: 1 },
  { timestamp: 200, urgency: 2 },
  { timestamp: 100, urgency: 1 }
], 150), {
  unread: 2,
  hasCriticalUnread: true
})

assert.deepEqual(Model.unreadState([], 0), {
  unread: 0,
  hasCriticalUnread: false
})

assert.deepEqual(Model.unreadState(null, "invalid"), {
  unread: 0,
  hasCriticalUnread: false
})

console.log("Notification center model tests passed.")

// Icon colour ignores greys and follows the most common vivid hue.
{
  const px = (r, g, b, a = 255) => [r, g, b, a]
  const green = Array(20).fill(px(30, 200, 80)).flat()
  const red = Array(5).fill(px(220, 40, 40)).flat()
  const grey = Array(50).fill(px(128, 128, 128)).flat()
  const clear = Array(30).fill(px(255, 0, 0, 0)).flat()
  const rgb = Model.dominantColor([...grey, ...green, ...red, ...clear])
  assert.ok(rgb.g > rgb.r && rgb.g > rgb.b)
  assert.equal(Model.dominantColor([...grey, ...clear]), null)
  assert.equal(Model.dominantColor([...Array(200).fill(px(128, 128, 128)).flat(), ...red]), null)
}
