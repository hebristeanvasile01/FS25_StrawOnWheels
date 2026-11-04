-- Straw On Wheels: driving through straw windrows on a field makes straw stick to
-- the tyres. The pieces turn with the wheel and stay there until the vehicle
-- drives 30 km/h or faster, then they fall off.
-- Client side visuals only. Author: FS Modding
StrawOnWheels = {}

local modDirectory = g_currentModDirectory

StrawOnWheels.enabled = true
StrawOnWheels.SHED_SPEED = 30        -- km/h, from this speed the straw falls off
StrawOnWheels.SHED_MIN = 300         -- ms at that speed until a piece lets go (shortest)
StrawOnWheels.SHED_MAX = 3500        -- ms (longest)
StrawOnWheels.MAX_PIECES = 16        -- pieces per wheel
StrawOnWheels.ADD_INTERVAL = 140     -- ms between two new pieces while rolling through straw
StrawOnWheels.MIN_LEVEL = 0.5        -- litres of straw under the tyre needed
StrawOnWheels.MIN_SPEED = 1.5        -- km/h
StrawOnWheels.FALL_MS = 1500         -- ms a piece needs to fall off
StrawOnWheels.CHECK_MS = 100
StrawOnWheels.FILL_TYPES = { "STRAW" }

StrawOnWheels.states = {}
StrawOnWheels.fillTypeIndices = {}
StrawOnWheels.loaded = false

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

