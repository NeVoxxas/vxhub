local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")

local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()
local localPlayer = Players.LocalPlayer

local autoTeleportActive = false
local autoDepositActive = false
local autoTrialsActive = false
local autoRitualActive = false
local autoRejoinActive = true

local isTriggeringRitual = false
local isRitualOnCooldown = false
local depositInterval = 10
local ritualPosition = nil

local selectedOres = {}
local selectedMobs = {}

local tpThread = nil
local depositThread = nil
local trialsThread = nil
local ritualThread = nil

local mainRemote = ReplicatedStorage:WaitForChild("__Net"):WaitForChild("MainRemote")

-- === ANTI-AFK & AUTO-REJOIN ===
localPlayer.Idled:Connect(function()
    VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    task.wait(1)
    VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

GuiService.ErrorMessageChanged:Connect(function()
    if autoRejoinActive then
        task.wait(2)
        TeleportService:Teleport(game.PlaceId, localPlayer)
    end
end)

-- === SUFFIX REIKŠMIŲ KONVERTAVIMAS ===
local SUFFIXES = {
    k = 1e3, m = 1e6, b = 1e9, t = 1e12, qd = 1e15, qn = 1e18,
    sx = 1e21, sp = 1e24, oc = 1e27, no = 1e30, dc = 1e33
}

local function parseHP(hpText)
    if not hpText or hpText == "" or hpText:find("Respawning") then
        return math.huge
    end

    local currentHp = hpText:split("/")[1] or hpText
    currentHp = currentHp:gsub("%s+", ""):lower()

    local num, suffix = currentHp:match("([%d%.]+)(%a*)")
    num = tonumber(num) or math.huge

    if suffix and SUFFIXES[suffix] then
        return num * SUFFIXES[suffix]
    end

    return num
end

local function getSortedItemsFromFolder(folderName)
    local gameContent = workspace:FindFirstChild("__GAME_CONTENT")
    local folder = gameContent and gameContent:FindFirstChild(folderName)

    local itemList = {}
    local seen = {}

    if folder then
        for _, object in ipairs(folder:GetChildren()) do
            if not seen[object.Name] then
                seen[object.Name] = true
                local ui = object:FindFirstChild("OresTopUI") or object:FindFirstChildOfClass("BillboardGui") or object:FindFirstChild("TopUI", true)
                local bar = ui and ui:FindFirstChild("Bar", true)
                local lbl = bar and bar:FindFirstChild("Health", true) or (ui and ui:FindFirstChild("Health", true))
                local hpValue = lbl and parseHP(lbl.Text) or math.huge

                table.insert(itemList, { name = object.Name, hp = hpValue })
            end
        end
    end

    table.sort(itemList, function(a, b) return a.hp < b.hp end)

    local sortedNames = {}
    for _, item in ipairs(itemList) do table.insert(sortedNames, item.name) end
    if #sortedNames == 0 then sortedNames = {"Nėra " .. folderName} end

    return sortedNames
end

local availableOres = getSortedItemsFromFolder("Ores")
local availableMobs = getSortedItemsFromFolder("Mobs")

local function isSelected(name, selectedList)
    if type(selectedList) == "table" then
        for _, v in ipairs(selectedList) do
            if v == name then return true end
        end
    elseif type(selectedList) == "string" then
        return selectedList == name
    end
    return false
end

local function teleportToCFrame(targetCFrame)
    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if hrp then
        hrp.CFrame = targetCFrame * CFrame.new(0, 0, 3)
    end
end

-- === AUTO RITUAL LOGIKA ===
local function startAutoRitual()
    task.spawn(function()
        while autoRitualActive do
            if not isRitualOnCooldown then
                local character = localPlayer.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")

                if hrp then
                    local targetCFrame = ritualPosition or hrp.CFrame

                    isTriggeringRitual = true
                    isRitualOnCooldown = true

                    hrp.CFrame = targetCFrame
                    task.wait(1.5)

                    pcall(function()
                        mainRemote:FireServer("StartRitual")
                    end)

                    Rayfield:Notify({
                        Title = "Ritualas Aktyvuotas!",
                        Content = "StartRitual paleistas. Auto TP grąžintas!",
                        Duration = 3
                    })

                    task.wait(1.0)
                    isTriggeringRitual = false

                    task.wait(177.5)
                    isRitualOnCooldown = false
                end
            end
            task.wait(1)
        end
    end)
end

-- === AUTO TRIALS LOGIKA ===
local function startAutoTrials()
    task.spawn(function()
        while autoTrialsActive do
            if not isTriggeringRitual then
                local character = localPlayer.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")

                if hrp then
                    local closestMobPart = nil
                    local shortestDistance = math.huge

                    for _, descendant in ipairs(workspace:GetDescendants()) do
                        if descendant.Name == "Mobs" and descendant.Parent and descendant.Parent.Name:find("Trial") then
                            for _, mob in ipairs(descendant:GetChildren()) do
                                if mob.Name ~= localPlayer.Name then
                                    local part = mob:IsA("BasePart") and mob or mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart") or mob:FindFirstChildOfClass("BasePart")
                                    
                                    if part then
                                        local dist = (hrp.Position - part.Position).Magnitude
                                        if dist < shortestDistance and dist < 300 then
                                            shortestDistance = dist
                                            closestMobPart = part
                                        end
                                    end
                                end
                            end
                        end
                    end

                    if closestMobPart then
                        hrp.CFrame = closestMobPart.CFrame * CFrame.new(0, 0, 3)
                        task.wait(0.12)
                    else
                        task.wait(0.2)
                    end
                else
                    task.wait(0.5)
                end
            else
                task.wait(0.5)
            end
            task.wait(0.02)
        end
    end)
end

-- === AUTO DEPOSIT LOGIKA ===
local function startAutoDeposit()
    task.spawn(function()
        while autoDepositActive do
            pcall(function()
                mainRemote:FireServer("DepositMeat")
            end)
            task.wait(depositInterval)
        end
    end)
end

-- === AUTO TELEPORT LOGIKA ===
local function startAutoTeleport()
    task.spawn(function()
        while autoTeleportActive do
            if not isTriggeringRitual then
                local character = localPlayer.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")

                if hrp then
                    local gameContent = workspace:FindFirstChild("__GAME_CONTENT")
                    local oresFolder = gameContent and gameContent:FindFirstChild("Ores")
                    local mobsFolder = gameContent and gameContent:FindFirstChild("Mobs")

                    local closestObject = nil
                    local shortestDistance = math.huge

                    if oresFolder then
                        for _, object in ipairs(oresFolder:GetChildren()) do
                            if isSelected(object.Name, selectedOres) then
                                local ui = object:FindFirstChild("OresTopUI") or object:FindFirstChildOfClass("BillboardGui") or object:FindFirstChild("TopUI", true)
                                local bar = ui and ui:FindFirstChild("Bar", true)
                                local lbl = bar and bar:FindFirstChild("Health", true) or (ui and ui:FindFirstChild("Health", true))

                                if not (lbl and lbl.Text:find("Respawning")) then
                                    local objPos = object:IsA("BasePart") and object.Position or object:GetPivot().Position
                                    local dist = (hrp.Position - objPos).Magnitude

                                    if dist < shortestDistance then
                                        shortestDistance = dist
                                        closestObject = object
                                    end
                                end
                            end
                        end
                    end

                    if mobsFolder then
                        for _, object in ipairs(mobsFolder:GetChildren()) do
                            if isSelected(object.Name, selectedMobs) then
                                local ui = object:FindFirstChild("OresTopUI") or object:FindFirstChildOfClass("BillboardGui") or object:FindFirstChild("TopUI", true)
                                local bar = ui and ui:FindFirstChild("Bar", true)
                                local lbl = bar and bar:FindFirstChild("Health", true) or (ui and ui:FindFirstChild("Health", true))

                                if not (lbl and lbl.Text:find("Respawning")) then
                                    local objPos = object:IsA("BasePart") and object.Position or object:GetPivot().Position
                                    local dist = (hrp.Position - objPos).Magnitude

                                    if dist < shortestDistance then
                                        shortestDistance = dist
                                        closestObject = object
                                    end
                                end
                            end
                        end
                    end

                    if closestObject then
                        local targetCFrame = closestObject:IsA("BasePart") and closestObject.CFrame or closestObject:GetPivot()
                        teleportToCFrame(targetCFrame)
                    end
                end
            end
            task.wait(0.2)
        end
    end)
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
       if autoTeleportActive then startAutoTeleport() end
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
