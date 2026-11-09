-- Headless smoke test with a small mocked Aseprite API.
local dialogs = {}
local savedImages = {}
local function Events()
  local events = { listeners = {}, nextCode = 0 }
  function events:on(name, fn)
    self.nextCode = self.nextCode + 1
    self.listeners[self.nextCode] = { name = name, fn = fn }
    return self.nextCode
  end
  function events:off(code) self.listeners[code] = nil end
  function events:emit(name, ev)
    for _, listener in pairs(self.listeners) do
      if listener.name == name then listener.fn(ev) end
    end
  end
  function events:count()
    local count = 0
    for _ in pairs(self.listeners) do count = count + 1 end
    return count
  end
  return events
end
ColorMode = { RGB = 1 }
BlendMode = { NORMAL = 0 }
MouseButton = { LEFT = 1 }

function Color(c)
  c.red, c.green, c.blue, c.alpha = c.r or 0, c.g or 0, c.b or 0, c.a or 255
  return c
end
function Rectangle(x, y, w, h) return { x=x, y=y, width=w, height=h } end
function Point(x, y) return { x=x, y=y } end

local pixelColor = {}
function pixelColor.rgba(r,g,b,a) return r + g*256 + b*65536 + a*16777216 end
function pixelColor.rgbaR(p) return p % 256 end
function pixelColor.rgbaG(p) return math.floor(p/256) % 256 end
function pixelColor.rgbaB(p) return math.floor(p/65536) % 256 end
function pixelColor.rgbaA(p) return math.floor(p/16777216) % 256 end

local ImageMethods = {}
ImageMethods.__index = ImageMethods
function Image(w,h)
  local img = { width=w, height=h, data={} }
  for i=1,w*h do img.data[i]=0 end
  img.bounds = Rectangle(0,0,w,h)
  return setmetatable(img, ImageMethods)
end
function ImageMethods:putPixel(x,y,p) self.data[y*self.width+x+1]=p end
function ImageMethods:getPixel(x,y) return self.data[y*self.width+x+1] end
function ImageMethods:pixels()
  local x,y=0,0
  return function()
    if y>=self.height then return nil end
    local it={x=x,y=y}
    local px,py=x,y
    setmetatable(it,{__call=function() return self.data[py*self.width+px+1] end})
    x=x+1; if x>=self.width then x=0;y=y+1 end
    return it
  end
end
function ImageMethods:drawImage(src,pos,opacity,blend)
  for y=0,src.height-1 do for x=0,src.width-1 do
    local dx,dy=x+(pos and pos.x or 0),y+(pos and pos.y or 0)
    if dx>=0 and dy>=0 and dx<self.width and dy<self.height then
      self.data[dy*self.width+dx+1]=src.data[y*src.width+x+1]
    end
  end end
end
function ImageMethods:drawSprite(sprite,frame) self:drawImage(sprite.mockImage,Point(0,0)) end
function ImageMethods:isEqual(other)
  if self.width~=other.width or self.height~=other.height then return false end
  for i=1,#self.data do if self.data[i]~=other.data[i] then return false end end
  return true
