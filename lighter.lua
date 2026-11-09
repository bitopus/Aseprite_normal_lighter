-- Aseprite_normal_lighter: pure Lua pixel-processing core.
-- Ported from rhinoc/xprite-lighter (MIT), adapted from Pixel Art Lighter
-- v3.5.22 by Red Hat Sprite (MIT). See LICENSES/ for notices.
-- Buffers use { width, height, data }, with 1-based straight-alpha RGBA bytes.

local M = {}
local floor, ceil, sqrt, abs = math.floor, math.ceil, math.sqrt, math.abs
local min, max, huge = math.min, math.max, math.huge
local sin, cos, atan = math.sin, math.cos, math.atan
local PI = math.pi

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end
local function round(v) return floor(v + 0.5) end
local function finite(v)
  return type(v) == "number" and v == v and v ~= huge and v ~= -huge
end
local function luminanceAt(data, at)
  return (0.2126 * data[at] + 0.7152 * data[at + 1] + 0.0722 * data[at + 2]) / 255
end
local function unit(x, y, z)
  local len = sqrt(x * x + y * y + z * z)
  if len == 0 then len = 1 end
  return x / len, y / len, z / len
end
local function copy3(dst, di, x, y, z)
  dst[di], dst[di + 1], dst[di + 2] = x, y, z
end

local function buildNeighbors(w, h)
  local n = w * h
  local neighbors, counts = {}, {}
  for i = 1, n * 4 do neighbors[i] = 0 end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = y * w + x + 1
      local base, count = (i - 1) * 4, 0
      if x > 0 then count = count + 1; neighbors[base + count] = i - 1 end
      if x < w - 1 then count = count + 1; neighbors[base + count] = i + 1 end
      if y > 0 then count = count + 1; neighbors[base + count] = i - w end
      if y < h - 1 then count = count + 1; neighbors[base + count] = i + w end
      counts[i] = count
    end
  end
  return neighbors, counts
end

local linearSRGB = {}
for i = 0, 255 do
  local c = i / 255
  linearSRGB[i] = c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end
local function labPivot(v)
  return v > 216 / 24389 and v ^ (1 / 3) or ((24389 / 27) * v + 16) / 116
end
local function colorToLab(color)
  local r = floor(color / 65536) % 256
  local g = floor(color / 256) % 256
  local b = color % 256
  local lr, lg, lb = linearSRGB[r], linearSRGB[g], linearSRGB[b]
  local x = labPivot((lr * 0.4124564 + lg * 0.3575761 + lb * 0.1804375) / 0.95047)
  local y = labPivot(lr * 0.2126729 + lg * 0.7151522 + lb * 0.072175)
  local z = labPivot((lr * 0.0193339 + lg * 0.119192 + lb * 0.9503041) / 1.08883)
  return 116 * y - 16, 500 * (x - y), 200 * (y - z)
end

