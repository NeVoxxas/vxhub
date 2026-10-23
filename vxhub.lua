-- VX Hub | pataisyta versija
-- Pastaba: skriptas skirtas aplinkai, kurioje palaikomi loadstring ir game:HttpGet.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local localPlayer = Players.LocalPlayer
local mainRemote = ReplicatedStorage:WaitForChild("__Net"):WaitForChild("MainRemote")

local autoTeleportActive = false
local autoStarsActive = false
local autoDepositActive = false
local autoTrialsActive = false
local autoRitualActive = false
local autoRejoinActive = true
local isTriggeringRitual = false
local depositInterval = 10
local ritualPosition = nil
local selectedTrialRoom = nil
local selectedOres = {}
local selectedMobs = {}
local destroyed = false
local ritualCooldownUntil = 0
local rejoinPending = false
local generation = {teleport = 0, trials = 0, deposit = 0, ritual = 0}
local connections = {}

local function addConnection(connection)
    table.insert(connections, connection)
end

addConnection(localPlayer.Idled:Connect(function()
    if destroyed then return end
    pcall(function()
        local camera = Workspace.CurrentCamera
        if not camera then return end
        VirtualUser:Button2Down(Vector2.new(0, 0), camera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.new(0, 0), camera.CFrame)
    end)
end))

addConnection(GuiService.ErrorMessageChanged:Connect(function(message)
    if destroyed or not autoRejoinActive or rejoinPending or not message or message == "" then return end
    rejoinPending = true
    task.delay(2, function()
        if destroyed or not autoRejoinActive then
            rejoinPending = false
            return
        end
        local ok = pcall(function()
            TeleportService:Teleport(game.PlaceId, localPlayer)
        end)
        if not ok then
            rejoinPending = false -- vėlesnis įvykis galės bandyti dar kartą
        end
    end)
end))

local SUFFIXES = {
    k = 1e3, m = 1e6, b = 1e9, t = 1e12, qd = 1e15, qn = 1e18,
    sx = 1e21, sp = 1e24, oc = 1e27, no = 1e30, dc = 1e33
}

-- nil reiškia nežinomą HP; nežinomas HP nėra automatiškai laikomas 0.
local function parseHP(hpText)
    if type(hpText) ~= "string" or hpText == "" then return nil end
    if hpText:lower():find("respawning", 1, true) then return 0 end
    local left = (hpText:split("/")[1] or hpText):lower():gsub("%s+", "")
    local number, suffix = left:match("^([%d%.]+)(%a*)$")
    local value = number and tonumber(number)
    if not value then return nil end
    if suffix ~= "" then
        local multiplier = SUFFIXES[suffix]
        if not multiplier then return nil end
        value = value * multiplier
    end
    return value
end