function StrawOnWheels:loadTemplate()
    local path = modDirectory .. "i3d/strawBit.i3d"
    local root = nil
    if g_i3DManager ~= nil and g_i3DManager.loadI3DFile ~= nil then
        root = g_i3DManager:loadI3DFile(path, false, false)
    elseif loadI3DFile ~= nil then
        root = loadI3DFile(path, false, false, false)
    end
    if root == nil or root == 0 then
        Logging.warning("[StrawOnWheels] could not load %s", path)
        return
    end
    link(getRootNode(), root)
    setVisibility(root, false)
    self.templateRoot = root
    local group = getChildAt(root, 0)
    self.template = getChildAt(group, 0)
    for _, name in ipairs(self.FILL_TYPES) do
        local index = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
        if index ~= nil then table.insert(self.fillTypeIndices, index) end
    end
    Logging.info("[StrawOnWheels] straw model loaded, %d fill type(s)", #self.fillTypeIndices)
end

-- wheel parts: node with the physics, node that turns, radius, width
local function wheelParts(wheel)
    local ph = type(wheel.physics) == "table" and wheel.physics or wheel
    local node = wheel.node or ph.node
    local shape = ph.wheelShape or wheel.wheelShape
    local turning = wheel.driveNode or ph.driveNode
    local center = turning or wheel.repr or ph.repr or wheel.linkNode
    local radius = ph.radius or wheel.radius or 0.5
    local width = ph.width or wheel.width or 0.4
    return node, shape, turning, center, radius, width
end

-- ground contact point of a wheel, nil when it is in the air
local function wheelContact(wheel)
    local node, shape, turning, center, radius = wheelParts(wheel)
    local x, y, z
    if node ~= nil and shape ~= nil and shape ~= 0 and getWheelShapeContactObject ~= nil then
        local obj = getWheelShapeContactObject(node, shape)
        if obj == nil or obj == 0 then return nil end
        if getWheelShapeContactPoint ~= nil then
            x, y, z = getWheelShapeContactPoint(node, shape)
        end
    end
    if x == nil or (x == 0 and y == 0 and z == 0) then
        local ph = type(wheel.physics) == "table" and wheel.physics or nil
        local net = ph ~= nil and ph.netInfo or nil
        if net ~= nil and node ~= nil and entityExists(node) then
            x, y, z = localToWorld(node, net.x, net.y - radius, net.z)
            local terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
            if y - terrainY > 1.0 then return nil end
        elseif center ~= nil and entityExists(center) then
            x, y, z = getWorldTranslation(center)
            y = y - radius
        else
            return nil
        end
    end
    return x, y, z
end

local function strawUnder(x, z)
    if DensityMapHeightUtil == nil or DensityMapHeightUtil.getFillLevelAtArea == nil then return 0 end
    local total = 0
    local r = 0.35
    for _, index in ipairs(StrawOnWheels.fillTypeIndices) do
        local level = DensityMapHeightUtil.getFillLevelAtArea(index, x - r, z - r, x + r, z - r, x - r, z + r)
        if level ~= nil then total = total + level end
    end
    return total
end

function StrawOnWheels:addPiece(wstate, radius, width)
    if self.template == nil then return end
    local parent = wstate.turning
    if parent == nil or not entityExists(parent) then return end
    local node = clone(self.template, false, false, false)
    if node == nil or node == 0 then return end
    link(parent, node)
    setVisibility(node, true)
    local angle = math.random() * math.pi * 2
    local along = (math.random() - 0.5) * width * 0.9
    local out = radius + 0.01 + math.random() * 0.05
    local size = 0.18 + math.random() * 0.22
    local piece = {
        node = node, age = 0, fall = 0,
        life = self.SHED_MIN + math.random() * (self.SHED_MAX - self.SHED_MIN),
        y = out * math.cos(angle), z = out * math.sin(angle), x = along,
        rx = angle, ry = (math.random() - 0.5) * 1.6, rz = (math.random() - 0.5) * 0.9,
        sx = size, sz = size * (0.7 + math.random() * 0.8),
    }
    setTranslation(node, piece.x, piece.y, piece.z)
    setRotation(node, piece.rx, piece.ry, piece.rz)
    setScale(node, piece.sx, 1, piece.sz)
    if setClipDistance ~= nil then setClipDistance(node, 120) end
    table.insert(wstate.pieces, piece)
end

function StrawOnWheels:removePiece(piece)
    if piece.node ~= nil and entityExists(piece.node) then delete(piece.node) end
    piece.node = nil
end

function StrawOnWheels:updatePieces(wstate, dt, speed)
    local fast = speed >= self.SHED_SPEED
    for i = #wstate.pieces, 1, -1 do
        local p = wstate.pieces[i]
        if p.node == nil or not entityExists(p.node) then
            table.remove(wstate.pieces, i)
        else
            if fast then p.age = p.age + dt end
            if p.age >= p.life then
                p.fall = p.fall + dt
                local t = clamp(p.fall / self.FALL_MS, 0, 1)
                -- the piece peels off the tyre and shrinks away
                local s = 1 - t
                setTranslation(p.node, p.x, p.y * (1 + 0.5 * t), p.z * (1 + 0.5 * t))
                setScale(p.node, p.sx * s, 1, p.sz * s)
                if t >= 1 then
                    self:removePiece(p)
                    table.remove(wstate.pieces, i)
                end
            end
        end
    end
end

function StrawOnWheels:isVehicle(vehicle)
    if vehicle.rootNode == nil or not entityExists(vehicle.rootNode) then return false end
    return vehicle.spec_wheels ~= nil and vehicle.spec_wheels.wheels ~= nil
end

function StrawOnWheels:updateVehicle(vehicle, dt)
    local state = self.states[vehicle]
    if state == nil then
        state = { wheels = {}, timer = 0 }
        self.states[vehicle] = state
    end
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    state.timer = state.timer + dt
    local check = state.timer >= self.CHECK_MS
    local step = state.timer
    if check then state.timer = 0 end

    for i, wheel in ipairs(vehicle.spec_wheels.wheels) do
        local wstate = state.wheels[i]
        if wstate == nil then
            local _, _, turning = wheelParts(wheel)
            wstate = { pieces = {}, addTimer = 0, turning = turning }
            if wstate.turning == nil then
                local _, _, _, center = wheelParts(wheel)
                wstate.turning = center
            end
            state.wheels[i] = wstate
        end
        if #wstate.pieces > 0 then
            self:updatePieces(wstate, dt, speed)
        end
        if check and speed >= self.MIN_SPEED and wstate.turning ~= nil then
            wstate.addTimer = wstate.addTimer + step
            local x, y, z = wheelContact(wheel)
            if x ~= nil and wstate.addTimer >= self.ADD_INTERVAL and #wstate.pieces < self.MAX_PIECES then
                if strawUnder(x, z) >= self.MIN_LEVEL then
                    wstate.addTimer = 0
                    local _, _, _, _, radius, width = wheelParts(wheel)
                    self:addPiece(wstate, radius, width)
                end
            end
        end
    end
end

function StrawOnWheels:clearVehicleState(state)
    for _, wstate in ipairs(state.wheels) do
        for _, p in ipairs(wstate.pieces) do self:removePiece(p) end
        wstate.pieces = {}
    end
end

function StrawOnWheels:update(dt)
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then return end
    if g_currentMission.getIsClient ~= nil and not g_currentMission:getIsClient() then return end
    if not self.loaded then
        self.loaded = true
        self:loadTemplate()
    end
    if self.enabled and self.template ~= nil then
        for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
            if self:isVehicle(vehicle) then
                self:updateVehicle(vehicle, dt)
            end
        end
    end
    for vehicle, state in pairs(self.states) do
        if vehicle.rootNode == nil or not entityExists(vehicle.rootNode) then
            self:clearVehicleState(state)
            self.states[vehicle] = nil
        end
    end
end

function StrawOnWheels:deleteMap()
    for _, state in pairs(self.states) do self:clearVehicleState(state) end
    self.states = {}
    if self.templateRoot ~= nil and entityExists(self.templateRoot) then delete(self.templateRoot) end
    self.templateRoot = nil
    self.template = nil
    self.loaded = false
end

-- ---------------------------------------------------------------- console
function StrawOnWheels:consoleToggle()
    StrawOnWheels.enabled = not StrawOnWheels.enabled
    if not StrawOnWheels.enabled then
        for _, state in pairs(StrawOnWheels.states) do StrawOnWheels:clearVehicleState(state) end
    end
    return "Straw On Wheels " .. (StrawOnWheels.enabled and "on" or "off")
end
addConsoleCommand("sowToggle", "Straw On Wheels on/off", "consoleToggle", StrawOnWheels)

function StrawOnWheels:consoleSpeed(v)
    v = tonumber(v)
    if v ~= nil then StrawOnWheels.SHED_SPEED = clamp(v, 5, 100) end
    return string.format("straw falls off from %d km/h (sowSpeed 5..100, default 30)", StrawOnWheels.SHED_SPEED)
end
addConsoleCommand("sowSpeed", "Speed in km/h from which straw falls off the tyres: sowSpeed 30", "consoleSpeed", StrawOnWheels)

function StrawOnWheels:consoleInfo()
    local pieces, wheels = 0, 0
    for _, state in pairs(StrawOnWheels.states) do
        for _, w in ipairs(state.wheels) do wheels = wheels + 1; pieces = pieces + #w.pieces end
    end
    return string.format("fill types %d, wheels tracked %d, straw pieces %d", #StrawOnWheels.fillTypeIndices, wheels, pieces)
end
addConsoleCommand("sowInfo", "Straw On Wheels status", "consoleInfo", StrawOnWheels)

addModEventListener(StrawOnWheels)