-- Four-connected exact-RGB or perceptual CIELAB region segmentation.
local function segment(albedo, perceptual)
  local w, h, a = albedo.width, albedo.height, albedo.data
  local n = w * h
  local fg, lum, labels, rgb = {}, {}, {}, {}
  local lo, hi, area = huge, -huge, 0
  for i = 1, n do
    local at = (i - 1) * 4 + 1
    fg[i] = a[at + 3] > 0 and 1 or 0
    lum[i] = luminanceAt(a, at)
    rgb[i] = a[at] * 65536 + a[at + 1] * 256 + a[at + 2]
    labels[i] = 0
    if fg[i] == 1 then
      area = area + 1
      lo, hi = min(lo, lum[i]), max(hi, lum[i])
    end
  end
  if area == 0 then lo, hi = 0, 0 end
  local neighbors, counts = buildNeighbors(w, h)
  local queue, clusters = {}, {}
  local labCache, labCacheCount = {}, 0
  local function labDistanceSquared(c1, c2)
    if c1 == c2 then return 0 end
    local l1, l2 = labCache[c1], labCache[c2]
    if not l1 then
      local L, A, B = colorToLab(c1); l1 = { L, A, B }; labCache[c1] = l1
      labCacheCount = labCacheCount + 1
    end
    if not l2 then
      local L, A, B = colorToLab(c2); l2 = { L, A, B }; labCache[c2] = l2
      labCacheCount = labCacheCount + 1
    end
    if labCacheCount >= 4096 then labCache, labCacheCount = {}, 0 end
    local dl, da, db = l1[1] - l2[1], l1[2] - l2[2], l1[3] - l2[3]
    return dl * dl + da * da + db * db
  end
  local function canGrow(seed, pixel, neighbor)
    if perceptual then
      local ap = (pixel - 1) * 4 + 4
      local an = (neighbor - 1) * 4 + 4
      if abs(a[ap] - a[an]) >= 48 then return false end
      local nc = rgb[neighbor]
      return labDistanceSquared(rgb[pixel], nc) <= 36
        and labDistanceSquared(rgb[seed], nc) <= 100
    end
    return rgb[seed] == rgb[neighbor]
  end
  for i = 1, n do
    if fg[i] == 1 and labels[i] == 0 then
      local id = #clusters + 1
      local pixels, luminanceSum = {}, 0
      local head, tail = 1, 1
      queue[1], labels[i] = i, id
      while head <= tail do
        local p = queue[head]; head = head + 1
        pixels[#pixels + 1] = p
        luminanceSum = luminanceSum + lum[p]
        local base = (p - 1) * 4
        for k = 1, counts[p] do
          local nextPixel = neighbors[base + k]
          if fg[nextPixel] == 1 and labels[nextPixel] == 0
            and canGrow(i, p, nextPixel) then
            labels[nextPixel] = id
            tail = tail + 1; queue[tail] = nextPixel
          end
        end
      end
      clusters[id] = { pixels = pixels,
        value = perceptual and luminanceSum / #pixels or lum[i] }
    end
  end
  return { w = w, h = h, N = n, a = a, fg = fg, lum = lum, labels = labels,
    lo = lo, hi = hi, neighbors = neighbors, counts = counts, queue = queue,
    clusters = clusters, foregroundArea = area }
end

local function paintedLightSignal(w, h, fg, area, lum)
  local radius = min(12, max(2, round(sqrt(area) / 4)))
  local rowSums, rowCounts, signal = {}, {}, {}
  for i = 1, w * h do rowSums[i], rowCounts[i], signal[i] = 0, 0, 0 end
  for y = 0, h - 1 do
    local start = y * w
    local sum, count = 0, 0
    for x = -radius, w - 1 do
      local nextX = x + radius
      if nextX < w then
        local p = start + nextX + 1
        if fg[p] == 1 then sum, count = sum + lum[p], count + 1 end
      end
      local previous = x - radius - 1
      if previous >= 0 then
        local p = start + previous + 1
        if fg[p] == 1 then sum, count = sum - lum[p], count - 1 end
      end
      if x >= 0 then
        local p = start + x + 1
        rowSums[p], rowCounts[p] = sum, count
      end
    end
  end
  for x = 0, w - 1 do
    local sum, count = 0, 0
    for y = -radius, h - 1 do
      local nextY = y + radius
      if nextY < h then
        local p = nextY * w + x + 1
        sum, count = sum + rowSums[p], count + rowCounts[p]
      end
      local previous = y - radius - 1
      if previous >= 0 then
        local p = previous * w + x + 1
        sum, count = sum - rowSums[p], count - rowCounts[p]
      end
      if y >= 0 then
        local p = y * w + x + 1
        if fg[p] == 1 and count > 0 then signal[p] = lum[p] - sum / count end
      end
    end
  end
  return signal
end

local PRESETS = {
  architecture = { silhouette = 0, cap = 16, luminance = 3.5,
    shapeStrength = 100, smoothing = 1, facets = 20 },
  character = { silhouette = 0.65, cap = 8, luminance = 1.2,
    shapeStrength = 65, smoothing = 2, facets = 15 },
  object = { silhouette = 0.65, cap = 16, luminance = 2.1,
    shapeStrength = 100, smoothing = 3, facets = 35 },
  terrain = { silhouette = 0.12, cap = 16, luminance = 4,
    shapeStrength = 110, smoothing = 3, facets = 50 },
}
local LIMITS = { shapeStrength = 200, normalStrength = 300, smoothing = 6,
  facets = 100, paintedLightAngle = 359, paintedLightInfluence = 100 }

function M.defaultNormalMapOptions(preset)
  preset = PRESETS[preset] and preset or "object"
  local p = PRESETS[preset]
  return { preset = preset, shapeStrength = p.shapeStrength, smoothing = p.smoothing,
    facets = p.facets, normalStrength = 100, mergeOutlines = true,
    invertY = false, paintedLightAngle = 135, paintedLightInfluence = 60 }
end

local function normalizeOptions(input)
  local preset = PRESETS[input.preset] and input.preset or "object"
  local result = M.defaultNormalMapOptions(preset)
  for key, limit in pairs(LIMITS) do
    local value = input[key]
    if finite(value) then result[key] = round(clamp(value, 0, limit)) end
  end
  if type(input.mergeOutlines) == "boolean" then result.mergeOutlines = input.mergeOutlines end
  if type(input.invertY) == "boolean" then result.invertY = input.invertY end
  return result
end

local function alignArchitectureEdges(dirs, fg, w, h, spriteScale, strength)
  local depth = max(1, round(spriteScale * 2))
  local minLength = max(12, depth * 4)
  local n = w * h
  local distance, edgeX, edgeY = {}, {}, {}
  for i = 1, n do distance[i], edgeX[i], edgeY[i] = depth, 0, 0 end
  for pass = 1, 2 do
    local horizontal = pass == 1
    local lineCount = horizontal and h or w
    local lineLength = horizontal and w or h
    local lineStride = horizontal and w or 1
    local pixelStride = horizontal and 1 or w
    for _, side in ipairs({ -1, 1 }) do
      for line = 0, lineCount - 1 do
        local start = line * lineStride
        local outside = line + side < 0 or line + side >= lineCount
        local runStart = 0
        for offset = 0, lineLength do
          local pixel = start + offset * pixelStride + 1
          local continuing = offset < lineLength and fg[pixel] == 1
            and (outside or fg[pixel + side * lineStride] == 1)
          if not continuing then
            if offset - runStart >= minLength then
              for along = runStart, offset - 1 do
                for step = 0, depth - 1 do
                  local inside = line - step * side
                  local p = inside * lineStride + along * pixelStride + 1
                  if inside < 0 or inside >= lineCount or fg[p] ~= 1 then break end
                  if step <= distance[p] then
                    if step < distance[p] then
                      distance[p] = step; edgeX[p], edgeY[p] = 0, 0
                    end
                    if horizontal then edgeY[p] = edgeY[p] - side
                    else edgeX[p] = edgeX[p] + side end
                  end
                end
              end
            end
            runStart = offset + 1
          end
        end
      end
    end
  end
  for p = 1, n do
    local length = sqrt(edgeX[p] * edgeX[p] + edgeY[p] * edgeY[p])
    if length > 0 then
      local tilt = 0.35 * strength * (1 - distance[p] / depth)
      dirs[(p - 1) * 3 + 1] = edgeX[p] * tilt / length
      dirs[(p - 1) * 3 + 2] = edgeY[p] * tilt / length
      dirs[(p - 1) * 3 + 3] = sqrt(max(0, 1 - tilt * tilt))
    end
  end
end

function M.createNormalMapGenerator(albedo)
  local s = segment(albedo, true)
  local w, h, n, a = s.w, s.h, s.N, s.a
  local fg, lum, labels = s.fg, s.lum, s.labels
  local neighbors, counts, queue, clusters = s.neighbors, s.counts, s.queue, s.clusters
  local spriteScale = min(2, sqrt(s.foregroundArea) / 64)
  local distance = {}
  for i = 1, n do distance[i] = n end
  local head, tail = 1, 0
  for i = 1, n do
    local x, y = (i - 1) % w, floor((i - 1) / w)
    local boundary = x == 0 or x == w - 1 or y == 0 or y == h - 1
    if fg[i] == 1 and not boundary then
      local base = (i - 1) * 4
      for k = 1, counts[i] do
        if fg[neighbors[base + k]] == 0 then boundary = true; break end
      end
    end
    if fg[i] == 1 and boundary then
      distance[i] = 1; tail = tail + 1; queue[tail] = i
    end
  end
  while head <= tail do
    local p = queue[head]; head = head + 1
    local base = (p - 1) * 4
    for k = 1, counts[p] do
      local nextPixel = neighbors[base + k]
      if fg[nextPixel] == 1 and distance[nextPixel] > distance[p] + 1 then
        distance[nextPixel] = distance[p] + 1
        tail = tail + 1; queue[tail] = nextPixel
      end
    end
  end
  local range = s.hi - s.lo
  local function normalized(i)
    return range > 0.00001 and (lum[i] - s.lo) / range or 0.75
  end
  local thin = {}
  for i = 1, n do thin[i] = 0 end
  for _, cluster in ipairs(clusters) do
    if cluster.value <= s.lo + range * 0.24 then
      local interior = 0
      for _, p in ipairs(cluster.pixels) do
        if counts[p] == 4 then
          local allSame, base = true, (p - 1) * 4
          for k = 1, 4 do
            if labels[neighbors[base + k]] ~= labels[p] then allSame = false; break end
          end
          if allSame then interior = interior + 1 end
        end
      end
      if interior / #cluster.pixels < 0.15 then
        for _, p in ipairs(cluster.pixels) do thin[p] = 1 end
      end
    end
  end

  local cachedFieldKey, cachedField = "", nil
  local cachedKey, cachedDirections = "", nil
  local lightSignal, paintedEstimate = nil, nil
  local estimateDone = false
  local function estimatePainted()
    if not estimateDone then
      paintedEstimate = M.estimatePaintedLight(albedo)
      estimateDone = true
    end
    return paintedEstimate
  end

  local generator = {}
  function generator.suggestPaintedLightAngle()
    local estimate = estimatePainted()
    return estimate and estimate.angle or nil
  end
  function generator.getPaintedLightEstimate() return estimatePainted() end

  function generator.generate(input)
    input = input or {}
    local options = normalizeOptions(input)
    local influence = options.paintedLightInfluence / 100
    local angleDeg = options.paintedLightAngle
    if influence > 0 and input.paintedLightAngle == nil then
      local estimate = estimatePainted()
      if estimate then
        angleDeg = estimate.angle
        influence = influence * clamp((estimate.fit - 0.2) / 0.25, 0, 1)
      else
        influence = 0
      end
    end
    local key = table.concat({ options.preset, options.shapeStrength,
      options.smoothing, options.facets, tostring(options.mergeOutlines),
      influence, influence > 0 and angleDeg or 0 }, ":")
    local dirs = cachedDirections
    if not dirs or cachedKey ~= key then
      local preset = options.preset
      local profile = PRESETS[preset]
      local scale = options.shapeStrength / 100
      local fieldKey = table.concat({ preset, options.smoothing, influence }, ":")
      local field = cachedField
      if not field or cachedFieldKey ~= fieldKey then
        local power = min(1, max(0.5, 0.5 + (spriteScale - 0.5) * 0.5))
        local nextField = {}
        for i = 1, n do
          nextField[i] = 0
          if fg[i] == 1 then
            local convex = (min(distance[i], profile.cap) / profile.cap) ^ power
              * profile.silhouette * sqrt(profile.cap)
            nextField[i] = convex + normalized(i) * profile.luminance * (1 - influence)
          end
        end
        for _ = 1, options.smoothing do
          local blurred = {}
          for i = 1, n do
            blurred[i] = 0
            if fg[i] == 1 then
              local sum, count = nextField[i] * 2, 2
              local base = (i - 1) * 4
              for k = 1, counts[i] do
                local nextPixel = neighbors[base + k]
                if fg[nextPixel] == 1 then
                  sum, count = sum + nextField[nextPixel], count + 1
                end
              end
              blurred[i] = sum / count
            end
          end
          nextField = blurred
        end
        cachedFieldKey, field, cachedField = fieldKey, nextField, nextField
      end
      dirs = {}
      for i = 1, n * 3 do dirs[i] = 0 end
      local function quantize(x, y, z)
        x, y, z = unit(x, y, z)
        local tilt = sqrt(x * x + y * y)
        if tilt < 0.12 then return 0, 0, 1 end
        local angle = round(atan(y, x) / (PI / 4)) * (PI / 4)
        local elevation
        if preset == "architecture" then elevation = min(0.9, 0.6 * scale)
        elseif tilt < 0.3 then elevation = 0.24
        elseif tilt < 0.6 then elevation = 0.48
        elseif tilt < 0.85 then elevation = 0.72
        else elevation = 0.9 end
        return cos(angle) * elevation, sin(angle) * elevation, sqrt(1 - elevation * elevation)
      end
      if influence > 0 and not lightSignal then
        lightSignal = paintedLightSignal(w, h, fg, s.foregroundArea, lum)
      end
      local angle = angleDeg * PI / 180
      local lightX = cos(angle) * influence * 3
      local lightY = sin(angle) * influence * 3
      local function normalAt(pixel)
        local x, y = (pixel - 1) % w, floor((pixel - 1) / w)
        local center = field[pixel]
        local function at(neighbor)
          return fg[neighbor] == 1 and field[neighbor] or center
        end
        local dx = (x < w - 1 and at(pixel + 1) or center)
          - (x > 0 and at(pixel - 1) or center)
        local dy = (y < h - 1 and at(pixel + w) or center)
          - (y > 0 and at(pixel - w) or center)
        if influence == 0 then return unit(-dx * scale, dy * scale, 1) end
        local tilt = lightSignal[pixel]
        return unit(-dx * scale + lightX * tilt, dy * scale + lightY * tilt, 1)
      end
      for i = 1, n do
        if fg[i] == 1 then copy3(dirs, (i - 1) * 3 + 1, normalAt(i)) end
      end
      local facetStrength = options.facets / 100
      local minFacetArea = max(8, round((180 - options.facets * 1.1) * spriteScale))
      local supportFactor = 1.5 - facetStrength * 0.75
      local dotLimit = 0.7 + facetStrength * 0.1
      for _, cluster in ipairs(clusters) do
        local sx, sy, sz = 0, 0, 0
        for _, p in ipairs(cluster.pixels) do
          local v = (p - 1) * 3 + 1
          if not (preset == "architecture"
            and sqrt(dirs[v] ^ 2 + dirs[v + 1] ^ 2) < 0.06) then
            sx, sy, sz = sx + dirs[v], sy + dirs[v + 1], sz + dirs[v + 2]
          end
        end
        if sz == 0 then sx, sy, sz = 0, 0, 1 end
        local ax, ay, az = unit(sx, sy, sz)
        local groups = {}
        local split = options.facets > 0 and #cluster.pixels >= minFacetArea
        if split then
          for _, p in ipairs(cluster.pixels) do
            local v = (p - 1) * 3 + 1
            local dx, dy = dirs[v], dirs[v + 1]
            local tilt = sqrt(dx * dx + dy * dy)
            local groupKey = 9
            if tilt > 0.35 then
              groupKey = (round(atan(dy, dx) / (PI / 2)) + 4) % 4
            end
            if not groups[groupKey] then groups[groupKey] = {} end
            local group = groups[groupKey]; group[#group + 1] = p
          end
        end
        local minSupport = max(2, ceil(sqrt(#cluster.pixels) * supportFactor))
        local supported = {}
        for _, group in pairs(groups) do
          if #group >= minSupport then supported[#supported + 1] = group end
        end
        local allow = false
        if #supported >= 2 then
          local means = {}
          for gi, group in ipairs(supported) do
            local gx, gy, gz = 0, 0, 0
            for _, p in ipairs(group) do
              local v = (p - 1) * 3 + 1
              gx, gy, gz = gx + dirs[v], gy + dirs[v + 1], gz + dirs[v + 2]
            end
            local mx, my, mz = unit(gx, gy, gz)
            means[gi] = { mx, my, mz }
          end
          for i = 1, #means do
            for j = 1, i - 1 do
              local dot = means[i][1] * means[j][1] + means[i][2] * means[j][2]
                + means[i][3] * means[j][3]
              if dot < dotLimit then allow = true end
            end
          end
        end
        local bx, by, bz = quantize(ax, ay, az)
        for _, p in ipairs(cluster.pixels) do copy3(dirs, (p - 1) * 3 + 1, bx, by, bz) end
        if allow then
          for _, group in ipairs(supported) do
            local gx, gy, gz = 0, 0, 0
            for _, p in ipairs(group) do
              local nx, ny, nz = normalAt(p)
              gx, gy, gz = gx + nx, gy + ny, gz + nz
            end
            local qx, qy, qz = quantize(gx, gy, gz)
            for _, p in ipairs(group) do copy3(dirs, (p - 1) * 3 + 1, qx, qy, qz) end
          end
        end
      end
      if options.mergeOutlines then
        local assigned = {}
        for i = 1, n do assigned[i] = 0 end
        head, tail = 1, 0
        for i = 1, n do
          if fg[i] == 1 and thin[i] == 0 then
            assigned[i] = 1; tail = tail + 1; queue[tail] = i
          end
        end
        while head <= tail do
          local p = queue[head]; head = head + 1
          local base, pv = (p - 1) * 4, (p - 1) * 3 + 1
          for k = 1, counts[p] do
            local nextPixel = neighbors[base + k]
            if fg[nextPixel] == 1 and assigned[nextPixel] == 0 then
              assigned[nextPixel] = 1
              copy3(dirs, (nextPixel - 1) * 3 + 1, dirs[pv], dirs[pv + 1], dirs[pv + 2])
              tail = tail + 1; queue[tail] = nextPixel
            end
          end
        end
      end
      local seen = {}
      for i = 1, n do seen[i] = 0 end
      for i = 1, n do
        if fg[i] == 1 and seen[i] == 0 then
          local group, inGroup = {}, {}
          head, tail = 1, 1
          queue[1], seen[i] = i, 1
          local iv = (i - 1) * 3 + 1
          while head <= tail do
            local p = queue[head]; head = head + 1
            group[#group + 1] = p; inGroup[p] = true
            local base, pv = (p - 1) * 4, (p - 1) * 3 + 1
            for k = 1, counts[p] do
              local nextPixel = neighbors[base + k]
              local nv = (nextPixel - 1) * 3 + 1
              if labels[nextPixel] == labels[i] and seen[nextPixel] == 0
                and abs(dirs[nv] - dirs[iv]) < 0.001
                and abs(dirs[nv + 1] - dirs[iv + 1]) < 0.001 then
                seen[nextPixel] = 1; tail = tail + 1; queue[tail] = nextPixel
              end
            end
          end
          if #group <= 2 then
            local replacement = 0
            for _, p in ipairs(group) do
              local base = (p - 1) * 4
              for k = 1, counts[p] do
                local nextPixel = neighbors[base + k]
                if labels[nextPixel] == labels[i] and not inGroup[nextPixel] then
                  replacement = nextPixel; break
                end
              end
              if replacement > 0 then break end
            end
            if replacement > 0 then
              local rv = (replacement - 1) * 3 + 1
              for _, p in ipairs(group) do
                copy3(dirs, (p - 1) * 3 + 1, dirs[rv], dirs[rv + 1], dirs[rv + 2])
              end
            end
          end
        end
      end
      if preset == "architecture" and scale > 0 then
        alignArchitectureEdges(dirs, fg, w, h, spriteScale, scale)
      end
      cachedKey, cachedDirections = key, dirs
    end
    local output = {}
    for i = 1, n * 4 do output[i] = 0 end
    local gain = options.normalStrength / 100
    local ySign = options.invertY and -1 or 1
    for i = 1, n do
      local v, at = (i - 1) * 3 + 1, (i - 1) * 4 + 1
      local x = fg[i] == 1 and dirs[v] * gain or 0
      local y = fg[i] == 1 and dirs[v + 1] * gain or 0
      local z = fg[i] == 1 and dirs[v + 2] or 1
      local length = sqrt(x * x + y * y + z * z)
      if length == 0 then length = 1 end
      output[at] = round((x / length + 1) * 127.5)
      output[at + 1] = round((y / length * ySign + 1) * 127.5)
      output[at + 2] = round((z / length + 1) * 127.5)
      output[at + 3] = a[at + 3]
    end
    return { width = w, height = h, data = output }
  end
  return generator
end

function M.generateNormalMap(albedo, options)
  return M.createNormalMapGenerator(albedo).generate(options)
end

function M.defaultLightMaskOptions()
  return { strength = 100, floor = 20, ceiling = 255, cavity = 35 }
end

function M.createLightMaskGenerator(albedo)
  local s = segment(albedo, false)
  local range = s.hi - s.lo
  local regions = {}
  for _, cluster in ipairs(s.clusters) do
    local tone = range > 0.00001 and (cluster.value - s.lo) / range or 0.75
    local surrounded = 0
    if tone < 0.35 then
      for _, pixel in ipairs(cluster.pixels) do
        local brighter, neighborCount = 0, 0
        local base = (pixel - 1) * 4
        for k = 1, s.counts[pixel] do
          local neighbor = s.neighbors[base + k]
          if s.fg[neighbor] == 1 and s.labels[neighbor] ~= s.labels[pixel] then
            neighborCount = neighborCount + 1
            if s.lum[neighbor] > cluster.value + range * 0.15 then
              brighter = brighter + 1
            end
          end
        end
        if neighborCount > 0 and brighter / neighborCount > 0.5 then
          surrounded = surrounded + 1
        end
      end
    end
    regions[#regions + 1] = { pixels = cluster.pixels, reception = tone ^ 1.15,
      cavity = min(1, surrounded / sqrt(#cluster.pixels)) }
  end
  local generator = {}
  function generator.generate(input)
    input = input or {}
    local options = M.defaultLightMaskOptions()
    for _, key in ipairs({ "strength", "floor", "ceiling", "cavity" }) do
      local value = input[key]
      local limit = (key == "floor" or key == "ceiling") and 255 or 100
      if finite(value) then options[key] = round(clamp(value, 0, limit)) end
    end
    local strength, floorValue = options.strength / 100, options.floor / 255
    local cavity, ceiling = options.cavity / 100, options.ceiling / 255
    local data = {}
    for i = 1, s.N * 4 do data[i] = 0 end
    for _, region in ipairs(regions) do
      local reception = (floorValue + (1 - floorValue) * region.reception)
        * (1 - cavity * region.cavity)
      local value = round(255 * min(ceiling, 1 - strength + strength * reception))
      for _, pixel in ipairs(region.pixels) do
        local at = (pixel - 1) * 4 + 1
        data[at], data[at + 1], data[at + 2] = value, value, value
        data[at + 3] = s.a[at + 3]
      end
    end
    return { width = s.w, height = s.h, data = data }
  end
  return generator
end

function M.prepareNormalMapLighting(albedo, normals, lightMask)
  local w, h, n = albedo.width, albedo.height, albedo.width * albedo.height
  local colors, directions, alpha, mask = {}, {}, {}, lightMask and {} or nil
  for i = 1, n do
    local at, v = (i - 1) * 4 + 1, (i - 1) * 3 + 1
    alpha[i] = albedo.data[at + 3]
    if mask then
      local coverage = lightMask.data[at + 3] / 255
      mask[i] = 1 - coverage * (1 - luminanceAt(lightMask.data, at))
    end
    for c = 0, 2 do colors[v + c] = linearSRGB[albedo.data[at + c]] end
    local valid = normals and normals.data[at + 3] > 0
    local nx = valid and normals.data[at] / 255 * 2 - 1 or 0
    local ny = valid and normals.data[at + 1] / 255 * 2 - 1 or 0
    local nz = valid and normals.data[at + 2] / 255 * 2 - 1 or 1
    directions[v], directions[v + 1], directions[v + 2] = unit(nx, ny, nz)
  end
  return { width = w, height = h, colors = colors, directions = directions,
    alpha = alpha, mask = mask }
end

local function encodeSRGB(value)
  value = clamp(value, 0, 1)
  local encoded = value <= 0.0031308 and value * 12.92
    or 1.055 * value ^ (1 / 2.4) - 0.055
  return round(255 * encoded)
end

local function paintedLightGainFunction(source, delight, ySign)
  if not delight or not finite(delight.angle) then return nil end
  local strength = finite(delight.influence) and clamp(delight.influence, 0, 100) / 100 or 0
  if strength == 0 then return nil end
  local azimuth, elevation = delight.angle * PI / 180, 45 * PI / 180
  local lx = cos(azimuth) * cos(elevation)
  local ly = sin(azimuth) * cos(elevation) * ySign
  local lz = sin(elevation)
  local directions = source.directions
  return function(v)
    local facing = max(0, directions[v] * lx + directions[v + 1] * ly + directions[v + 2] * lz)
    return 1 + strength * (1 / (0.15 + 0.85 * facing) - 1)
  end
end

function M.defaultNormalMapLightOptions(w, h)
  return { position = { x = w / 2, y = h / 2 }, height = 25, brightness = 250,
    ambient = 15, maskStrength = 100, color = { 255, 255, 255, 255 }, invertY = false }
end

function M.renderPreparedNormalMapLighting(source, options)
  local w, h = source.width, source.height
  local lightHeight = max(0.000001, finite(options.height) and clamp(options.height, 0, 600) or 25)
  local power = (finite(options.brightness) and clamp(options.brightness, 0, 500) or 250) / 100
  local ambient = (finite(options.ambient) and clamp(options.ambient, 0, 100) or 15) / 100
  local maskStrength = (finite(options.maskStrength) and clamp(options.maskStrength, 0, 100) or 100) / 100
  local color = options.color or { 255, 255, 255, 255 }
  local light = { linearSRGB[color[1]], linearSRGB[color[2]], linearSRGB[color[3]] }
  local pos = options.position or { x = w / 2, y = h / 2 }
  local x = finite(pos.x) and pos.x or w / 2
  local y = finite(pos.y) and pos.y or h / 2
  local ySign = options.invertY and -1 or 1
  local data = {}
  local gainFunction = paintedLightGainFunction(source, options.delight, ySign)
  for i = 1, w * h do
    local at, v = (i - 1) * 4 + 1, (i - 1) * 3 + 1
    data[at + 3] = source.alpha[i]
    if source.alpha[i] > 0 then
      local dx = x - ((i - 1) % w)
      local dy = floor((i - 1) / w) - y
      local distanceSquared = dx * dx + dy * dy + lightHeight * lightHeight
      local diffuse = max(0, (source.directions[v] * dx
        + source.directions[v + 1] * dy * ySign
        + source.directions[v + 2] * lightHeight) / sqrt(distanceSquared))
      local reception = source.mask and 1 - maskStrength * (1 - source.mask[i]) or 1
      local direct = power * diffuse * reception / (1 + distanceSquared / 1024)
      local gain = gainFunction and gainFunction(v) or 1
      for channel = 0, 2 do
        data[at + channel] = encodeSRGB(source.colors[v + channel] * gain
          * (ambient + direct * light[channel + 1]))
      end
    else
      data[at], data[at + 1], data[at + 2] = 0, 0, 0
    end
  end
  return { width = w, height = h, data = data }
end

function M.removePaintedLight(source, delight, invertY)
  local gainFunction = paintedLightGainFunction(source, delight, invertY and -1 or 1)
  local data = {}
  for i = 1, source.width * source.height do
    local at, v = (i - 1) * 4 + 1, (i - 1) * 3 + 1
    data[at + 3] = source.alpha[i]
    local gain = gainFunction and gainFunction(v) or 1
    for channel = 0, 2 do
      data[at + channel] = source.alpha[i] > 0
        and encodeSRGB(source.colors[v + channel] * gain) or 0
    end
  end
  return { width = source.width, height = source.height, data = data }
end

-- Painted-light estimation: fit contour luminance against Lambert directions.
local ESTIMATE_ELEVATIONS = { 25, 45, 65 }
local CARDINAL = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local CHAMFER = { { -1, 0, 1 }, { 0, -1, 1 },
  { -1, -1, math.sqrt(2) }, { 1, -1, math.sqrt(2) } }

local function angularDistance(a, b)
  return abs((a - b + 540) % 360 - 180)
end

local function fitDirection(samples)
  if #samples < 40 then return nil end
  local byGroup = {}
  for _, sample in ipairs(samples) do
    if not byGroup[sample.group] then byGroup[sample.group] = {} end
    local group = byGroup[sample.group]; group[#group + 1] = sample
  end
  local groups, observedVariance = {}, 0
  for _, samplesInGroup in pairs(byGroup) do
    local count, mean = #samplesInGroup, 0
    for _, sample in ipairs(samplesInGroup) do mean = mean + sample.luminance end
    mean = mean / count
    local residuals, weight = {}, 1 / sqrt(count)
    for i, sample in ipairs(samplesInGroup) do residuals[i] = sample.luminance - mean end
    for _, residual in ipairs(residuals) do
      observedVariance = observedVariance + weight * residual * residual
    end
    groups[#groups + 1] = { samples = samplesInGroup, residuals = residuals, weight = weight }
  end
  if observedVariance <= 0.000000001 then return nil end
  local scores = {}
  local winner = 1
  for slot = 1, 72 do
    scores[slot] = -1
    local angle = (slot - 1) * 5 * PI / 180
    for _, elevation in ipairs(ESTIMATE_ELEVATIONS) do
      local height = elevation * PI / 180
      local lx, ly, lz = cos(angle) * cos(height), sin(angle) * cos(height), sin(height)
      local predictedVariance, covariance = 0, 0
      for _, group in ipairs(groups) do
        local sum, squared, cross = 0, 0, 0
        for i, sample in ipairs(group.samples) do
          local prediction = max(0, sample.nx * lx + sample.ny * ly + sample.nz * lz)
          sum = sum + prediction
          squared = squared + prediction * prediction
          cross = cross + prediction * group.residuals[i]
        end
        predictedVariance = predictedVariance + group.weight
          * (squared - sum * sum / #group.samples)
        covariance = covariance + group.weight * cross
      end
      if predictedVariance > 0.000000001 then
        scores[slot] = max(scores[slot], covariance / sqrt(predictedVariance * observedVariance))
      end
    end
    if scores[slot] > scores[winner] then winner = slot end
  end
  return { angle = (winner - 1) * 5, fit = scores[winner],
    oppositeMargin = scores[winner] - scores[(winner - 1 + 36) % 72 + 1] }
end

function M.estimatePaintedLight(source)
  local w, h, data = source.width, source.height, source.data
  if w * h > 1048576 then return nil end
  local n = w * h
  local mask, distance, smooth, labels, componentSizes = {}, {}, {}, {}, {}
  local area, left, top = 0, w - 1, h - 1
  local function indexAt(x, y)
    if x < 0 or x >= w or y < 0 or y >= h then return 0 end
    return y * w + x + 1
  end
  for i = 1, n do
    mask[i], distance[i], smooth[i], labels[i] = 0, 0, 0, 0
    if data[(i - 1) * 4 + 4] >= 128 then
      mask[i] = 1; area = area + 1
      left, top = min(left, (i - 1) % w), min(top, floor((i - 1) / w))
    end
  end
  local queue = {}
  for i = 1, n do
    if mask[i] == 1 then
      local x, y = (i - 1) % w, floor((i - 1) / w)
      local boundary = false
      for _, step in ipairs(CARDINAL) do
        local nextPixel = indexAt(x + step[1], y + step[2])
        if nextPixel == 0 or mask[nextPixel] == 0 then boundary = true; break end
      end
      distance[i] = boundary and 1 or 7
      if labels[i] == 0 then
        local label = #componentSizes + 1
        local head, tail = 1, 1
        queue[1], labels[i] = i, label
        while head <= tail do
          local p = queue[head]; head = head + 1
          local px, py = (p - 1) % w, floor((p - 1) / w)
          for _, step in ipairs(CARDINAL) do
            local nextPixel = indexAt(px + step[1], py + step[2])
            if nextPixel > 0 and mask[nextPixel] == 1 and labels[nextPixel] == 0 then
              labels[nextPixel] = label
              tail = tail + 1; queue[tail] = nextPixel
            end
          end
        end
        componentSizes[label] = tail
      end
    end
  end
  for _, sign in ipairs({ 1, -1 }) do
    for step = 0, n - 1 do
      local i = sign == 1 and step + 1 or n - step
      if mask[i] == 1 and distance[i] ~= 1 then
        local x, y = (i - 1) % w, floor((i - 1) / w)
        for _, stepData in ipairs(CHAMFER) do
          local nextPixel = indexAt(x + stepData[1] * sign, y + stepData[2] * sign)
          if nextPixel > 0 and mask[nextPixel] == 1 then
            distance[i] = min(distance[i], distance[nextPixel] + stepData[3])
          end
        end
      end
    end
  end
  for i = 1, n do
    if mask[i] == 1 then
      local x, y = (i - 1) % w, floor((i - 1) / w)
      local sum, weight = distance[i] * 2, 2
      for _, step in ipairs(CARDINAL) do
        local nextPixel = indexAt(x + step[1], y + step[2])
        if nextPixel > 0 and mask[nextPixel] == 1 then
          sum, weight = sum + distance[nextPixel], weight + 1
        end
      end
      smooth[i] = sum / weight
    end
  end
  if area < 40 then return nil end
  local tileSize = max(4, floor(sqrt(area) / 5))
  local samples = {}
  for i = 1, n do
    local component = labels[i]
    if mask[i] == 1 and distance[i] <= 4 and componentSizes[component] >= 24 then
      local x, y = (i - 1) % w, floor((i - 1) / w)
      local function sampleAt(sx, sy)
        local p = indexAt(sx, sy)
        return p > 0 and smooth[p] or 0
      end
      local nx = (sampleAt(x - 1, y) - sampleAt(x + 1, y)) / 2
      local ny = (sampleAt(x, y + 1) - sampleAt(x, y - 1)) / 2
      local length = sqrt(nx * nx + ny * ny + 1)
      if sqrt(nx * nx + ny * ny) / length >= 0.15 then
        local at = (i - 1) * 4 + 1
        if max(data[at], data[at + 1], data[at + 2]) >= 20 then
          local sum = data[at] + data[at + 1] + data[at + 2]
          local red = round(data[at] / sum * 16)
          local green = round(data[at + 1] / sum * 16)
          local group = (component * 17 + red) * 17 + green
          local block = (floor((y - top) / tileSize) * 7
            + floor((x - left) / tileSize)) % 4
          samples[#samples + 1] = { nx = nx / length, ny = ny / length, nz = 1 / length,
            luminance = luminanceAt(data, at), component = component, group = group, block = block }
        end
      end
    end
  end
  local bounded = samples
  if #samples > 8192 then
    bounded = {}
    for i = 0, 8191 do bounded[i + 1] = samples[floor(i * #samples / 8192) + 1] end
  end
  local byGroup = {}
  for _, sample in ipairs(bounded) do
    if not byGroup[sample.group] then byGroup[sample.group] = {} end
    local group = byGroup[sample.group]; group[#group + 1] = sample
  end
  local supported, contrast = {}, 0
  for _, group in pairs(byGroup) do
    if #group >= 8 then
      local tones = {}
      for i = 0, 32 do tones[i] = 0 end
      for _, sample in ipairs(group) do
        local tone = round(sample.luminance * 32); tones[tone] = tones[tone] + 1
      end
      local toneCount = 0
      for i = 0, 32 do if tones[i] >= 2 then toneCount = toneCount + 1 end end
      if toneCount >= 3 then
        local mean = 0
        for _, sample in ipairs(group) do mean = mean + sample.luminance end
        mean = mean / #group
        for _, sample in ipairs(group) do
          contrast = contrast + (sample.luminance - mean) ^ 2
          supported[#supported + 1] = sample
        end
      end
    end
  end
  if #supported < 40 or contrast < #supported * 0.025 ^ 2 then return nil end
  local candidate = fitDirection(supported)
  if not candidate or candidate.fit < 0.3 or candidate.oppositeMargin < 0.12 then return nil end
  for block = 0, 3 do
    local holdout = {}
    for _, sample in ipairs(supported) do
      if sample.block ~= block then holdout[#holdout + 1] = sample end
    end
    local fit = fitDirection(holdout)
    if not fit or angularDistance(fit.angle, candidate.angle) > 45 then return nil end
  end
  local byComponent = {}
  for _, sample in ipairs(supported) do
    if not byComponent[sample.component] then byComponent[sample.component] = {} end
    local component = byComponent[sample.component]; component[#component + 1] = sample
  end
  for _, component in pairs(byComponent) do
    local fit = fitDirection(component)
    if fit and fit.fit >= 0.25 and angularDistance(fit.angle, candidate.angle) > 75 then
      return nil
    end
  end
  return { angle = candidate.angle, fit = candidate.fit }
end

return M
