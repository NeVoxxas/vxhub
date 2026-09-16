local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local VirtualUser = game:GetService("VirtualUser")

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

-- === AUTO RITUAL LOGIKA (NEUŽBLOKUOJA AUTO TP) ===
local function startAutoRitual()
    ritualThread = task.spawn(function()
        while autoRitualActive do
            if not isRitualOnCooldown then
                local character = localPlayer.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")

                if hrp then
                    local targetCFrame = ritualPosition or hrp.CFrame

                    -- 1. Laikinai sustabdomas Auto TP teleportacijai į ritualą
                    isTriggeringRitual = true
                    hrp.CFrame = targetCFrame
                    task.wait(0.4)

                    -- 2. Paleidžiamas ritualas
                    pcall(function()
                        mainRemote:FireServer("StartRitual")
                    end)

                    Rayfield:Notify({
                        Title = "Ritualas Aktyvuotas!",
                        Content = "StartRitual paleistas. Auto TP grąžintas!",
                        Duration = 3
                    })

                    -- 3. IŠKART PO TRIGGERINIMO: Atsukame Auto TP!
                    isTriggeringRitual = false
                    isRitualOnCooldown = true

                    -- 4. Fone atskaičiuojame 4 min. (2 min. ritualas + 2 min. cooldown)
                    task.delay(180, function()
                        isRitualOnCooldown = false
                    end)
                end
            end
            task.wait(1)
        end
    end)
end

-- === AUTO TRIALS LOGIKA ===
local function startAutoTrials()
    trialsThread = task.spawn(function()
        while autoTrialsActive do
            if not isTriggeringRitual then
                local character = localPlayer.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart")

                if hrp then
                    local closestMob = nil
                    local shortestDistance = math.huge

                    for _, descendant in ipairs(workspace:GetDescendants()) do
                        if descendant.Name == "Mobs" and descendant.Parent and descendant.Parent.Name:find("Trial") then
                            for _, mob in ipairs(descendant:GetChildren()) do
                                local ui = mob:FindFirstChild("OresTopUI") or mob:FindFirstChildOfClass("BillboardGui") or mob:FindFirstChild("TopUI", true)
                                local bar = ui and ui:FindFirstChild("Bar", true)
                                local lbl = bar and bar:FindFirstChild("Health", true) or (ui and ui:FindFirstChild("Health", true))

                                if not (lbl and lbl.Text:find("Respawning")) then
                                    local mobPos = mob:IsA("BasePart") and mob.Position or mob:GetPivot().Position
                                    local dist = (hrp.Position - mobPos).Magnitude

                                    if dist < shortestDistance then
                                        shortestDistance = dist
                                        closestMob = mob
                                    end
                                end
                            end
                        end
                    end

                    if closestMob then
                        local targetCFrame = closestMob:IsA("BasePart") and closestMob.CFrame or closestMob:GetPivot()
                        teleportToCFrame(targetCFrame)
                    end
                end
            end
            task.wait(0.2)
        end
    end)
end

-- === AUTO DEPOSIT LOGIKA ===
local function startAutoDeposit()
    depositThread = task.spawn(function()
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
    tpThread = task.spawn(function()
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

-- === RAYFIELD UI ===
local Window = Rayfield:CreateWindow({
   Name = "VX Hub",
   Icon = 0,
   LoadingTitle = "VX Hub Kraunasi...",
   LoadingSubtitle = "by Sirius Rayfield",
   Theme = "Default",
   DisableRayfieldPrompts = false,
   ConfigurationSaving = {
      Enabled = true,
      FolderName = "VXHubConfigs",
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
   Flag = "OreSelect",
   Callback = function(Options) selectedOres = Options end,
})

MainTab:CreateSection("⚔️ Mobs (Monstrai)")

local MobDropdown = MainTab:CreateDropdown({
   Name = "Pasirinkite Mobus",
   Options = availableMobs,
   CurrentOption = {},
   MultipleOptions = true,
   Flag = "MobSelect",
   Callback = function(Options) selectedMobs = Options end,
})

MainTab:CreateSection("⚡ Auto Teleport")

MainTab:CreateToggle({
   Name = "Auto TP To Target",
   CurrentValue = false,
   Flag = "AutoTPToggle",
   Callback = function(Value)
       autoTeleportActive = Value
       if autoTeleportActive then startAutoTeleport()
       else if tpThread then task.cancel(tpThread) tpThread = nil end end
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
   Flag = "AutoTrialsToggle",
   Callback = function(Value)
       autoTrialsActive = Value
       if autoTrialsActive then startAutoTrials()
       else if trialsThread then task.cancel(trialsThread) trialsThread = nil end end
   end,
})

-- === TAB 3: AUTOMATION ===
AutomationTab:CreateSection("🔮 Auto Ritual")

AutomationTab:CreateButton({
   Name = "Nustatyti Dabartinę Vietą kaip Ritualo Vietą",
   Callback = function()
       local hrp = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
       if hrp then
           ritualPosition = hrp.CFrame
           Rayfield:Notify({ Title = "Ritualo Vieta", Content = "Dabartinė pozicija išsaugota ritualams!", Duration = 3 })
       end
   end,
})

AutomationTab:CreateToggle({
   Name = "Auto Start Ritual (Loop Every 4m)",
   CurrentValue = false,
   Flag = "AutoRitualToggle",
   Callback = function(Value)
       autoRitualActive = Value
       if autoRitualActive then
           startAutoRitual()
       else
           isTriggeringRitual = false
           isRitualOnCooldown = false
           if ritualThread then task.cancel(ritualThread) ritualThread = nil end
       end
   end,
})

AutomationTab:CreateSection("📦 Auto Deposit & Protection")

AutomationTab:CreateSlider({
   Name = "Deposit Timeout (Sekundėmis)",
   Range = {1, 60},
   Increment = 1,
   Suffix = "s",
   CurrentValue = 10,
   Flag = "DepositTimeoutSlider",
   Callback = function(Value) depositInterval = Value end,
})

AutomationTab:CreateToggle({
   Name = "Auto Deposit Meat",
   CurrentValue = false,
   Flag = "AutoDepositToggle",
   Callback = function(Value)
       autoDepositActive = Value
       if autoDepositActive then startAutoDeposit()
       else if depositThread then task.cancel(depositThread) depositThread = nil end end
   end,
})

AutomationTab:CreateToggle({
   Name = "Auto Rejoin on Kick / Disconnect",
   CurrentValue = true,
   Flag = "AutoRejoinToggle",
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
       Rayfield:Notify({ Title = "Config", Content = "Nustatymai sėkmingai išsaugoti!", Duration = 3 })
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
       if tpThread then task.cancel(tpThread) end
       if depositThread then task.cancel(depositThread) end
       if trialsThread then task.cancel(trialsThread) end
       if ritualThread then task.cancel(ritualThread) end
       Rayfield:Destroy()
   end,
})
