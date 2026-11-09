-- Aseprite_normal_lighter
-- Normal-map and light-mask generation with an optional relighting preview.
-- Original TypeScript project: https://github.com/rhinoc/xprite-lighter

local Lighter = require("lighter")
local normalDialog = nil
local maskDialog = nil
local lightPreviewDialog = nil
local lightSettingsDialog = nil
local normalEditorDialog = nil
local session = nil
local editorSession = nil
local editorSpriteConnections = nil
local editorSiteConnection = nil
local refreshingEditor = false
local closingPreview = false

local SOURCE_MODES = { "所有图层", "可见图层" }
local PRESETS = { "object", "character", "architecture", "terrain" }
local PRESET_LABELS = { object = "物件", character = "角色", architecture = "建筑", terrain = "地形" }
local PRESET_VALUES = { "物件", "角色", "建筑", "地形" }
local ZOOM_VALUES = { "适应窗口", "100%", "200%", "400%", "800%", "1000%" }

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function showError(message)
  app.alert{ title = "Aseprite Normal Lighter", text = tostring(message) }
end

local function imageToBuffer(image)
  local w, h = image.width, image.height
  local data = {}
  for i = 1, w * h * 4 do data[i] = 0 end
  for it in image:pixels() do
    local pixel = it()
    local at = (it.y * w + it.x) * 4 + 1
    data[at] = app.pixelColor.rgbaR(pixel)
    data[at + 1] = app.pixelColor.rgbaG(pixel)
    data[at + 2] = app.pixelColor.rgbaB(pixel)
    data[at + 3] = app.pixelColor.rgbaA(pixel)
  end
  return { width = w, height = h, data = data }
end

local function bufferToImage(buffer)
  local image = Image(buffer.width, buffer.height, ColorMode.RGB)
  local data = buffer.data
  for y = 0, buffer.height - 1 do
    for x = 0, buffer.width - 1 do
      local at = (y * buffer.width + x) * 4 + 1
      image:putPixel(x, y, app.pixelColor.rgba(data[at], data[at + 1],
        data[at + 2], data[at + 3]))
    end
  end
  return image
end