end
function ImageMethods:saveAs(args)
  local filename=type(args)=="table" and args.filename or args
  savedImages[#savedImages+1]={filename=filename,image=self}
end

local sprite
local function newLayer(name)
  local layer={name=name,isGroup=false,isVisible=true,isEditable=true,opacity=255,
    blendMode=0,sprite=sprite,stackIndex=#sprite.layers+1,parent=sprite}
  function layer:cel(frame) return self._cel end
  return layer
end
sprite={width=16,height=16,layers={},frames={{frameNumber=1}},filename="",events=Events()}
sprite.mockImage=Image(16,16)
for y=2,13 do for x=2,13 do
  sprite.mockImage:putPixel(x,y,pixelColor.rgba(60+x*8,80+y*5,120,255))
end end
function sprite:newLayer()
  local l=newLayer("Layer"); self.layers[#self.layers+1]=l; return l
end
function sprite:newCel(layer,frame,image,pos)
  layer._cel={image=image,position=pos or Point(0,0)}; return layer._cel
end
local base=sprite:newLayer();base.name="角色";base._cel={image=sprite.mockImage,position=Point(0,0)}

local gc={}
for _,name in ipairs({"fillRect","beginPath","moveTo","lineTo","stroke","fillText"}) do
  gc[name]=function() end
end
function gc:drawImage(src) self.lastDrawn=src end
app={sprite=sprite,layer=base,frame=sprite.frames[1],pixelColor=pixelColor,events=Events(),
  theme={color={window_face=Color{r=20,g=20,b=20}}}}
function app.alert(args) error(args.text or args) end
function app.transaction(name,fn) fn() end
function app.refresh() end

local DialogMethods={}
DialogMethods.__index=DialogMethods
local function store(d,id,args)
  d.widgets[id]=args
  if args.value~=nil then d.data[id]=args.value end
  if args.option~=nil then d.data[id]=args.option end
  if args.selected~=nil then d.data[id]=args.selected end
  if args.color~=nil then d.data[id]=args.color end
  if args.filename~=nil then d.data[id]=args.filename end
  if args.text~=nil and args.id then d.data[id]=args.text end
end
function Dialog(opts)
  local d=setmetatable({data={},widgets={},visible=false,onclose=opts.onclose,title=opts.title,
    notitlebar=opts.notitlebar},DialogMethods)
  dialogs[#dialogs+1]=d
  return d
end
for _,name in ipairs({"combobox","slider","check","color","file","label","canvas"}) do
  DialogMethods[name]=function(self,args) store(self,args.id,args); return self end
end
function DialogMethods:button(args) store(self,args.text,args); return self end
function DialogMethods:modify(args)
  local w=self.widgets[args.id]
  for k,v in pairs(args) do
    if k~="id" then self.data[args.id]=v; if w then w[k]=v end end
  end
end
function DialogMethods:show(args) self.visible=true end
function DialogMethods:close()
  if not self.visible then return end
  self.visible=false
  if self.onclose then self.onclose() end
end
function DialogMethods:repaint()
  for _,w in pairs(self.widgets) do
    if w.onpaint then
      gc.width,gc.height=w.width,w.height
      w.onpaint{context=gc}
    end
  end
end

local commands={}
local plugin={}
function plugin:newCommand(args) commands[args.id]=args end
package.path="./?.lua;"..package.path
dofile("main.lua")
init(plugin)
assert(commands.AsepriteNormalLighterNormal and commands.AsepriteNormalLighterMask
  and commands.AsepriteNormalLighterNormalEditor)
assert(commands.AsepriteNormalLighterNormal.group=="edit_fx")
assert(commands.AsepriteNormalLighterMask.group=="edit_fx")
assert(commands.AsepriteNormalLighterNormalEditor.group=="edit_fx")

local function findDialog(title)
  for i=#dialogs,1,-1 do
    if dialogs[i].title==title then return dialogs[i] end
  end
end

commands.AsepriteNormalLighterNormal.onclick()
local nd=dialogs[#dialogs]
assert(nd.title=="生成法线贴图" and nd.data.status=="已生成")
assert(nd.widgets.zoom.option=="适应窗口")
local foundLayerName=false
for _,option in ipairs(nd.widgets.source.options) do
  assert(option~="具体图层")
  if option=="角色" then foundLayerName=true end
end
assert(foundLayerName)
nd.widgets["确定"].onclick()
assert(#sprite.layers==2 and sprite.layers[2].name=="Normal")
local preview=findDialog("光照预览")
local settings=findDialog("光照设置")
assert(preview and preview.visible and preview.notitlebar~=true)
assert(preview.widgets.lightCanvas.height==360)
assert(settings and settings.visible)
preview:repaint()
local canvas=preview.widgets.lightCanvas
local oldX=settings.data.lightX
canvas.onmousemove{x=100,y=100}
assert(settings.data.lightX~=oldX or settings.data.lightY~=10)
settings.widgets["关闭"].onclick()
assert(preview.visible and not settings.visible)
preview:close()

commands.AsepriteNormalLighterNormal.onclick()
nd=dialogs[#dialogs]
nd.widgets["应用"].onclick()
assert(#sprite.layers==3 and sprite.layers[3].name=="Normal")
assert(sprite.layers[3].stackIndex==2 and sprite.layers[3]._cel.image.width==16)
assert(nd.visible)
preview=findDialog("光照预览")
settings=findDialog("光照设置")
assert(preview and preview.visible and preview.notitlebar~=true)
assert(settings and settings.visible)
nd:close()
preview:close()
assert(not settings.visible)

commands.AsepriteNormalLighterMask.onclick()
local md=dialogs[#dialogs]
assert(md.title=="生成光线遮罩" and md.data.status=="已生成")
md.widgets["应用"].onclick()
assert(#sprite.layers==4 and sprite.layers[4].name=="Light Mask")
assert(sprite.layers[4]._cel.image.width==16)
assert(md.visible)
preview=findDialog("光照预览")
settings=findDialog("光照设置")
assert(preview and preview.visible and preview.notitlebar~=true)
assert(settings and settings.visible)
preview:close()
md:close()

-- Persistent editor: detect a Normal layer, react to edits, allow manual refresh,
-- keep the window open, and export the current relighted image.
commands.AsepriteNormalLighterNormalEditor.onclick()
local editor=findDialog("法线贴图编辑")
assert(editor and editor.visible and editor.data.autoRefresh)
assert(editor.widgets["刷新"] and editor.widgets["导出光照图"])
assert(editor.data.editorStatus:match("已刷新：Normal"))
local editedNormal=sprite.layers[3]
assert(editedNormal.name=="Normal")
local beforeEdit=gc.lastDrawn:getPixel(2,2)
editedNormal._cel.image:putPixel(2,2,pixelColor.rgba(255,128,64,255))
sprite.events:emit("change")
assert(editor.visible and editor.data.editorStatus:match("已自动刷新"))
local afterEdit=gc.lastDrawn:getPixel(2,2)
assert(beforeEdit~=afterEdit)

editor.data.autoRefresh=false
editor.widgets.autoRefresh.onclick()
local automaticImage=gc.lastDrawn
editedNormal._cel.image:putPixel(2,2,pixelColor.rgba(128,128,255,255))
sprite.events:emit("change")
assert(editor.visible and editor.data.editorStatus:match("点击“刷新”"))
assert(gc.lastDrawn==automaticImage)
editor.widgets["刷新"].onclick()
assert(editor.data.editorStatus:match("已刷新：Normal"))
assert(not gc.lastDrawn:isEqual(automaticImage))

editor.data.exportPath="/mock/edited-lighting"
editor.widgets["导出光照图"].onclick()
assert(#savedImages==1 and savedImages[1].filename=="/mock/edited-lighting.png")
assert(savedImages[1].image.width==16 and savedImages[1].image.height==16)
assert(editor.data.editorStatus:match("已导出光照图"))
editor:close()
assert(sprite.events:count()==0 and app.events:count()==0)
print("Mocked generation, persistent normal editing, automatic/manual refresh and PNG export passed.")