local function getHp(object)
    local ui = object:FindFirstChild("OresTopUI")
        or object:FindFirstChildOfClass("BillboardGui")
        or object:FindFirstChild("TopUI", true)
    local bar = ui and ui:FindFirstChild("Bar", true)
    local label = (bar and bar:FindFirstChild("Health", true))
        or (ui and ui:FindFirstChild("Health", true))
    if label and (label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox")) then
        return parseHP(label.Text)
    end
    return nil
end

local function isAlive(object)
    local hp = getHp(object)
    return hp == nil or hp > 0
end

local function getRoot()
    local character = localPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function getPart(object)
    if object:IsA("BasePart") then return object end
    if not object:IsA("Model") then return object:FindFirstChildWhichIsA("BasePart", true) end
    return object.PrimaryPart
        or object:FindFirstChild("HumanoidRootPart", true)
        or object:FindFirstChild("Hitbox", true)
        or object:FindFirstChildWhichIsA("BasePart", true)
end

local function getSortedItemsFromFolder(folderName)
    local content = Workspace:FindFirstChild("__GAME_CONTENT")
    local folder = content and content:FindFirstChild(folderName)
    local items, seen, names = {}, {}, {}
    if folder then
        for _, obj in ipairs(folder:GetChildren()) do
            if not seen[obj.Name] then
                seen[obj.Name] = true
                table.insert(items, {name = obj.Name, hp = getHp(obj) or math.huge})
            end
        end
    end
    table.sort(items, function(a, b)
        if a.hp == b.hp then return a.name < b.name end
        return a.hp < b.hp
    end)
    for _, item in ipairs(items) do table.insert(names, item.name) end
    if #names == 0 then return {"Nėra " .. folderName} end
    return names
end

local availableOres = getSortedItemsFromFolder("Ores")
local availableMobs = getSortedItemsFromFolder("Mobs")

local function isSelected(name, selectedList)
    if type(selectedList) == "string" then return selectedList == name end
    if type(selectedList) ~= "table" then return false end
    for _, value in pairs(selectedList) do
        if value == name then return true end
    end
    return false
end

-- Vienu metu naudojamas vienas teleportavimo prioritetas:
-- ritualas > pasirinktas Trial kambarys > paprastos rūdos / monstrai.
local function trialHasPriority()
    return not autoStarsActive and autoTrialsActive and selectedTrialRoom ~= nil and selectedTrialRoom ~= ""
end

local function teleportToCFrame(targetCFrame)
    local hrp = getRoot()
    if hrp and targetCFrame then
        hrp.CFrame = targetCFrame * CFrame.new(0, 0, 3)
    end
end

local function chooseNearestFromFolders(folderSpecs, root)
    local bestPart, bestDistance = nil, math.huge
    for _, spec in ipairs(folderSpecs) do
        local folder, names = spec[1], spec[2]
        if folder then
            for _, obj in ipairs(folder:GetChildren()) do
                if isSelected(obj.Name, names) and isAlive(obj) then
                    local part = getPart(obj)
                    if part then
                        local dist = (root.Position - part.Position).Magnitude
                        if dist < bestDistance then
                            bestDistance, bestPart = dist, part
                        end
                    end
                end
            end
        end
    end
    return bestPart
end

local function nearestTrialMob(root)
    local content = Workspace:FindFirstChild("__GAME_CONTENT")
    local contents = content and content:FindFirstChild("Contents")
    if not contents then return nil end
    local bestPart, bestDistance = nil, math.huge
    for _, worldObj in ipairs(contents:GetChildren()) do
        local trials = worldObj:FindFirstChild("Trials")
        if trials then
            for _, room in ipairs(trials:GetChildren()) do
                if room.Name == selectedTrialRoom then
                    local mobs = room:FindFirstChild("Mobs")
                    if mobs then
                        for _, mob in ipairs(mobs:GetChildren()) do
                            if mob.Name ~= localPlayer.Name and isAlive(mob) then
                                local part = getPart(mob)
                                if part then
                                    local dist = (root.Position - part.Position).Magnitude
                                    if dist < bestDistance then
                                        bestDistance, bestPart = dist, part
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return bestPart
end

-- Kiekvienas perjungimas pakeičia epochą. Senas ciklas neatsinaujina,
-- net jei vartotojas labai greitai išjungė ir įjungė jungiklį.
local function runLoop(key, isEnabled, step, delaySeconds)
    generation[key] = generation[key] + 1
    local thisGeneration = generation[key]
    if not isEnabled() then return end
    task.spawn(function()
        while not destroyed and generation[key] == thisGeneration and isEnabled() do
            local ok, err = pcall(step)
            if not ok then warn("[VX Hub] " .. key .. ": " .. tostring(err)) end
            local delay = type(delaySeconds) == "function" and delaySeconds() or delaySeconds
            task.wait(math.max(delay or 0.1, 0.05))
        end
    end)
end

local function startAutoTeleport()
    runLoop("teleport", function() return autoTeleportActive end, function()
        if isTriggeringRitual or autoStarsActive or trialHasPriority() then return end
        local root = getRoot()
        if not root then return end
        local content = Workspace:FindFirstChild("__GAME_CONTENT")
        if not content then return end
        local closest = chooseNearestFromFolders({
            {content:FindFirstChild("Ores"), selectedOres},
            {content:FindFirstChild("Mobs"), selectedMobs}
        }, root)
        if closest then teleportToCFrame(closest.CFrame) end
    end, 0.2)
end

local function startAutoTrials()
    runLoop("trials", function() return autoTrialsActive end, function()
        if isTriggeringRitual or autoStarsActive or not trialHasPriority() then return end
        local root = getRoot()
        if not root then return end
        local closest = nearestTrialMob(root)
        if closest then teleportToCFrame(closest.CFrame) end
    end, 0.08)
end

local function startAutoDeposit()
    runLoop("deposit", function() return autoDepositActive end, function()
        mainRemote:FireServer("DepositMeat")
    end, function() return depositInterval end)
end

local function startAutoRitual()
    runLoop("ritual", function() return autoRitualActive end, function()
        if os.clock() < ritualCooldownUntil or isTriggeringRitual then return end
        local root = getRoot()
        if not root then return end
        isTriggeringRitual = true
        local currentGeneration = generation.ritual
        local target = ritualPosition or root.CFrame
        local sent = false
        local ok, err = pcall(function()
            root.CFrame = target
            task.wait(1.5)
            if destroyed or not autoRitualActive or generation.ritual ~= currentGeneration then return end
            mainRemote:FireServer("StartRitual")
            sent = true
        end)
        if ok and sent and autoRitualActive and not destroyed then
            ritualCooldownUntil = os.clock() + 178.5
            Rayfield:Notify({
                Title = "Ritualo užklausa išsiųsta",
                Content = "StartRitual išsiųstas serveriui (patvirtinimas netikrinamas).",
                Duration = 3
            })
        elseif not ok then
            warn("[VX Hub] ritual: " .. tostring(err))
            ritualCooldownUntil = os.clock() + 5 -- trumpa pauzė prieš pakartotinį bandymą
        end
        isTriggeringRitual = false
    end, 0.5)
end

-- === INTEGRUOTAS STAR AUTO TP (Realm4 QuickPickup) ===
local controller = {
    Enabled = false,
    Offset = Vector3.new(0, 0, 0),
    ScanInterval = 0.05,
    FollowInterval = 0.03,
    PickupHoldTime = 0.08,       -- time to let a pickup register before seeking the next star
    TargetRetryCooldown = 0.5,    -- seconds before reconsidering the same still-visible star
    MaxTargetDistance = 200,      -- radius around the player
    MaxHeightDifference = 65,     -- reject far-above/below stars
    BorderInset = 2,             -- require target away from outer AABB edge
    RequireFourWalls = true,     -- fail closed unless rays see surrounding borders
    _destroyed = false,
    _connections = {},
}


local activeTarget, printedTarget
local firstTeleportTime = nil
local ignoredUntil = setmetatable({}, {__mode = "k"})
local lastScan, lastFollow = -math.huge, -math.huge
local boundsCache, cacheTime, cacheFolder

local function rootPart()
    return getRoot()
end

local function bordersFolder()
    local maps = Workspace:FindFirstChild("MAPS")
    local realm4 = maps and maps:FindFirstChild("Realm4")
    return realm4 and realm4:FindFirstChild("Borders")
end

local function borderBounds()
    local folder = bordersFolder()
    if not folder then return nil end
    if folder == cacheFolder and os.clock() - cacheTime < 2 then
        return boundsCache
    end
    cacheFolder, cacheTime, boundsCache = folder, os.clock(), nil
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    local count = 0
    for _, item in ipairs(folder:GetDescendants()) do
        if item:IsA("BasePart") then
            -- AABB of all eight corners, correctly handling rotated wall parts
            for ix = -1, 1, 2 do
                for iy = -1, 1, 2 do
                    for iz = -1, 1, 2 do
                        local p = item.CFrame:PointToWorldSpace(Vector3.new(ix * item.Size.X / 2, iy * item.Size.Y / 2, iz * item.Size.Z / 2))
                        minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
                        minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
                    end
                end
            end
            count += 1
        end
    end
    if count == 0 then return nil end
    boundsCache = {minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ, folder = folder}
    return boundsCache
end

local function insideAABB(p, bounds)
    local inset = controller.BorderInset
    return p.X > bounds.minX + inset and p.X < bounds.maxX - inset
        and p.Z > bounds.minZ + inset and p.Z < bounds.maxZ - inset
end

local function makeParams(folder)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = {folder}
    params.IgnoreWater = true
    return params
end

local function enclosedByBorders(pos, b, params)
    -- AABB alone does NOT prove a point is within irregular geometry.
    -- Four horizontal raycasts must reach border parts from the candidate point.
    -- This intentionally rejects uncertain positions (e.g. incomplete borders).
    local search = math.max(b.maxX - b.minX, b.maxZ - b.minZ) + 20
    local origin = Vector3.new(pos.X, pos.Y, pos.Z)
    local directions = {
        Vector3.new(search, 0, 0), Vector3.new(-search, 0, 0),
        Vector3.new(0, 0, search), Vector3.new(0, 0, -search),
    }
    for _, direction in ipairs(directions) do
        if not Workspace:Raycast(origin, direction, params) then
            return false
        end
    end
    return true
end

local function allowedPosition(pos, root, bounds, params)
    if not bounds or not root then return false end
    if not insideAABB(root.Position, bounds) or not insideAABB(pos, bounds) then return false end
    if math.abs(pos.Y - root.Position.Y) > controller.MaxHeightDifference then return false end
    if (pos - root.Position).Magnitude > controller.MaxTargetDistance then return false end
    if controller.RequireFourWalls then
        if not enclosedByBorders(root.Position, bounds, params)
            or not enclosedByBorders(pos, bounds, params) then
            return false
        end
    end
    -- Never TP through a border, even when both positions fall inside the global AABB.
    local delta = pos - root.Position
    if delta.Magnitude > 0.1 and Workspace:Raycast(root.Position, delta, params) then
        return false
    end
    return true
end

local function targetPosition(gain, hitbox)
    if gain:IsA("Attachment") then return gain.WorldPosition end
    if gain:IsA("BasePart") then return gain.Position end
    local current = gain.Parent
    while current and current ~= hitbox do
        if current:IsA("Attachment") then return current.WorldPosition end
        if current:IsA("BasePart") then return current.Position end
        current = current.Parent
    end
    if hitbox:IsA("BasePart") then return hitbox.Position end
    if hitbox:IsA("Attachment") then return hitbox.WorldPosition end
    return nil
end

local function resolve(star)
    local hitbox = star:FindFirstChild("Hitbox")
    local ui = hitbox and hitbox:FindFirstChild("StarUI")
    local gain = ui and ui:FindFirstChild("Gain")
    local pos = gain and targetPosition(gain, hitbox)
    if pos then return {star = star, gain = gain, position = pos} end
    return nil
end

local function nearestTarget(bounds, params)
    local folder, root = Workspace:FindFirstChild("ClientStars"), rootPart()
    if not folder or not root then return nil end
    local best, bestDist
    for _, star in ipairs(folder:GetChildren()) do
        local item = resolve(star)
        if item and (ignoredUntil[star] or 0) <= os.clock()
            and allowedPosition(item.position + controller.Offset, root, bounds, params) then
            local d = (root.Position - item.position).Magnitude
            if not bestDist or d < bestDist then
                best, bestDist = item, d
            end
        end
    end
    return best
end

local function update()
    if not controller.Enabled or controller._destroyed or destroyed or isTriggeringRitual then return end
    local root, bounds = rootPart(), borderBounds()
    if not root or not bounds then
        activeTarget, firstTeleportTime = nil, nil
        return -- fail closed when border geometry is unavailable
    end
    local params = makeParams(bounds.folder)
    local now = os.clock()

    -- The Gain GUI can remain visible during the pickup animation.
    -- Do not keep following its hitbox forever. After a short hold, move on.
    if activeTarget and firstTeleportTime and now - firstTeleportTime >= controller.PickupHoldTime then
        ignoredUntil[activeTarget.star] = now + controller.TargetRetryCooldown
        activeTarget, firstTeleportTime = nil, nil
        lastScan = -math.huge
    end

    if not activeTarget or not activeTarget.star.Parent or now - lastScan >= controller.ScanInterval then
        local nextTarget = nearestTarget(bounds, params)
        if not activeTarget or not activeTarget.star.Parent then
            if not nextTarget or not activeTarget or nextTarget.star ~= activeTarget.star then
                firstTeleportTime = nil
            end
            activeTarget = nextTarget
        end
        -- Keep the current star for the short pickup hold, even when
        -- the nearest-star ordering changes as the character moves.
        lastScan = now
        if activeTarget and activeTarget.star ~= printedTarget then
            printedTarget = activeTarget.star
            print("[StarAutoTP] Realm4 target:", activeTarget.star:GetFullName())
        end
    end

    if now - lastFollow >= controller.FollowInterval then
        lastFollow = now
        if not activeTarget then return end
        local current = resolve(activeTarget.star)
        if not current then
            activeTarget, firstTeleportTime = nil, nil
            return
        end
        local destination = current.position + controller.Offset
        if not allowedPosition(destination, root, bounds, params) then
            activeTarget, firstTeleportTime = nil, nil
            return
        end
        root.CFrame = CFrame.new(destination)
        if not firstTeleportTime then firstTeleportTime = now end
    end
end

addConnection(RunService.Heartbeat:Connect(function()
    local ok, err = pcall(update)
    if not ok then warn("[VX Hub Stars] " .. tostring(err)) end
end))

function controller.Start()
    if controller._destroyed then return end
    controller.Enabled = true
    autoStarsActive = true
    activeTarget, printedTarget, firstTeleportTime = nil, nil, nil
    ignoredUntil = setmetatable({}, {__mode = "k"})
    lastScan, lastFollow = -math.huge, -math.huge
    if not bordersFolder() then
        warn("[StarAutoTP] Borders nerastas: Workspace.MAPS.Realm4.Borders - teleportavimas blokuojamas")
    end
    print("[StarAutoTP] ON - Realm4 borders protection")
end
function controller.Stop()
    controller.Enabled = false
    autoStarsActive = false
    activeTarget, firstTeleportTime = nil, nil
    print("[StarAutoTP] OFF")
end
function controller.Toggle()
    if controller.Enabled then controller.Stop() else controller.Start() end
end
function controller.Destroy()
    controller.Enabled = false
    autoStarsActive = false
    controller._destroyed = true
    for _, connection in ipairs(controller._connections) do connection:Disconnect() end

    print("[StarAutoTP] Unloaded")
end


-- === RAYFIELD UI LANGAS ===
local Window = Rayfield:CreateWindow({
   Name = "VX Hub",
   Icon = 0,
   LoadingTitle = "VX Hub Kraunasi...",
   LoadingSubtitle = "by Sirius Rayfield",
   Theme = "Default",
   DisableRayfieldPrompts = false,
   ConfigurationSaving = {
      Enabled = true,
      FolderName = "VXHubFolder",
      FileName = "VX_Config"
   }
})

local MainTab = Window:CreateTab("Teleport", 4483362458)
local TrialsTab = Window:CreateTab("Trials", 4483362458)
local AutomationTab = Window:CreateTab("Automation", 4483362458)
local SettingsTab = Window:CreateTab("Settings", 4483362458)

-- === TAB 1: TELEPORT ===
MainTab:CreateSection("⛏️ Ores (Rudos)")

local OreDropdown = MainTab:CreateDropdown({
   Name = "Pasirinkite Rudas",
   Options = availableOres,
   CurrentOption = {},
   MultipleOptions = true,
   Flag = "OreSelectFlag",
   Callback = function(Options) selectedOres = Options end,
})

MainTab:CreateSection("⚔️ Mobs (Monstrai)")

local MobDropdown = MainTab:CreateDropdown({
   Name = "Pasirinkite Mobus",
   Options = availableMobs,
   CurrentOption = {},
   MultipleOptions = true,
   Flag = "MobSelectFlag",
   Callback = function(Options) selectedMobs = Options end,
})

MainTab:CreateSection("⚡ Auto Teleport")

MainTab:CreateToggle({
   Name = "Auto TP To Target",
   CurrentValue = false,
   Flag = "AutoTPToggleFlag",
   Callback = function(Value)
       autoTeleportActive = Value
       startAutoTeleport()
   end,
})

MainTab:CreateButton({
   Name = "Atnaujinti Rudų ir Mobų Sąrašus",
   Callback = function()
       local updatedOres = getSortedItemsFromFolder("Ores")
       local updatedMobs = getSortedItemsFromFolder("Mobs")
       OreDropdown:Refresh(updatedOres)
       MobDropdown:Refresh(updatedMobs)
       Rayfield:Notify({ Title = "Sąrašas atnaujintas", Content = "Rasta Rudų: " .. #updatedOres .. " | Mobų: " .. #updatedMobs, Duration = 3 })
   end,
})


MainTab:CreateSection("⭐ Stars - Realm4")
MainTab:CreateToggle({
   Name = "Auto TP Stars (Realm4)",
   CurrentValue = false,
   Flag = "AutoStarsRealm4Flag",
   Callback = function(value)
       if value then controller.Start() else controller.Stop() end
   end,
})
MainTab:CreateSlider({
   Name = "Star Pickup Hold (ms)",
   Range = {30, 500}, Increment = 10, Suffix = " ms",
   CurrentValue = 80,
   Flag = "StarPickupHoldFlag",
   Callback = function(value) controller.PickupHoldTime = value / 1000 end,
})
MainTab:CreateSlider({
   Name = "Star Retry Cooldown (ms)",
   Range = {100, 2000}, Increment = 50, Suffix = " ms",
   CurrentValue = 500,
   Flag = "StarCooldownFlag",
   Callback = function(value) controller.TargetRetryCooldown = value / 1000 end,
})
MainTab:CreateSlider({
   Name = "Star Max Distance",
   Range = {50, 500}, Increment = 10, Suffix = " studs",
   CurrentValue = 200,
   Flag = "StarMaxDistanceFlag",
   Callback = function(value) controller.MaxTargetDistance = value end,
})
MainTab:CreateButton({
   Name = "Star Status / Borders Check (F9)",
   Callback = function()
       local b = borderBounds()
       print("[VX Hub Stars] Active:", controller.Enabled,
           "Borders:", b and b.folder:GetFullName() or "MISSING",
           "PickupHold:", controller.PickupHoldTime,
           "RetryCooldown:", controller.TargetRetryCooldown)
   end,
})

-- === TAB 2: TRIALS ===
TrialsTab:CreateSection("🏆 Auto Trials (Teleport Cleaver)")

TrialsTab:CreateDropdown({
   Name = "Pasirinkite Trial Sunkumą",
   Options = {"EasyTrialRoom", "MediumTrialRoom", "HardTrialRoom", "ExtremeTrialRoom"},
   CurrentOption = {},
   MultipleOptions = false,
   Flag = "TrialRoomSelectFlag",
   Callback = function(Option)
       if type(Option) == "table" then
           selectedTrialRoom = Option[1]
       else
           selectedTrialRoom = Option
       end
   end,
})

TrialsTab:CreateToggle({
   Name = "Auto TP To Wave Mobs",
   CurrentValue = false,
   Flag = "AutoTrialsToggleFlag",
   Callback = function(Value)
       autoTrialsActive = Value
       startAutoTrials()
   end,
})

-- === TAB 3: AUTOMATION ===
AutomationTab:CreateSection("🔮 Auto Ritual")

local RitualInput = AutomationTab:CreateInput({
   Name = "Išsaugota Ritualo Vieta (X, Y, Z)",
   PlaceholderText = "Pvz: 100.0, 15.0, -200.0",
   RemoveTextAfterFocusLost = false,
   Flag = "RitualPositionFlag",
   Callback = function(Text)
       local x, y, z = Text:match("([^,]+),%s*([^,]+),%s*([^,]+)")
       if x and y and z then
           ritualPosition = CFrame.new(tonumber(x), tonumber(y), tonumber(z))
       end
   end,
})

AutomationTab:CreateButton({
   Name = "Nustatyti Dabartinę Vietą kaip Ritualo Vietą",
   Callback = function()
       local hrp = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
       if hrp then
           local pos = hrp.Position
           local posStr = string.format("%.1f, %.1f, %.1f", pos.X, pos.Y, pos.Z)
           
           RitualInput:Set(posStr)
           ritualPosition = hrp.CFrame
           
           Rayfield:Notify({ Title = "Ritualo Vieta", Content = "Išsaugota pozicija: " .. posStr, Duration = 3 })
       end
   end,
})

AutomationTab:CreateToggle({
   Name = "Auto Start Ritual (Loop Every 3m)",
   CurrentValue = false,
   Flag = "AutoRitualToggleFlag",
   Callback = function(Value)
       autoRitualActive = Value
       startAutoRitual()
   end,
})

AutomationTab:CreateSection("📦 Auto Deposit & Protection")

AutomationTab:CreateSlider({
   Name = "Deposit Timeout (Sekundėmis)",
   Range = {1, 60},
   Increment = 1,
   Suffix = "s",
   CurrentValue = 10,
   Flag = "DepositTimeoutFlag",
   Callback = function(Value) depositInterval = Value end,
})

AutomationTab:CreateToggle({
   Name = "Auto Deposit Meat",
   CurrentValue = false,
   Flag = "AutoDepositToggleFlag",
   Callback = function(Value)
       autoDepositActive = Value
       startAutoDeposit()
   end,
})

AutomationTab:CreateToggle({
   Name = "Auto Rejoin on Kick / Disconnect",
   CurrentValue = true,
   Flag = "AutoRejoinToggleFlag",
   Callback = function(Value) autoRejoinActive = Value end,
})

-- === TAB 4: SETTINGS ===
SettingsTab:CreateSection("💾 Configuration (Nustatymai)")

SettingsTab:CreateButton({
   Name = "Išsaugoti Nustatymus (Save Config)",
   Callback = function()
       pcall(function()
           if Rayfield.Save then Rayfield:Save()
           elseif Window.SaveConfiguration then Window:SaveConfiguration() end
       end)
       Rayfield:Notify({ Title = "Config", Content = "Nustatymai išsaugoti į kompiuterį!", Duration = 3 })
   end,
})

SettingsTab:CreateButton({
   Name = "Užkrauti Nustatymus (Load Config)",
   Callback = function()
       pcall(function()
           if Rayfield.Load then Rayfield:Load()
           elseif Window.LoadConfiguration then Window:LoadConfiguration() end
       end)
       Rayfield:Notify({ Title = "Config", Content = "Nustatymai sėkmingai užkrauti!", Duration = 3 })
   end,
})

SettingsTab:CreateSection("Sąsajos Valdymas")

SettingsTab:CreateButton({
   Name = "Unload UI",
   Callback = function()
       destroyed = true
       autoTeleportActive = false
       autoDepositActive = false
       autoTrialsActive = false
       autoRitualActive = false
       isTriggeringRitual = false
       controller.Destroy()
       for key in pairs(generation) do generation[key] += 1 end
       for _, connection in ipairs(connections) do connection:Disconnect() end
       Rayfield:Destroy()
   end,
})

-- === AUTOMATINIS CONFIGO UŽKROVIMAS PALEIDŽIANT SKRIPTĄ ===
task.spawn(function()
    task.wait(1.2)
    pcall(function()
        Rayfield:Load()
    end)
end)
