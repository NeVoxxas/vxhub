-- VX Hub | pataisyta versija
-- Pastaba: skriptas skirtas aplinkai, kurioje palaikomi loadstring ir game:HttpGet.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local VirtualUser = game:GetService("VirtualUser")

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local localPlayer = Players.LocalPlayer
local mainRemote = ReplicatedStorage:WaitForChild("__Net"):WaitForChild("MainRemote")

local autoTeleportActive = false
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
    return autoTrialsActive and selectedTrialRoom ~= nil and selectedTrialRoom ~= ""
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
        if isTriggeringRitual or trialHasPriority() then return end
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
        if isTriggeringRitual or not trialHasPriority() then return end
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
       if autoTrialsActive then startAutoTrials() end
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
       if autoRitualActive then startAutoRitual() end
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
       if autoDepositActive then startAutoDeposit() end
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
       autoTeleportActive = false
       autoDepositActive = false
       autoTrialsActive = false
       autoRitualActive = false
       isTriggeringRitual = false
       isRitualOnCooldown = false
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