local function collectLayers(sprite)
  local entries, usedLabels = {}, {}
  local function walk(layers, depth)
    for _, layer in ipairs(layers) do
      local baseLabel = string.rep("　", depth) .. layer.name
      local label = baseLabel
      local suffix = 2
      while usedLabels[label] do
        label = baseLabel .. " (" .. suffix .. ")"
        suffix = suffix + 1
      end
      usedLabels[label] = true
      entries[#entries + 1] = { layer = layer, label = label }
      if layer.isGroup and layer.layers then walk(layer.layers, depth + 1) end
    end
  end
  walk(sprite.layers, 0)
  return entries
end

local function layerLabel(entries, wanted)
  if wanted then
    for _, entry in ipairs(entries) do
      if entry.layer == wanted then return entry.label end
    end
  end
  return entries[1] and entries[1].label or ""
end

local function layerFromLabel(entries, label)
  for _, entry in ipairs(entries) do
    if entry.label == label then return entry.layer end
  end
  return entries[1] and entries[1].layer or nil
end

local function drawLayer(image, layer, frameNumber)
  if layer.isGroup then
    if layer.layers then
      for _, child in ipairs(layer.layers) do drawLayer(image, child, frameNumber) end
    end
    return
  end
  local cel = layer:cel(frameNumber)
  if cel and cel.image then
    image:drawImage(cel.image, cel.position, layer.opacity or 255,
      layer.blendMode or BlendMode.NORMAL)
  end
end

local function sourceImage(sprite, mode, specificLayer)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  local frameNumber = app.frame.frameNumber
  if mode == "可见图层" then
    image:drawSprite(sprite, frameNumber)
  elseif mode == "所有图层" then
    for _, layer in ipairs(sprite.layers) do drawLayer(image, layer, frameNumber) end
  elseif specificLayer then
    drawLayer(image, specificLayer, frameNumber)
  end
  return image
end

local function countForeground(buffer)
  local count = 0
  for i = 4, #buffer.data, 4 do if buffer.data[i] > 0 then count = count + 1 end end
  return count
end

local function presetFromLabel(label)
  for _, preset in ipairs(PRESETS) do
    if PRESET_LABELS[preset] == label then return preset end
  end
  return "object"
end

local function zoomScale(zoom, canvasWidth, canvasHeight, imageWidth, imageHeight)
  if zoom ~= "适应窗口" then
    return math.max(0.01, tonumber(zoom:match("^(%d+)%%")) / 100)
  end
  local scale = math.min((canvasWidth - 12) / imageWidth,
    (canvasHeight - 12) / imageHeight)
  if scale > 1 then scale = math.max(1, math.floor(scale)) end
  return math.max(0.01, scale)
end

local function checkerboard(gc, x, y, w, h)
  local cell = 8
  gc.color = Color{ r = 204, g = 204, b = 204, a = 255 }
  gc:fillRect(Rectangle(x, y, w, h))
  gc.color = Color{ r = 232, g = 232, b = 232, a = 255 }
  local row = 0
  for cy = y, y + h - 1, cell do
    local col = 0
    for cx = x, x + w - 1, cell do
      if (row + col) % 2 == 0 then
        gc:fillRect(Rectangle(cx, cy, math.min(cell, x + w - cx),
          math.min(cell, y + h - cy)))
      end
      col = col + 1
    end
    row = row + 1
  end
end

local function updateEstimateLabel(dlg)
  if not session or not session.normalGenerator then return end
  local estimate = session.normalGenerator.getPaintedLightEstimate()
  if estimate then
    dlg:modify{ id = "estimate", text = string.format("估计：%d°，置信度 %.2f",
      estimate.angle, estimate.fit) }
  else
    dlg:modify{ id = "estimate", text = "估计：没有可靠方向" }
  end
end

local function currentDelight()
  if not session or not session.light.delight then return nil end
  local angle = session.normal.paintedLightAngle
  if session.normal.autoAngle then
    local estimate = session.normalGenerator.getPaintedLightEstimate()
    if estimate then angle = estimate.angle end
  end
  return { angle = angle, influence = session.light.delightInfluence }
end

local function renderLighting()
  if not session or not session.prepared then return end
  local w, h = session.albedo.width, session.albedo.height
  local options = Lighter.defaultNormalMapLightOptions(w, h)
  options.position = { x = session.light.x / 100 * w, y = session.light.y / 100 * h }
  options.height = session.light.height
  options.brightness = session.light.brightness
  options.ambient = session.light.ambient
  options.maskStrength = session.light.maskStrength
  options.invertY = session.normal.invertY
  options.color = session.light.color
  options.delight = currentDelight()
  session.outputs.relighted = Lighter.renderPreparedNormalMapLighting(session.prepared, options)
  if options.delight then
    session.outputs.delit = Lighter.removePaintedLight(session.prepared,
      options.delight, options.invertY)
  else
    session.outputs.delit = session.albedo
  end
end

local function generateMaps()
  if not session or not session.normalGenerator then return end
  local n = session.normal
  local normalOptions = {
    preset = n.preset, shapeStrength = n.shapeStrength,
    normalStrength = n.normalStrength, smoothing = n.smoothing, facets = n.facets,
    mergeOutlines = n.mergeOutlines, invertY = n.invertY,
    paintedLightInfluence = n.paintedInfluence,
  }
  if not n.autoAngle then normalOptions.paintedLightAngle = n.paintedLightAngle end
  session.outputs.normal = session.normalGenerator.generate(normalOptions)
  session.outputs.mask = session.maskGenerator.generate(session.mask)
  session.prepared = Lighter.prepareNormalMapLighting(session.albedo,
    session.outputs.normal, session.outputs.mask)
  renderLighting()
end

local function rebuildSource(mode, specificLayer)
  if not session then return false end
  local image = sourceImage(session.sprite, mode, specificLayer)
  local albedo = imageToBuffer(image)
  if countForeground(albedo) == 0 then
    showError("所选来源在当前帧没有可见像素。")
    return false
  end
  session.sourceMode = mode
  session.sourceLayer = specificLayer or session.sourceLayer
  session.albedo = albedo
  session.normalGenerator = Lighter.createNormalMapGenerator(albedo)
  session.maskGenerator = Lighter.createLightMaskGenerator(albedo)
  session.prepared = nil
  session.outputs = {}
  return true
end

local function sourceFromDialog(dlg)
  local selection = dlg.data.source
  if selection == "所有图层" or selection == "可见图层" then
    return selection, session.sourceLayer
  end
  return selection, layerFromLabel(session.layerEntries, selection)
end

local function changeSource(dlg)
  local mode, specific = sourceFromDialog(dlg)
  if rebuildSource(mode, specific) then
    local ok, err = pcall(generateMaps)
    if not ok then showError(err) end
    dlg:repaint()
    if lightPreviewDialog then lightPreviewDialog:repaint() end
    return true
  end
  dlg:modify{ id = "source", option = session.sourceMode }
  return false
end

local function drawPreview(ev, dlg, kind)
  local gc = ev.context
  gc.color = app.theme.color.window_face
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  if not session then return end
  local buffer
  if kind == "normal" then
    local mode = dlg.data.previewMode or "法线贴图"
    buffer = mode == "原图" and session.albedo
      or mode == "光照" and session.outputs.relighted or session.outputs.normal
  elseif kind == "mask" then
    local mode = dlg.data.previewMode or "光照遮罩"
    buffer = mode == "原图" and session.albedo
      or mode == "光照" and session.outputs.relighted or session.outputs.mask
  else
    buffer = session.outputs.relighted
  end
  if not buffer then return end
  local image = bufferToImage(buffer)
  local w, h = image.width, image.height
  local scale = zoomScale(dlg.data.zoom or "适应窗口", gc.width, gc.height, w, h)
  local dw, dh = w * scale, h * scale
  local ox = math.floor((gc.width - dw) / 2)
  local oy = math.floor((gc.height - dh) / 2)
  checkerboard(gc, ox, oy, dw, dh)
  gc.antialias = false
  gc:drawImage(image, image.bounds, Rectangle(ox, oy, dw, dh))
  if kind == "light" then
    session.lightDrawInfo = { x = ox, y = oy, scale = scale, width = w, height = h }
    local lx, ly = ox + session.light.x / 100 * dw, oy + session.light.y / 100 * dh
    gc.color = Color{ r = 255, g = 255, b = 255, a = 220 }
    gc.strokeWidth = 1
    gc:beginPath()
    gc:moveTo(lx - 5, ly); gc:lineTo(lx + 5, ly)
    gc:moveTo(lx, ly - 5); gc:lineTo(lx, ly + 5); gc:stroke()
  end
end

local function refreshLightPreview()
  if not session or not session.prepared then return end
  local ok, err = pcall(renderLighting)
  if not ok then showError(err); return end
  if lightPreviewDialog then lightPreviewDialog:repaint() end
end

local function moveLightFromMouse(ev)
  if not session or not session.lightDrawInfo then return end
  local info = session.lightDrawInfo
  local x = clamp((ev.x - info.x) / info.scale, 0, info.width - 1)
  local y = clamp((ev.y - info.y) / info.scale, 0, info.height - 1)
  session.light.x = math.floor(x / info.width * 100 + 0.5)
  session.light.y = math.floor(y / info.height * 100 + 0.5)
  if lightSettingsDialog then
    lightSettingsDialog:modify{ id = "lightX", value = session.light.x }
    lightSettingsDialog:modify{ id = "lightY", value = session.light.y }
  end
  refreshLightPreview()
end

local function closeLightSettings()
  if lightSettingsDialog then lightSettingsDialog:close(); lightSettingsDialog = nil end
end

local function closeLightPreview()
  if closingPreview then return end
  closingPreview = true
  closeLightSettings()
  if lightPreviewDialog then lightPreviewDialog:close(); lightPreviewDialog = nil end
  closingPreview = false
end

local function openLightSettings()
  if not session or lightSettingsDialog then return end
  local settings = Dialog{ title = "光照设置", resizeable = true,
    onclose = function() if lightSettingsDialog == settings then lightSettingsDialog = nil end end }
  lightSettingsDialog = settings
  settings:combobox{ id = "source", label = "原图", options = session.sourceOptions,
    option = session.sourceMode, onchange = function() changeSource(settings) end }
  settings:combobox{ id = "normalMap", label = "法线贴图", options = { "Normal" }, option = "Normal" }
  settings:slider{ id = "lightHeight", label = "灯光高度", min = 1, max = 600,
    value = session.light.height, onrelease = function()
      session.light.height = settings.data.lightHeight; refreshLightPreview() end }
  settings:slider{ id = "brightness", label = "亮度", min = 0, max = 500,
    value = session.light.brightness, onrelease = function()
      session.light.brightness = settings.data.brightness; refreshLightPreview() end }
  settings:slider{ id = "ambient", label = "环境光", min = 0, max = 100,
    value = session.light.ambient, onrelease = function()
      session.light.ambient = settings.data.ambient; refreshLightPreview() end }
  settings:color{ id = "lightColor", label = "灯光颜色",
    color = Color{ r = session.light.color[1], g = session.light.color[2],
      b = session.light.color[3], a = 255 }, onchange = function()
      local c = settings.data.lightColor
      session.light.color = { c.red, c.green, c.blue, c.alpha }
      refreshLightPreview()
    end }
  settings:check{ id = "followPointer", text = "跟随指针",
    selected = session.light.followPointer, onclick = function()
      session.light.followPointer = settings.data.followPointer end }
  settings:check{ id = "delight", text = "去除原画明暗",
    selected = session.light.delight, onclick = function()
      session.light.delight = settings.data.delight; refreshLightPreview() end }
  settings:check{ id = "invertY", text = "反转 Y（DirectX）",
    selected = session.normal.invertY, onclick = function()
      session.normal.invertY = settings.data.invertY
      local ok, err = pcall(generateMaps)
      if not ok then showError(err) end
      if lightPreviewDialog then lightPreviewDialog:repaint() end
    end }
  settings:slider{ id = "lightX", label = "光源 X %", min = 0, max = 100,
    value = session.light.x, onrelease = function()
      session.light.x = settings.data.lightX; refreshLightPreview() end }
  settings:slider{ id = "lightY", label = "光源 Y %", min = 0, max = 100,
    value = session.light.y, onrelease = function()
      session.light.y = settings.data.lightY; refreshLightPreview() end }
  settings:slider{ id = "maskStrength", label = "遮罩强度", min = 0, max = 100,
    value = session.light.maskStrength, onrelease = function()
      session.light.maskStrength = settings.data.maskStrength; refreshLightPreview() end }
  settings:slider{ id = "delightInfluence", label = "去明暗强度", min = 0, max = 100,
    value = session.light.delightInfluence, onrelease = function()
      session.light.delightInfluence = settings.data.delightInfluence; refreshLightPreview() end }
  settings:button{ text = "关闭", onclick = closeLightSettings }
  settings:show{ wait = false, autoscrollbars = true }
end

local function openLightPreview()
  if not session or not session.outputs.normal then return end
  closeLightPreview()
  local preview = Dialog{ title = "光照预览", resizeable = true,
    onclose = function()
      if lightPreviewDialog == preview then lightPreviewDialog = nil end
      if not closingPreview then closeLightSettings() end
    end }
  lightPreviewDialog = preview
  preview:canvas{ id = "lightCanvas", width = 480, height = 360,
    hexpand = true, vexpand = true,
    onpaint = function(ev) drawPreview(ev, preview, "light") end,
    onmousedown = function(ev)
      if ev.button == MouseButton.LEFT then
        session.draggingLight = true; moveLightFromMouse(ev)
      end
    end,
    onmousemove = function(ev)
      if session.light.followPointer or session.draggingLight then
        moveLightFromMouse(ev)
      end
    end,
    onmouseup = function() session.draggingLight = false end,
  }
  preview:combobox{ id = "zoom", options = ZOOM_VALUES, option = "适应窗口",
    onchange = function() preview:repaint() end }
  preview:show{ wait = false, autoscrollbars = true }
  preview:repaint()
  openLightSettings()
end

local function applyResultLayer(dlg)
  if not session then return false end
  local isNormal = session.kind == "normal"
  local buffer = isNormal and session.outputs.normal or session.outputs.mask
  if not buffer then return false end
  local sprite = session.sprite
  local source = session.sourceLayer or app.layer
  if not source or source.sprite ~= sprite then source = sprite.layers[#sprite.layers] end
  if not source then showError("找不到来源图层。"); return false end
  local ok, err = pcall(function()
    app.transaction(isNormal and "生成法线贴图" or "生成光线遮罩", function()
      local layer = session.resultLayer
      if not layer or layer.sprite ~= sprite then
        layer = sprite:newLayer()
        layer.name = isNormal and "Normal" or "Light Mask"
        session.resultLayer = layer
      end
      if layer.parent ~= source.parent then layer.parent = source.parent end
      layer.stackIndex = source.stackIndex + 1
      layer.isVisible = true
      local image = bufferToImage(buffer)
      local cel = layer:cel(app.frame)
      if cel then cel.image = image
      else sprite:newCel(layer, app.frame, image, Point(0, 0)) end
    end)
    app.refresh()
  end)
  if ok then
    dlg:modify{ id = "status", text = (isNormal and "Normal" or "Light Mask") .. " 图层已更新" }
    return true
  end
  session.resultLayer = nil
  showError(err)
  return false
end

local function createSession(kind)
  local sprite = app.sprite
  local entries = collectLayers(sprite)
  local labels = {}
  for _, entry in ipairs(entries) do labels[#labels + 1] = entry.label end
  local sourceOptions = { SOURCE_MODES[1], SOURCE_MODES[2] }
  for _, label in ipairs(labels) do sourceOptions[#sourceOptions + 1] = label end
  session = {
    kind = kind, sprite = sprite, layerEntries = entries, layerLabels = labels,
    sourceOptions = sourceOptions,
    sourceMode = "可见图层", sourceLayer = app.layer or (entries[1] and entries[1].layer),
    normal = { preset = "object", shapeStrength = 100, normalStrength = 100,
      smoothing = 3, facets = 35, mergeOutlines = true, invertY = false,
      autoAngle = false, paintedLightAngle = 135, paintedInfluence = 60 },
    mask = { strength = 100, floor = 20, ceiling = 255, cavity = 35 },
    light = { x = 25, y = 10, height = 25, brightness = 250, ambient = 15,
      maskStrength = 100, color = { 255, 255, 255, 255 }, followPointer = true,
      delight = true, delightInfluence = 100 },
    outputs = {}, draggingLight = false,
  }
  if not rebuildSource(session.sourceMode, session.sourceLayer) then session = nil; return false end
  return true
end

local function addSourceWidgets(dlg, onChange)
  dlg:combobox{ id = "source", label = "来源", options = session.sourceOptions,
    option = session.sourceMode, onchange = onChange }
end

local function openNormalDialog()
  if not app.sprite then showError("请先打开一张精灵图。"); return end
  if normalDialog then normalDialog:close() end
  closeLightPreview()
  if not createSession("normal") then return end
  local dlg = Dialog{ title = "生成法线贴图", resizeable = true,
    onclose = function() if normalDialog == dlg then normalDialog = nil end end }
  normalDialog = dlg
  local function readOptions()
    local n = session.normal
    n.preset = presetFromLabel(dlg.data.preset)
    n.shapeStrength, n.normalStrength = dlg.data.shapeStrength, dlg.data.normalStrength
    n.smoothing, n.facets = dlg.data.smoothing, dlg.data.facets
    n.mergeOutlines, n.invertY = dlg.data.mergeOutlines, dlg.data.invertY
    n.autoAngle, n.paintedLightAngle = dlg.data.autoAngle, dlg.data.lightAngle
    n.paintedInfluence = dlg.data.paintedInfluence
  end
  local function applyNormal()
    if not session then return false end
    readOptions()
    dlg:modify{ id = "status", text = "正在生成…" }
    local ok, err = pcall(function()
      generateMaps()
      if session.normal.autoAngle then updateEstimateLabel(dlg) end
      dlg:repaint()
      dlg:modify{ id = "status", text = "已生成" }
    end)
    if not ok then dlg:modify{ id = "status", text = "生成失败" }; showError(err) end
    return ok
  end
  addSourceWidgets(dlg, function()
    if changeSource(dlg) and session.normal.autoAngle then updateEstimateLabel(dlg) end
  end)
  dlg:combobox{ id = "preset", label = "预设", options = PRESET_VALUES, option = "物件",
    onchange = function()
      local defaults = Lighter.defaultNormalMapOptions(presetFromLabel(dlg.data.preset))
      dlg:modify{ id = "shapeStrength", value = defaults.shapeStrength }
      dlg:modify{ id = "smoothing", value = defaults.smoothing }
      dlg:modify{ id = "facets", value = defaults.facets }
      applyNormal()
    end }
  dlg:check{ id = "autoAngle", text = "自动估计原画光源", selected = false, onclick = applyNormal }
  dlg:slider{ id = "lightAngle", label = "原画光源方向", min = 0, max = 359,
    value = 135, onrelease = applyNormal }
  dlg:slider{ id = "paintedInfluence", label = "原画明暗影响", min = 0, max = 100,
    value = 60, onrelease = applyNormal }
  dlg:label{ id = "estimate", text = "角度约定：0° 向右，90° 向上" }
  dlg:slider{ id = "shapeStrength", label = "形状强度", min = 0, max = 200,
    value = 100, onrelease = applyNormal }
  dlg:slider{ id = "normalStrength", label = "法线强度", min = 0, max = 300,
    value = 100, onrelease = applyNormal }
  dlg:slider{ id = "smoothing", label = "平滑", min = 0, max = 6, value = 3, onrelease = applyNormal }
  dlg:slider{ id = "facets", label = "分面", min = 0, max = 100, value = 35, onrelease = applyNormal }
  dlg:check{ id = "mergeOutlines", text = "合并轮廓", selected = true, onclick = applyNormal }
  dlg:check{ id = "invertY", text = "反转 Y（DirectX）", selected = false, onclick = applyNormal }
  dlg:canvas{ id = "normalCanvas", width = 340, height = 230, hexpand = true, vexpand = true,
    onpaint = function(ev) drawPreview(ev, dlg, "normal") end }
  dlg:combobox{ id = "zoom", options = ZOOM_VALUES, option = "适应窗口",
    onchange = function() dlg:repaint() end }
  dlg:combobox{ id = "previewMode", options = { "原图", "法线贴图", "光照" },
    option = "法线贴图", onchange = function() dlg:repaint() end }
  dlg:label{ id = "status", text = "就绪" }
  dlg:button{ text = "确定", onclick = function()
    if applyNormal() and applyResultLayer(dlg) then openLightPreview(); dlg:close() end
  end }
  dlg:button{ text = "应用", onclick = function()
    if applyNormal() and applyResultLayer(dlg) then openLightPreview() end
  end }
  dlg:button{ text = "取消", onclick = function() dlg:close() end }
  dlg:show{ wait = false, autoscrollbars = true }
  applyNormal()
end

local function openMaskDialog()
  if not app.sprite then showError("请先打开一张精灵图。"); return end
  if maskDialog then maskDialog:close() end
  closeLightPreview()
  if not createSession("mask") then return end
  local dlg = Dialog{ title = "生成光线遮罩", resizeable = true,
    onclose = function() if maskDialog == dlg then maskDialog = nil end end }
  maskDialog = dlg
  local function applyMask()
    if not session then return false end
    session.mask = { strength = dlg.data.strength, floor = dlg.data.floor,
      ceiling = dlg.data.ceiling, cavity = dlg.data.cavity }
    dlg:modify{ id = "status", text = "正在生成…" }
    local ok, err = pcall(function()
      generateMaps(); dlg:repaint(); dlg:modify{ id = "status", text = "已生成" }
    end)
    if not ok then dlg:modify{ id = "status", text = "生成失败" }; showError(err) end
    return ok
  end
  addSourceWidgets(dlg, function() changeSource(dlg) end)
  dlg:slider{ id = "strength", label = "明暗强度", min = 0, max = 100,
    value = 100, onrelease = applyMask }
  dlg:slider{ id = "floor", label = "最暗值", min = 0, max = 255,
    value = 20, onrelease = applyMask }
  dlg:slider{ id = "ceiling", label = "最亮值", min = 0, max = 255,
    value = 255, onrelease = applyMask }
  dlg:slider{ id = "cavity", label = "凹陷加深", min = 0, max = 100,
    value = 35, onrelease = applyMask }
  dlg:canvas{ id = "maskCanvas", width = 340, height = 230, hexpand = true, vexpand = true,
    onpaint = function(ev) drawPreview(ev, dlg, "mask") end }
  dlg:combobox{ id = "zoom", options = ZOOM_VALUES, option = "适应窗口",
    onchange = function() dlg:repaint() end }
  dlg:combobox{ id = "previewMode", options = { "原图", "光照遮罩", "光照" },
    option = "光照遮罩", onchange = function() dlg:repaint() end }
  dlg:label{ id = "status", text = "就绪" }
  dlg:button{ text = "确定", onclick = function()
    if applyMask() and applyResultLayer(dlg) then openLightPreview(); dlg:close() end
  end }
  dlg:button{ text = "应用", onclick = function()
    if applyMask() and applyResultLayer(dlg) then openLightPreview() end
  end }
  dlg:button{ text = "取消", onclick = function() dlg:close() end }
  dlg:show{ wait = false, autoscrollbars = true }
  applyMask()
end

-- Persistent normal-map editor: read edited normals and visible artwork without
-- changing the sprite, then refresh and export the relighted result.
local refreshNormalEditor

local function findNamedLayer(entries, wantedName)
  wantedName = string.lower(wantedName)
  for i = #entries, 1, -1 do
    local layer = entries[i].layer
    if not layer.isGroup and string.lower(layer.name or "") == wantedName then
      return layer
    end
  end
  return nil
end

local function containsLayer(entries, wanted)
  if not wanted then return false end
  for _, entry in ipairs(entries) do
    if entry.layer == wanted then return true end
  end
  return false
end

local function editorLayerOptions(entries)
  local options = {}
  for _, entry in ipairs(entries) do
    if not entry.layer.isGroup then options[#options + 1] = entry.label end
  end
  return options
end

local function editorLayerCanvasImage(sprite, layer, frameNumber)
  if not layer or layer.isGroup then return nil end
  local cel = layer:cel(frameNumber)
  if not cel or not cel.image then return nil end
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:drawImage(cel.image, cel.position, 255, BlendMode.NORMAL)
  return image
end

local function isEditorDataLayer(layer, selectedNormal)
  if layer == selectedNormal then return true end
  local name = string.lower(layer.name or "")
  return name == "normal" or name == "light mask"
end

local function drawEditorVisibleLayer(image, layer, frameNumber, selectedNormal)
  if layer.isVisible == false or isEditorDataLayer(layer, selectedNormal) then return end
  if layer.isGroup then
    if layer.layers then
      for _, child in ipairs(layer.layers) do
        drawEditorVisibleLayer(image, child, frameNumber, selectedNormal)
      end
    end
    return
  end
  local cel = layer:cel(frameNumber)
  if cel and cel.image then
    image:drawImage(cel.image, cel.position, layer.opacity or 255,
      layer.blendMode or BlendMode.NORMAL)
  end
end

local function setEditorStatus(text)
  if normalEditorDialog then normalEditorDialog:modify{ id = "editorStatus", text = text } end
end

local function renderNormalEditorLighting()
  if not editorSession or not editorSession.prepared then return end
  local light = editorSession.light
  local w, h = editorSession.albedo.width, editorSession.albedo.height
  local options = Lighter.defaultNormalMapLightOptions(w, h)
  options.position = { x = light.x / 100 * w, y = light.y / 100 * h }
  options.height = light.height
  options.brightness = light.brightness
  options.ambient = light.ambient
  options.maskStrength = light.maskStrength
  options.invertY = editorSession.invertY
  options.color = light.color
  editorSession.output = Lighter.renderPreparedNormalMapLighting(editorSession.prepared, options)
end

local function disconnectEditorSprite()
  if editorSpriteConnections then
    local sprite = editorSpriteConnections.sprite
    if sprite and sprite.events then
      for _, code in ipairs(editorSpriteConnections.codes) do
        pcall(function() sprite.events:off(code) end)
      end
    end
    editorSpriteConnections = nil
  end
end

local function onNormalEditorSpriteChange()
  if not editorSession or not normalEditorDialog or refreshingEditor then return end
  if editorSession.autoRefresh then
    refreshNormalEditor(true, false)
  else
    editorSession.dirty = true
    setEditorStatus("检测到文档更改，请点击“刷新”")
  end
end

local function bindEditorSprite(sprite)
  disconnectEditorSprite()
  if not sprite or not sprite.events then return end
  local codes = {}
  for _, eventName in ipairs({ "change", "filenamechange", "layerblendmode",
    "layername", "layeropacity", "layervisibility" }) do
    local ok, code = pcall(function()
      return sprite.events:on(eventName, onNormalEditorSpriteChange)
    end)
    if ok and code then codes[#codes + 1] = code end
  end
  editorSpriteConnections = { sprite = sprite, codes = codes }
end

local function resetEditorSprite(sprite)
  if not editorSession then return end
  editorSession.sprite = sprite
  editorSession.layerEntries = sprite and collectLayers(sprite) or {}
  editorSession.normalLayer = sprite and findNamedLayer(editorSession.layerEntries, "Normal") or nil
  editorSession.maskLayer = sprite and findNamedLayer(editorSession.layerEntries, "Light Mask") or nil
  editorSession.prepared = nil
  editorSession.output = nil
  editorSession.albedoImage = nil
  editorSession.autoMask = nil
  bindEditorSprite(sprite)
end

local function onNormalEditorSiteChange()
  if not editorSession or not normalEditorDialog then return end
  if app.sprite ~= editorSession.sprite then resetEditorSprite(app.sprite) end
  if not app.sprite then
    setEditorStatus("请打开包含 Normal 图层的文档")
  elseif editorSession.autoRefresh then
    refreshNormalEditor(true, false)
  else
    editorSession.dirty = true
    setEditorStatus("当前帧或文档已更改，请点击“刷新”")
  end
end

local function disconnectEditorSite()
  if editorSiteConnection and app.events then
    pcall(function() app.events:off(editorSiteConnection) end)
  end
  editorSiteConnection = nil
end

refreshNormalEditor = function(automatic, notifyError)
  if not editorSession or not normalEditorDialog or refreshingEditor then return false end
  refreshingEditor = true
  local ok, err = pcall(function()
    local sprite = app.sprite
    if not sprite then error("请先打开一张精灵图。") end
    if sprite ~= editorSession.sprite then resetEditorSprite(sprite) end
    local entries = collectLayers(sprite)
    editorSession.layerEntries = entries
    if not containsLayer(entries, editorSession.normalLayer) then
      editorSession.normalLayer = findNamedLayer(entries, "Normal")
    end
    if not containsLayer(entries, editorSession.maskLayer) then
      editorSession.maskLayer = findNamedLayer(entries, "Light Mask")
    end
    local normalLayer = editorSession.normalLayer
    if not normalLayer then error("找不到 Normal 图层，请先生成法线贴图。") end
    local options = editorLayerOptions(entries)
    normalEditorDialog:modify{ id = "normalLayer", options = options,
      option = layerLabel(entries, normalLayer) }

    local frameNumber = app.frame.frameNumber
    local normalImage = editorLayerCanvasImage(sprite, normalLayer, frameNumber)
    if not normalImage then error("所选法线图层在当前帧没有图像。") end
    local albedoImage = Image(sprite.width, sprite.height, ColorMode.RGB)
    for _, layer in ipairs(sprite.layers) do
      drawEditorVisibleLayer(albedoImage, layer, frameNumber, normalLayer)
    end
    local albedo = imageToBuffer(albedoImage)
    if countForeground(albedo) == 0 then
      error("除法线／遮罩图层外，当前帧没有可见图像。")
    end
    local normals = imageToBuffer(normalImage)
    local maskImage = editorLayerCanvasImage(sprite, editorSession.maskLayer, frameNumber)
    local lightMask
    if maskImage then
      lightMask = imageToBuffer(maskImage)
    elseif editorSession.autoMask and editorSession.albedoImage
      and albedoImage:isEqual(editorSession.albedoImage) then
      lightMask = editorSession.autoMask
    else
      lightMask = Lighter.createLightMaskGenerator(albedo).generate(Lighter.defaultLightMaskOptions())
    end
    editorSession.albedo = albedo
    editorSession.albedoImage = albedoImage
    editorSession.autoMask = not maskImage and lightMask or nil
    editorSession.normals = normals
    editorSession.lightMask = lightMask
    editorSession.prepared = Lighter.prepareNormalMapLighting(albedo, normals, lightMask)
    renderNormalEditorLighting()
    editorSession.dirty = false
    local prefix = automatic and "已自动刷新：" or "已刷新："
    setEditorStatus(prefix .. layerLabel(entries, normalLayer)
      .. (maskImage and "；使用 Light Mask" or "；自动生成遮罩"))
  end)
  refreshingEditor = false
  if ok then
    normalEditorDialog:repaint()
  else
    setEditorStatus("刷新失败：" .. tostring(err))
    if notifyError then showError(err) end
  end
  return ok
end

local function refreshNormalEditorLightingOnly()
  if not editorSession or not editorSession.prepared then return end
  local ok, err = pcall(renderNormalEditorLighting)
  if not ok then setEditorStatus("光照计算失败：" .. tostring(err)); return end
  if normalEditorDialog then normalEditorDialog:repaint() end
end

local function moveNormalEditorLight(ev)
  if not editorSession or not editorSession.lightDrawInfo then return end
  local info = editorSession.lightDrawInfo
  local x = clamp((ev.x - info.x) / info.scale, 0, info.width - 1)
  local y = clamp((ev.y - info.y) / info.scale, 0, info.height - 1)
  editorSession.light.x = math.floor(x / info.width * 100 + 0.5)
  editorSession.light.y = math.floor(y / info.height * 100 + 0.5)
  if normalEditorDialog then
    normalEditorDialog:modify{ id = "editorLightX", value = editorSession.light.x }
    normalEditorDialog:modify{ id = "editorLightY", value = editorSession.light.y }
  end
  refreshNormalEditorLightingOnly()
end

local function drawNormalEditorPreview(ev)
  local gc = ev.context
  gc.color = app.theme.color.window_face
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  if not editorSession or not editorSession.output then return end
  local image = bufferToImage(editorSession.output)
  local w, h = image.width, image.height
  local zoom = normalEditorDialog and normalEditorDialog.data.editorZoom or "适应窗口"
  local scale = zoomScale(zoom, gc.width, gc.height, w, h)
  local dw, dh = w * scale, h * scale
  local ox = math.floor((gc.width - dw) / 2)
  local oy = math.floor((gc.height - dh) / 2)
  checkerboard(gc, ox, oy, dw, dh)
  gc.antialias = false
  gc:drawImage(image, image.bounds, Rectangle(ox, oy, dw, dh))
  editorSession.lightDrawInfo = { x = ox, y = oy, scale = scale, width = w, height = h }
  local lx = ox + editorSession.light.x / 100 * dw
  local ly = oy + editorSession.light.y / 100 * dh
  gc.color = Color{ r = 255, g = 255, b = 255, a = 220 }
  gc.strokeWidth = 1
  gc:beginPath()
  gc:moveTo(lx - 5, ly); gc:lineTo(lx + 5, ly)
  gc:moveTo(lx, ly - 5); gc:lineTo(lx, ly + 5); gc:stroke()
end

local function defaultEditorExportPath(sprite)
  local filename = sprite and sprite.filename or ""
  if filename == "" then return "lighting.png" end
  local directory, basename = filename:match("^(.*[/\\])([^/\\]+)$")
  basename = (basename or filename):gsub("%.[^%.]+$", "")
  return (directory or "") .. basename .. "-lighting.png"
end

local function exportNormalEditorLighting()
  if not editorSession or not normalEditorDialog then return end
  if not refreshNormalEditor(false, false) then
    showError("无法导出：请先解决刷新失败的问题。")
    return
  end
  local filename = normalEditorDialog.data.exportPath
  if not filename or filename == "" then
    showError("请选择光照图的导出路径。")
    return
  end
  if not string.lower(filename):match("%.png$") then
    filename = filename .. ".png"
    normalEditorDialog:modify{ id = "exportPath", filename = filename }
  end
  local ok, err = pcall(function()
    bufferToImage(editorSession.output):saveAs{ filename = filename }
  end)
  if ok then setEditorStatus("已导出光照图：" .. filename)
  else showError("导出失败：" .. tostring(err)) end
end

local function cleanupNormalEditor(dlg)
  if normalEditorDialog ~= dlg then return end
  normalEditorDialog = nil
  editorSession = nil
  disconnectEditorSprite()
  disconnectEditorSite()
end

local function closeNormalEditor()
  if normalEditorDialog then normalEditorDialog:close() end
end

local function openNormalEditor()
  if not app.sprite then showError("请先打开一张精灵图。"); return end
  closeNormalEditor()
  local entries = collectLayers(app.sprite)
  local normalLayer = findNamedLayer(entries, "Normal")
  if not normalLayer then
    showError("找不到 Normal 图层，请先使用“生成法线贴图”。")
    return
  end
  editorSession = {
    sprite = app.sprite, layerEntries = entries,
    normalLayer = normalLayer, maskLayer = findNamedLayer(entries, "Light Mask"),
    light = { x = 25, y = 10, height = 25, brightness = 250, ambient = 15,
      maskStrength = 100, color = { 255, 255, 255, 255 }, followPointer = true },
    autoRefresh = true, invertY = false, dirty = false,
  }
  local dlg
  dlg = Dialog{ title = "法线贴图编辑", resizeable = true,
    onclose = function() cleanupNormalEditor(dlg) end }
  normalEditorDialog = dlg
  dlg:combobox{ id = "normalLayer", label = "法线图层",
    options = editorLayerOptions(entries), option = layerLabel(entries, normalLayer),
    onchange = function()
      if not editorSession then return end
      editorSession.normalLayer = layerFromLabel(editorSession.layerEntries, dlg.data.normalLayer)
      refreshNormalEditor(false, true)
    end }
  dlg:check{ id = "autoRefresh", text = "自动刷新", selected = true,
    onclick = function()
      if not editorSession then return end
      editorSession.autoRefresh = dlg.data.autoRefresh
      if editorSession.autoRefresh and editorSession.dirty then refreshNormalEditor(true, false) end
    end }
  dlg:button{ text = "刷新", onclick = function() refreshNormalEditor(false, true) end }
  dlg:canvas{ id = "editorCanvas", width = 440, height = 280, hexpand = true, vexpand = true,
    onpaint = drawNormalEditorPreview,
    onmousedown = function(ev)
      if editorSession and ev.button == MouseButton.LEFT then
        editorSession.draggingLight = true; moveNormalEditorLight(ev)
      end
    end,
    onmousemove = function(ev)
      if editorSession and (editorSession.light.followPointer or editorSession.draggingLight) then
        moveNormalEditorLight(ev)
      end
    end,
    onmouseup = function() if editorSession then editorSession.draggingLight = false end end }
  dlg:combobox{ id = "editorZoom", label = "缩放", options = ZOOM_VALUES, option = "适应窗口",
    onchange = function() dlg:repaint() end }
  dlg:slider{ id = "editorHeight", label = "灯光高度", min = 1, max = 600, value = 25,
    onrelease = function()
      if editorSession then editorSession.light.height = dlg.data.editorHeight end
      refreshNormalEditorLightingOnly()
    end }
  dlg:slider{ id = "editorBrightness", label = "亮度", min = 0, max = 500, value = 250,
    onrelease = function()
      if editorSession then editorSession.light.brightness = dlg.data.editorBrightness end
      refreshNormalEditorLightingOnly()
    end }
  dlg:slider{ id = "editorAmbient", label = "环境光", min = 0, max = 100, value = 15,
    onrelease = function()
      if editorSession then editorSession.light.ambient = dlg.data.editorAmbient end
      refreshNormalEditorLightingOnly()
    end }
  dlg:color{ id = "editorColor", label = "灯光颜色", color = Color{ r=255, g=255, b=255, a=255 },
    onchange = function()
      if editorSession then
        local c = dlg.data.editorColor
        editorSession.light.color = { c.red, c.green, c.blue, c.alpha }
      end
      refreshNormalEditorLightingOnly()
    end }
  dlg:slider{ id = "editorMaskStrength", label = "遮罩强度", min = 0, max = 100, value = 100,
    onrelease = function()
      if editorSession then editorSession.light.maskStrength = dlg.data.editorMaskStrength end
      refreshNormalEditorLightingOnly()
    end }
  dlg:check{ id = "editorInvertY", text = "反转 Y（DirectX）", selected = false,
    onclick = function()
      if editorSession then editorSession.invertY = dlg.data.editorInvertY end
      refreshNormalEditorLightingOnly()
    end }
  dlg:check{ id = "editorFollowPointer", text = "光源跟随指针", selected = true,
    onclick = function()
      if editorSession then editorSession.light.followPointer = dlg.data.editorFollowPointer end
    end }
  dlg:slider{ id = "editorLightX", label = "光源 X %", min = 0, max = 100, value = 25,
    onrelease = function()
      if editorSession then editorSession.light.x = dlg.data.editorLightX end
      refreshNormalEditorLightingOnly()
    end }
  dlg:slider{ id = "editorLightY", label = "光源 Y %", min = 0, max = 100, value = 10,
    onrelease = function()
      if editorSession then editorSession.light.y = dlg.data.editorLightY end
      refreshNormalEditorLightingOnly()
    end }
  dlg:file{ id = "exportPath", label = "导出路径", title = "导出光照图",
    filename = defaultEditorExportPath(app.sprite), open = false, save = true,
    entry = true, filetypes = { "png" } }
  dlg:button{ text = "导出光照图", onclick = exportNormalEditorLighting }
  dlg:label{ id = "editorStatus", text = "正在读取法线图层…" }
  dlg:show{ wait = false, autoscrollbars = true }
  bindEditorSprite(app.sprite)
  if app.events then
    local ok, code = pcall(function()
      return app.events:on("sitechange", onNormalEditorSiteChange)
    end)
    if ok and code then editorSiteConnection = code end
  end
  refreshNormalEditor(false, true)
end

function init(plugin)
  plugin:newCommand{ id = "AsepriteNormalLighterNormal", title = "生成法线贴图",
    group = "edit_fx", onenabled = function() return app.sprite ~= nil end,
    onclick = openNormalDialog }
  plugin:newCommand{ id = "AsepriteNormalLighterMask", title = "生成光线遮罩",
    group = "edit_fx", onenabled = function() return app.sprite ~= nil end,
    onclick = openMaskDialog }
  plugin:newCommand{ id = "AsepriteNormalLighterNormalEditor", title = "法线贴图编辑",
    group = "edit_fx", onenabled = function() return app.sprite ~= nil end,
    onclick = openNormalEditor }
end

function exit(plugin)
  if normalDialog then normalDialog:close(); normalDialog = nil end
  if maskDialog then maskDialog:close(); maskDialog = nil end
  closeLightPreview()
  closeNormalEditor()
  session = nil
end
