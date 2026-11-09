local Lighter = require("lighter")

local function makeSprite(w, h)
  local data = {}
  for i = 1, w * h * 4 do data[i] = 0 end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local dx, dy = x - (w - 1) / 2, y - (h - 1) / 2
      if dx * dx + dy * dy < (w * 0.42) ^ 2 then
        local at = (y * w + x) * 4 + 1
        local shade = math.floor(70 + 150 * (1 - (x + y) / (w + h - 2)))
        data[at], data[at + 1], data[at + 2], data[at + 3] = shade, shade, shade, 255
      end
    end
  end
  return { width = w, height = h, data = data }
end

local function assertBuffer(buffer, w, h)
  assert(buffer.width == w and buffer.height == h)
  assert(#buffer.data == w * h * 4)
  for i = 1, #buffer.data do
    assert(type(buffer.data[i]) == "number")
    assert(buffer.data[i] >= 0 and buffer.data[i] <= 255)
  end
end

local albedo = makeSprite(24, 24)
local generator = Lighter.createNormalMapGenerator(albedo)
local normal = generator.generate{ preset = "object", paintedLightInfluence = 0 }
assertBuffer(normal, 24, 24)
assert(normal.data[4] == 0, "transparent margin must remain transparent")
local center = (12 * 24 + 12) * 4 + 1
assert(normal.data[center + 3] == 255, "foreground must remain opaque")
local nx = normal.data[center] / 127.5 - 1
local ny = normal.data[center + 1] / 127.5 - 1
local nz = normal.data[center + 2] / 127.5 - 1
assert(math.abs(math.sqrt(nx * nx + ny * ny + nz * nz) - 1) < 0.03,
  "normal vectors should be unit length")

local auto = generator.generate{ preset = "character" }
assertBuffer(auto, 24, 24)
local directX = generator.generate{ invertY = true, paintedLightInfluence = 0 }
assertBuffer(directX, 24, 24)

local mask = Lighter.createLightMaskGenerator(albedo).generate()
assertBuffer(mask, 24, 24)
assert(mask.data[center] == mask.data[center + 1]
  and mask.data[center + 1] == mask.data[center + 2], "mask must be grayscale")

local prepared = Lighter.prepareNormalMapLighting(albedo, normal, mask)
local light = Lighter.defaultNormalMapLightOptions(24, 24)
light.position = { x = 2, y = 2 }
light.delight = { angle = 135, influence = 100 }
local relitA = Lighter.renderPreparedNormalMapLighting(prepared, light)
assertBuffer(relitA, 24, 24)
light.position = { x = 21, y = 21 }
local relitB = Lighter.renderPreparedNormalMapLighting(prepared, light)
assertBuffer(relitB, 24, 24)
assert(relitA.data[center] ~= relitB.data[center]
  or relitA.data[center + 1] ~= relitB.data[center + 1],
  "moving the light should change the render")
local delit = Lighter.removePaintedLight(prepared, light.delight)
assertBuffer(delit, 24, 24)

local _ = Lighter.estimatePaintedLight(albedo) -- Nil is valid for synthetic art.
print("All Aseprite_normal_lighter core tests passed.")
