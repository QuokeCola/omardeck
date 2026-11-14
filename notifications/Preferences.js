var fields = [
  {key:"browserGrouping",type:"enum",label:"Group browser notifications by",defaultValue:"browser",options:["browser","hostname","none"]},
  {key:"useBrowserFavicons",type:"boolean",label:"Use website favicons",defaultValue:true},
  {key:"compact",type:"boolean",label:"Compact view",defaultValue:false},
  {key:"showPreview",type:"boolean",label:"Show pictures",defaultValue:true},
  {key:"keepDays",type:"integer",label:"Keep notifications (days)",defaultValue:30,min:1,max:365},
  {key:"maxItems",type:"integer",label:"Maximum notifications",defaultValue:1000,min:50,max:10000}
]
function field(key) {
  return fields.find(function(f) { return f.key === key }) || null
}
function valid(key,value) {
  var f = field(key)
  if (!f) return false
  if (f.type === "boolean") return typeof value === "boolean"
  if (f.type === "enum") return typeof value === "string" && f.options.indexOf(value) >= 0
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value && value >= f.min && value <= f.max
}
function value(settings,key) {
  var f = field(key)
  return f ? settings && valid(key,settings[key]) ? settings[key] : f.defaultValue : undefined
}
function saveCommand(key,next) {
  if (!valid(key,next)) return []
  // Leading whitespace keeps boolean JSON out of the IPC CLI's option parser.
  return ["omarchy-shell","shell","setBarWidget","quokecola.omardeck",key," " + JSON.stringify(next),"{}"]
}
function optionLabel(option) { return {browser:"Browser",hostname:"Hostname",none:"Do not group"}[option] || option }
if (typeof module !== "undefined") module.exports = {fields:fields,field:field,valid:valid,value:value,saveCommand:saveCommand,optionLabel:optionLabel}
